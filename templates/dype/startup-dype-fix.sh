#!/usr/bin/env bash
set -euo pipefail

# --- settings ---
ROOT="${ROOT:-/workspace}"
COMFY="$ROOT/ComfyUI"
PORT="${COMFY_PORT:-${PORT:-8188}}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"

log(){ echo "==> $*"; }

log "Step 0: prepare"
mkdir -p "$ROOT"

# GPU sanity
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: GPU driver not visible. Exiting."; exit 2
fi
python3 - <<'PY'
import torch, sys
sys.exit(0 if torch.cuda.is_available() else 3)
PY

# --- ensure ComfyUI present ---
log "Step 1: ensure ComfyUI"
if [ -d "$COMFY/.git" ]; then
  git -C "$COMFY" pull || true
else
  rm -rf "$COMFY"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
fi

# --- install missing nodes (rgthree for Power Lora Loader) ---
log "Step 2: install rgthree nodes (Power Lora Loader)"
mkdir -p "$COMFY/custom_nodes"
if [ ! -d "$COMFY/custom_nodes/rgthree-comfy/.git" ]; then
  git clone --depth 1 https://github.com/rgthree/rgthree-comfy "$COMFY/custom_nodes/rgthree-comfy" || true
else
  git -C "$COMFY/custom_nodes/rgthree-comfy" pull || true
fi

# (Optional but handy)
if [ ! -d "$COMFY/custom_nodes/ComfyUI-Manager/.git" ]; then
  git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager "$COMFY/custom_nodes/ComfyUI-Manager" || true
fi

# --- model folders (these are the scan paths ComfyUI uses) ---
mkdir -p \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/vae"

# --- resumable downloader ---
fetch () {
  local url="$1" out="$2"
  if [ -s "$out" ]; then log "exists: $(basename "$out")"; ls -lh "$out"; return 0; fi
  log "downloading: $(basename "$out")"
  curl -H "Accept: application/octet-stream" -fL -C - -o "$out" "$url"
  ls -lh "$out"
}

# --- EXACT files the workflow expects ---
log "Step 3: fetch required VAE and text encoders to exact filenames"
fetch "https://huggingface.co/Comfy-Org/Lumina_Image_2.0_Repackaged/resolve/main/split_files/vae/ae.safetensors" \
      "$COMFY/models/vae/ae.safetensors"

fetch "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors" \
      "$COMFY/models/text_encoders/clip_l.safetensors"

fetch "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors" \
      "$COMFY/models/text_encoders/t5xxl_fp16.safetensors"

# --- FLUX UNet checkpoint name the workflow references ---
# The graph expects: models/diffusion_models/flux1-dev-fp8.safetensors
# If your file has a different name, either:
#   (A) rename it to flux1-dev-fp8.safetensors, or
#   (B) change the UNETLoader node in the workflow to whatever you have.
UNET_EXPECTED="$COMFY/models/diffusion_models/flux1-dev-fp8.safetensors"

if [ ! -f "$UNET_EXPECTED" ]; then
  echo "-----------------------------------------------------------------"
  echo "⚠️  FLUX UNet missing: $UNET_EXPECTED"
  echo "   Put your FLUX.1 dev FP8 file here, e.g.:"
  echo "     $UNET_EXPECTED"
  echo "   (Or update the workflow UNETLoader name to match your file.)"
  echo "-----------------------------------------------------------------"
fi

# --- quick summary of what ComfyUI will see ---
log "Step 4: model summary"
ls -lh "$COMFY/models/vae/ae.safetensors" || true
ls -lh "$COMFY/models/text_encoders/clip_l.safetensors" || true
ls -lh "$COMFY/models/text_encoders/t5xxl_fp16.safetensors" || true
ls -lh "$COMFY/models/diffusion_models" || true

# --- launch ComfyUI ---
log "Step 5: launch ComfyUI"
cd "$COMFY"
python3 main.py --listen 0.0.0.0 --port "$PORT" --enable-cors-header --disable-metadata
