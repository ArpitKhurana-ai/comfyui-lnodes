#!/usr/bin/env bash
set -euo pipefail

# --- Config (overridable) ---
ROOT="${ROOT:-/workspace}"
COMFY="$ROOT/ComfyUI"
PORT="${COMFY_PORT:-${PORT:-8188}}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"

# Models the workflow expects (exact filenames)
VAE_URL="${VAE_URL:-https://huggingface.co/Comfy-Org/Lumina_Image_2.0_Repackaged/resolve/main/split_files/vae/ae.safetensors}"
CLIP_URL="${CLIP_URL:-https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors}"
T5XXL_URL="${T5XXL_URL:-https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors}"

UNET_EXPECTED_PATH="$COMFY/models/diffusion_models/flux1-dev-fp8.safetensors"
# Optionally let user auto-provide UNet via URL (else they can mount/rename)
FLUX_UNET_URL="${FLUX_UNET_URL:-}"

log(){ echo "==> $*"; }

# --- 0) Sanity & GPU ---
log "Prepare workspace"
mkdir -p "$ROOT"
if ! command -v nvidia-smi >/dev/null 2>&1; then echo "ERROR: No GPU visible."; exit 2; fi
python3 - <<'PY'
import torch, sys; sys.exit(0 if torch.cuda.is_available() else 3)
PY

# --- 1) Ensure ComfyUI present ---
log "Ensure ComfyUI exists"
if [ -d "$COMFY/.git" ]; then
  git -C "$COMFY" fetch --depth 1 || true
  git -C "$COMFY" reset --hard HEAD || true
  git -C "$COMFY" pull --rebase || true
else
  rm -rf "$COMFY"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
fi

# --- 2) Install required custom nodes (idempotent) ---
log "Install required node packs"
mkdir -p "$COMFY/custom_nodes"

# KJNodes (for PatchSageAttentionKJ, ModelPatchTorchSettings)
if [ ! -d "$COMFY/custom_nodes/ComfyUI-KJNodes/.git" ]; then
  git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes "$COMFY/custom_nodes/ComfyUI-KJNodes" || true
else
  git -C "$COMFY/custom_nodes/ComfyUI-KJNodes" pull || true
fi

# DyPE nodes (for DyPE_FLUX)
if [ ! -d "$COMFY/custom_nodes/ComfyUI-DyPE/.git" ]; then
  git clone --depth 1 https://github.com/wildminder/ComfyUI-DyPE "$COMFY/custom_nodes/ComfyUI-DyPE" || true
else
  git -C "$COMFY/custom_nodes/ComfyUI-DyPE" pull || true
fi

# rgthree (Power Lora Loader, already hit earlier but keep it permanent)
if [ ! -d "$COMFY/custom_nodes/rgthree-comfy/.git" ]; then
  git clone --depth 1 https://github.com/rgthree/rgthree-comfy "$COMFY/custom_nodes/rgthree-comfy" || true
else
  git -C "$COMFY/custom_nodes/rgthree-comfy" pull || true
fi

# Optional: Manager to make updates easy via UI
if [ ! -d "$COMFY/custom_nodes/ComfyUI-Manager/.git" ]; then
  git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager "$COMFY/custom_nodes/ComfyUI-Manager" || true
fi

# --- 3) Install any node requirements.txt (quietly) ---
log "Install node Python requirements (if present)"
find "$COMFY/custom_nodes" -maxdepth 2 -type f -name requirements.txt -print0 | while IFS= read -r -d '' req; do
  echo " - $req"; python3 -m pip install -q -r "$req" || true
done

# --- 4) Models: ensure exact filenames in correct folders ---
log "Ensure model directories"
mkdir -p \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/vae"

download() {  # resumable
  local url="$1" out="$2"
  if [ -s "$out" ]; then log "exists: $(basename "$out")"; return 0; fi
  log "downloading: $(basename "$out")"
  curl -H "Accept: application/octet-stream" -fL -C - -o "$out" "$url"
}

log "Fetch VAE + text encoders to exact names"
download "$VAE_URL"  "$COMFY/models/vae/ae.safetensors"
download "$CLIP_URL" "$COMFY/models/text_encoders/clip_l.safetensors"
download "$T5XXL_URL" "$COMFY/models/text_encoders/t5xxl_fp16.safetensors"

if [ -n "$FLUX_UNET_URL" ] && [ ! -s "$UNET_EXPECTED_PATH" ]; then
  log "Fetch FLUX UNet to expected filename"
  download "$FLUX_UNET_URL" "$UNET_EXPECTED_PATH"
fi

# Warn if UNet still missing
if [ ! -f "$UNET_EXPECTED_PATH" ]; then
  echo "-----------------------------------------------------------------"
  echo "⚠️  Missing UNet expected by workflow:"
  echo "    $UNET_EXPECTED_PATH"
  echo "   Provide it by either:"
  echo "   - Setting FLUX_UNET_URL env to an accessible .safetensors"
  echo "   - Or mounting your file and renaming it to flux1-dev-fp8.safetensors"
  echo "   - Or edit the UNETLoader node in the workflow to your filename"
  echo "-----------------------------------------------------------------"
fi

# --- 5) Summary (helps confirm the UI 'missing model' dialog disappears) ---
log "Model summary"
ls -lh "$COMFY/models/vae/ae.safetensors" || true
ls -lh "$COMFY/models/text_encoders/clip_l.safetensors" || true
ls -lh "$COMFY/models/text_encoders/t5xxl_fp16.safetensors" || true
ls -lh "$COMFY/models/diffusion_models" || true

# --- 6) Launch ComfyUI (nodes now present, no class_type errors) ---
log "Launch ComfyUI on :$PORT"
cd "$COMFY"
python3 main.py --listen 0.0.0.0 --port "$PORT" --enable-cors-header --disable-metadata
