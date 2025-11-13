#!/usr/bin/env bash
# DyPE + FLUX on top of an existing ComfyUI container
# - No Dockerfile edits
# - Pins PyTorch 2.4.x to avoid torch.compiler errors
# - Installs required node packs (DyPE, KJNodes, rgthree-comfy)
# - Ensures exact models are present in exact folders ComfyUI expects

set -euo pipefail

# ---- Config (override via env if you like) ----
ROOT="${ROOT:-/workspace}"
COMFY="$ROOT/ComfyUI"
PORT="${PORT:-8188}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"

echo "=== [DyPE] bootstrap @ $(date) ==="
echo "[cfg] ROOT=$ROOT  COMFY=$COMFY  PORT=$PORT"

# ---- Sanity: ComfyUI presence ----
if [[ ! -f "$COMFY/main.py" ]]; then
  echo "[ComfyUI] Not found, cloning..."
  rm -rf "$COMFY"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  echo "[ComfyUI] Found — pulling latest (safe)..."
  (cd "$COMFY" && git fetch --all -p && git pull --rebase || true)
fi

# ---- Python deps: pin torch 2.4.x (fixes torch.compiler attribute) ----
echo "[Py] Pinning PyTorch 2.4.x (CUDA 12.1 wheels are broadly compatible on RunPod)..."
python3 -m pip install -U pip >/dev/null
# If your base already has 2.5+, force-downgrade:
python3 - <<'PY'
import subprocess, sys
def pip(*args): subprocess.check_call([sys.executable, "-m", "pip", *args])
# Prefer cu121 for widest availability
pip("install","--upgrade","--extra-index-url","https://download.pytorch.org/whl/cu121",
    "torch==2.4.1","torchvision==0.19.1","torchaudio==2.4.1")
PY

# ---- Required node packs ----
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

# Nice-to-have: Manager (but we won’t rely on it for install)
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
    echo "[OK] $(basename "$out")"
    return
  fi
  echo "[DL] $repo :: $file  ->  $out"
  mkdir -p "$(dirname "$out")"
  if [[ -n "$HF_TOKEN" ]]; then
    HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" huggingface-cli download "$repo" "$file" --local-dir "$(dirname "$out")" --local-dir-use-symlinks False --resume
  else
    huggingface-cli download "$repo" "$file" --local-dir "$(dirname "$out")" --local-dir-use-symlinks False --resume
  fi
  if [[ ! -s "$out" ]]; then
    fpath="$(find "$(dirname "$out")" -maxdepth 2 -type f -name "$(basename "$out")" | head -n1 || true)"
    [[ -n "${fpath:-}" ]] && mv -f "$fpath" "$out"
  fi
}

# UNET (Flux)
dl "black-forest-labs/FLUX.1-dev" "flux1-dev.safetensors" \
   "$MODEL_DIR/diffusion_models/flux1-dev.safetensors"

# Text encoders (Flux)
dl "comfyanonymous/flux_text_encoders" "clip_l.safetensors" \
   "$MODEL_DIR/text_encoders/clip_l.safetensors"
dl "comfyanonymous/flux_text_encoders" "t5xxl_fp16.safetensors" \
   "$MODEL_DIR/text_encoders/t5xxl_fp16.safetensors"

# ---- VAE (ae.safetensors) — robust fetch with direct-URL fallback ----
VAE_OUT="$MODEL_DIR/vae/ae.safetensors"
VAE_URL_RESOLVE="https://huggingface.co/Comfy-Org/Lumina_Image_2.0_Repackaged/resolve/main/split_files/vae/ae.safetensors"
if [[ ! -s "$VAE_OUT" ]]; then
  echo "[VAE] Fetching ae.safetensors…"
  # 1) Try direct URL with resume (most reliable across environments)
  curl -H "Accept: application/octet-stream" -fL -C - -o "${VAE_OUT}.part" "$VAE_URL_RESOLVE" || true
  [[ -s "${VAE_OUT}.part" ]] && mv -f "${VAE_OUT}.part" "$VAE_OUT"
  # 2) Fallback to huggingface-cli from madebyollin if still missing
  if [[ ! -s "$VAE_OUT" ]]; then
    echo "[VAE] Direct URL fallback failed, trying madebyollin/ae-sdxl-v1 via HF CLI…"
    huggingface-cli download "madebyollin/ae-sdxl-v1" "ae.safetensors" \
      --local-dir "$MODEL_DIR/vae" --local-dir-use-symlinks False --resume || true
  fi
  # 3) Final hard check
  if [[ ! -s "$VAE_OUT" ]]; then
    echo "❌ VAE missing at $VAE_OUT"
    echo "   Manual one-liner:"
    echo "   curl -fL -C - '$VAE_URL_RESOLVE' -o '$VAE_OUT'"
    exit 14
  fi
fi

echo "[Models] Final check:"
ls -lh "$MODEL_DIR/diffusion_models" || true
ls -lh "$MODEL_DIR/text_encoders" || true
ls -lh "$MODEL_DIR/vae" || true

# ---- Launch ComfyUI (clean boot) ----
echo "[Run] Starting ComfyUI on :$PORT"
pkill -f "ComfyUI/main.py" 2>/dev/null || true
cd "$COMFY"
exec python3 main.py --listen 0.0.0.0 --port "$PORT" --enable-cors-header --disable-metadata
