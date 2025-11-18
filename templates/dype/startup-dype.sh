#!/usr/bin/env bash
# DyPE + FLUX on top of an existing ComfyUI container
# - No Dockerfile edits
# - Minimal installs (no torch re-pin)
# - Reuse any existing FLUX.1-dev checkpoint on the volume
# - Preload Flux-DyPE workflow JSON from GitHub into ComfyUI

set -euo pipefail

# ----------------- Config -----------------
ROOT="${ROOT:-/workspace}"
COMFY="$ROOT/ComfyUI"
PORT="${PORT:-8188}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"

# First-run flag so heavy work happens only once per volume
SETUP_FLAG="$ROOT/.dype_setup_done_v3"

# Raw GitHub URL for your workflow JSON
WORKFLOW_URL="${WORKFLOW_URL:-https://raw.githubusercontent.com/ArpitKhurana-ai/comfyui-lnodes/main/templates/dype/workflow/Flux-DyPE.json}"

echo "=== [DyPE] bootstrap @ $(date) ==="
echo "[cfg] ROOT=$ROOT  COMFY=$COMFY  PORT=$PORT  FLAG=$SETUP_FLAG"
echo "[cfg] WORKFLOW_URL=$WORKFLOW_URL"

# ----------------- ComfyUI repo -----------------
if [[ ! -f "$COMFY/main.py" ]]; then
  echo "[ComfyUI] Not found, cloning fresh..."
  rm -rf "$COMFY"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  echo "[ComfyUI] Found (no pull to avoid extra delay)."
fi

# ================= HEAVY SETUP (ONCE PER VOLUME) =================
if [[ ! -f "$SETUP_FLAG" ]]; then
  echo "[Setup] First-time DyPE setup (this is the only slow boot for this volume)..."

  # ---- Python deps (VERY LIGHT) ----
  echo "[Py] Ensuring sageattention + huggingface_hub..."
  python3 -m pip install -q "sageattention==1.0.6" "huggingface_hub" || true

  # ---- Custom nodes ----
  echo "[Nodes] Ensuring required custom nodes..."
  mkdir -p "$COMFY/custom_nodes"
  cd "$COMFY/custom_nodes"

  if [[ ! -d "ComfyUI-DyPE" ]]; then
    git clone https://github.com/wildminder/ComfyUI-DyPE.git
  fi

  if [[ ! -d "ComfyUI-KJNodes" ]]; then
    git clone https://github.com/kijai/ComfyUI-KJNodes.git
  fi

  if [[ ! -d "rgthree-comfy" ]]; then
    git clone https://github.com/rgthree/rgthree-comfy.git
  fi

  if [[ ! -d "ComfyUI-Manager" ]]; then
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git || true
  fi

  # ---- Models ----
  echo "[Models] Ensuring model folders..."
  MODEL_DIR="$COMFY/models"
  mkdir -p \
    "$MODEL_DIR/diffusion_models" \
    "$MODEL_DIR/text_encoders" \
    "$MODEL_DIR/vae"

  dl() {  # repo file outpath
    local repo="$1"; local file="$2"; local out="$3"

    # 1) If already present at target, we're done
    if [[ -s "$out" ]]; then
      echo "[OK] $(basename "$out") already at target"
      return
    fi

    # 2) Try to reuse from elsewhere on volume to avoid re-download
    local basename
    basename="$(basename "$out")"
    echo "[Scan] Looking for existing $basename under $ROOT..."
    local found
    found="$(find "$ROOT" -maxdepth 6 -type f -name "$basename" 2>/dev/null | head -n1 || true)"

    if [[ -n "${found:-}" && -s "$found" ]]; then
      echo "[Reuse] Copying existing $basename from $found -> $out"
      mkdir -p "$(dirname "$out")"
      cp -n "$found" "$out"
      return
    fi

    # 3) Fallback: actual HF download
    echo "[DL] $repo :: $file  ->  $out"
    mkdir -p "$(dirname "$out")"
    if [[ -n "$HF_TOKEN" ]]; then
      HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" huggingface-cli download "$repo" "$file" \
        --local-dir "$(dirname "$out")" --local-dir-use-symlinks False --resume
    else
      huggingface-cli download "$repo" "$file" \
        --local-dir "$(dirname "$out")" --local-dir-use-symlinks False --resume
    fi

    # Some HF repos save into a subfolder – fix that
    if [[ ! -s "$out" ]]; then
      local fpath
      fpath="$(find "$(dirname "$out")" -maxdepth 2 -type f -name "$(basename "$out")" 2>/dev/null | head -n1 || true)"
      [[ -n "${fpath:-}" ]] && mv -f "$fpath" "$out"
    fi
  }

  # UNET (FLUX.1-dev) – single official file
  dl "black-forest-labs/FLUX.1-dev" "flux1-dev.safetensors" \
     "$MODEL_DIR/diffusion_models/flux1-dev.safetensors"

  # Text encoders for FLUX
  dl "comfyanonymous/flux_text_encoders" "clip_l.safetensors" \
     "$MODEL_DIR/text_encoders/clip_l.safetensors"
  dl "comfyanonymous/flux_text_encoders" "t5xxl_fp16.safetensors" \
     "$MODEL_DIR/text_encoders/t5xxl_fp16.safetensors"

  # VAE: Lumina 2.0 repack
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

  touch "$SETUP_FLAG"
  echo "[Setup] Done – future boots on this volume will skip heavy work."
else
  echo "[Setup] Flag present – skipping heavy installs/downloads."
fi

# ----------------- Preload workflow (EVERY BOOT) -----------------
echo "[Workflow] Installing Flux-DyPE workflow from GitHub..."

WF_TMP="$COMFY/Flux-DyPE.json"
if curl -fsSL "$WORKFLOW_URL" -o "$WF_TMP"; then
  echo "[Workflow] Downloaded to $WF_TMP"

  # 1) Built-in gallery (left sidebar categories)
  install -Dm644 "$WF_TMP" "$COMFY/web/assets/workflows/DyPE/Flux-DyPE.json"

  # 2) User workflows (shown in the Workflows sidebar)
  install -Dm644 "$WF_TMP" "$COMFY/user/default/workflows/Flux-DyPE.json"

  # 3) ComfyUI-Manager gallery (optional)
  install -Dm644 "$WF_TMP" "$COMFY/custom_nodes/ComfyUI-Manager/workflows/DyPE/Flux-DyPE.json" || true
else
  echo "[Workflow] ERROR: could not download $WORKFLOW_URL"
fi

# ----------------- Launch ComfyUI -----------------
echo "[Run] Starting ComfyUI on :$PORT"
pkill -f "ComfyUI/main.py" 2>/dev/null || true
cd "$COMFY"
exec python3 main.py --listen 0.0.0.0 --port "$PORT" --enable-cors-header --disable-metadata
