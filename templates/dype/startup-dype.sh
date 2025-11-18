#!/usr/bin/env bash
# DyPE + FLUX on top of an existing ComfyUI container
# - No Dockerfile edits
# - Installs everything only once per volume (fast boots after first time)
# - Uses a single official FLUX.1-dev model (no fp8/fp16 copies)
# - Preloads your Flux-DyPE workflow JSON

set -euo pipefail

# ---- Config (override via env if you like) ----
ROOT="${ROOT:-/workspace}"
COMFY="$ROOT/ComfyUI"
PORT="${PORT:-8188}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"

SETUP_FLAG="$ROOT/.dype_setup_done_v2"

echo "=== [DyPE] bootstrap @ $(date) ==="
echo "[cfg] ROOT=$ROOT  COMFY=$COMFY  PORT=$PORT  FLAG=$SETUP_FLAG"

# ---- Ensure ComfyUI repo exists (light, every boot is fine) ----
if [[ ! -f "$COMFY/main.py" ]]; then
  echo "[ComfyUI] Not found, cloning fresh..."
  rm -rf "$COMFY"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  echo "[ComfyUI] Found."
fi

########################################
# HEAVY SETUP – only on first run
########################################
if [[ ! -f "$SETUP_FLAG" ]]; then
  echo "[Setup] Heavy setup starting (this is the long first boot only)..."

  # ---- Python deps: pin torch 2.4.x (fixes torch.compiler issues) ----
  echo "[Py] Installing PyTorch 2.4.x stack (CUDA 12.1 wheels)..."
  python3 -m pip install -U pip >/dev/null 2>&1 || true

  python3 - <<'PY'
import subprocess, sys
def pip(*args): subprocess.check_call([sys.executable, "-m", "pip", *args])

pip(
    "install",
    "--upgrade",
    "--extra-index-url", "https://download.pytorch.org/whl/cu121",
    "torch==2.4.1",
    "torchvision==0.19.1",
    "torchaudio==2.4.1",
)
PY

  # ---- SageAttention for KJNodes PatchSageAttentionKJ ----
  echo "[Py] Installing SageAttention..."
  python3 -m pip install "sageattention==1.0.6" --no-build-isolation

  # Ensure huggingface-cli exists
  echo "[Py] Ensuring huggingface_hub / huggingface-cli..."
  python3 -m pip install -q "huggingface_hub" >/dev/null 2>&1 || true

  # ---- Required custom nodes (DyPE, KJNodes, rgthree, Manager) ----
  echo "[Nodes] Installing required custom nodes..."
  mkdir -p "$COMFY/custom_nodes"
  cd "$COMFY/custom_nodes"

  if [[ ! -d "ComfyUI-DyPE" ]]; then
    git clone https://github.com/wildminder/ComfyUI-DyPE.git
  else
    (cd ComfyUI-DyPE && git pull --rebase || true)
  fi

  if [[ ! -d "ComfyUI-KJNodes" ]]; then
    git clone https://github.com/kijai/ComfyUI-KJNodes.git
  else
    (cd ComfyUI-KJNodes && git pull --rebase || true)
  fi

  if [[ ! -d "rgthree-comfy" ]]; then
    git clone https://github.com/rgthree/rgthree-comfy.git
  else
    (cd rgthree-comfy && git pull --rebase || true)
  fi

  if [[ ! -d "ComfyUI-Manager" ]]; then
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git || true
  fi

  # ---- Models: exact files in exact folders ----
  echo "[Models] Ensuring model folders..."
  MODEL_DIR="$COMFY/models"
  mkdir -p \
    "$MODEL_DIR/diffusion_models" \
    "$MODEL_DIR/text_encoders" \
    "$MODEL_DIR/vae"

  dl() {  # repo file outpath
    local repo="$1"; local file="$2"; local out="$3"
    if [[ -s "$out" ]]; then
      echo "[OK] $(basename "$out") already present"
      return
    fi
    echo "[DL] $repo :: $file  ->  $out"
    mkdir -p "$(dirname "$out")"
    if [[ -n "$HF_TOKEN" ]]; then
      HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" huggingface-cli download "$repo" "$file" \
        --local-dir "$(dirname "$out")" --local-dir-use-symlinks False --resume
    else
      huggingface-cli download "$repo" "$file" \
        --local-dir "$(dirname "$out")" --local-dir-use-symlinks False --resume
    fi
    if [[ ! -s "$out" ]]; then
      fpath="$(find "$(dirname "$out")" -maxdepth 2 -type f -name "$(basename "$out")" | head -n1 || true)"
      [[ -n "${fpath:-}" ]] && mv -f "$fpath" "$out"
    fi
  }

  ########################################
  # UNET (Flux) – single official BFL file
  ########################################
  dl "black-forest-labs/FLUX.1-dev" "flux1-dev.safetensors" \
     "$MODEL_DIR/diffusion_models/flux1-dev.safetensors"

  ########################################
  # Text encoders (Flux)
  ########################################
  dl "comfyanonymous/flux_text_encoders" "clip_l.safetensors" \
     "$MODEL_DIR/text_encoders/clip_l.safetensors"
  dl "comfyanonymous/flux_text_encoders" "t5xxl_fp16.safetensors" \
     "$MODEL_DIR/text_encoders/t5xxl_fp16.safetensors"

  # --- VAE: Lumina 2.0 repack (ae.safetensors) ---
  VAE_OUT="$MODEL_DIR/vae/ae.safetensors"
  if [[ ! -s "$VAE_OUT" ]]; then
    echo "[DL] Lumina VAE -> $VAE_OUT"
    mkdir -p "$(dirname "$VAE_OUT")"
    curl -L \
      "https://huggingface.co/Comfy-Org/Lumina_Image_2.0_Repackaged/resolve/main/split_files/vae/ae.safetensors" \
      -o "$VAE_OUT"
  fi

  echo "[Models] Final check:"
  ls -lh "$MODEL_DIR/diffusion_models" || true
  ls -lh "$MODEL_DIR/text_encoders" || true
  ls -lh "$MODEL_DIR/vae" || true

  # ---- Preload DyPE workflow (Flux-DyPE.json) ----
  TEMPLATE_REPO="${TEMPLATE_REPO:-$ROOT/comfyui-lnodes}"
  TEMPLATE_WORKFLOW="$TEMPLATE_REPO/templates/dype/workflow/Flux-DyPE.json"
  TARGET_DIR="$COMFY/user/default/workflows"
  TARGET_FILE="$TARGET_DIR/Flux-DyPE.json"

  if [[ -f "$TEMPLATE_WORKFLOW" ]]; then
    echo "[Workflow] Installing DyPE template -> $TARGET_FILE"
    mkdir -p "$TARGET_DIR"
    cp -f "$TEMPLATE_WORKFLOW" "$TARGET_FILE"
  else
    echo "[Workflow] Template not found at $TEMPLATE_WORKFLOW (skipping)"
  fi

  # Mark heavy setup done so next boots are fast
  touch "$SETUP_FLAG"
  echo "[Setup] Heavy setup finished, flag created."
else
  echo "[Setup] Flag found – skipping heavy installs & downloads."
fi

# ---- Launch ComfyUI (clean boot) ----
echo "[Run] Starting ComfyUI on :$PORT"
pkill -f "ComfyUI/main.py" 2>/dev/null || true
cd "$COMFY"
exec python3 main.py --listen 0.0.0.0 --port "$PORT" --enable-cors-header --disable-metadata
