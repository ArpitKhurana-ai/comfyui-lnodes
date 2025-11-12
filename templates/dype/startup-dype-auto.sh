#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/workspace}"
COMFY="$ROOT/ComfyUI"
PORT="${COMFY_PORT:-${PORT:-8188}}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"

# Exact filenames the workflow uses
VAE_URL="${VAE_URL:-https://huggingface.co/Comfy-Org/Lumina_Image_2.0_Repackaged/resolve/main/split_files/vae/ae.safetensors}"
CLIP_URL="${CLIP_URL:-https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors}"
T5XXL_URL="${T5XXL_URL:-https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp16.safetensors}"

UNET_DIR="$COMFY/models/diffusion_models"
UNET_EXPECTED="$UNET_DIR/flux1-dev-fp8.safetensors"
UNET_FALLBACK_MODEL_ID="${UNET_FALLBACK_MODEL_ID:-black-forest-labs/FLUX.1-dev}"
UNET_FALLBACK_FILENAME="${UNET_FALLBACK_FILENAME:-flux1-dev.safetensors}"
FLUX_UNET_URL="${FLUX_UNET_URL:-}"   # optional direct URL

log(){ echo "==> $*"; }

# --- 0) GPU & base ---
mkdir -p "$ROOT"
if ! command -v nvidia-smi >/dev/null 2>&1; then echo "ERROR: GPU not visible"; exit 2; fi
python3 - <<'PY'
import torch, sys
# Just exit code indicates if CUDA is usable
sys.exit(0 if torch.cuda.is_available() else 3)
PY

# --- 1) Ensure correct Torch (provide torch.compiler.is_compiling) ---
python3 - <<'PY'
import os, sys
try:
    import torch
    ok = False
    try:
        import torch.compiler as tc
        ok = hasattr(tc, "is_compiling")
    except Exception:
        ok = False
    if not ok:
        sys.exit(10)
except Exception:
    sys.exit(10)
PY
if [ $? -ne 0 ]; then
  echo "==> Upgrading PyTorch to a build that includes torch.compiler.is_compiling"
  # Detect existing CUDA and choose wheels
  CUDA_VER=$(python3 - <<'PY'
import sys
try:
    import torch
    print(torch.version.cuda or "")
except Exception:
    print("")
PY
)
  # Default to cu121 (most RunPod bases)
  INDEX_URL="https://download.pytorch.org/whl/cu121"
  TORCH_SPEC="torch==2.4.0 torchvision==0.19.0 torchaudio==2.4.0"
  if echo "$CUDA_VER" | grep -q "12.4"; then
    INDEX_URL="https://download.pytorch.org/whl/cu124"
    TORCH_SPEC="torch==2.5.1 torchvision==0.20.1 torchaudio==2.5.1"
  fi
  pip install --upgrade --extra-index-url "$INDEX_URL" $TORCH_SPEC
fi

python3 -m pip install -q --upgrade pip huggingface_hub || true

# --- 2) Ensure ComfyUI ---
if [ -d "$COMFY/.git" ]; then
  git -C "$COMFY" fetch --depth 1 || true
  git -C "$COMFY" reset --hard HEAD || true
  git -C "$COMFY" pull --rebase || true
else
  rm -rf "$COMFY"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
fi

# --- 3) Required node packs ---
mkdir -p "$COMFY/custom_nodes"
if [ ! -d "$COMFY/custom_nodes/ComfyUI-DyPE/.git" ]; then
  git clone --depth 1 https://github.com/wildminder/ComfyUI-DyPE "$COMFY/custom_nodes/ComfyUI-DyPE" || true
else
  git -C "$COMFY/custom_nodes/ComfyUI-DyPE" pull || true
fi
if [ ! -d "$COMFY/custom_nodes/ComfyUI-KJNodes/.git" ]; then
  git clone --depth 1 https://github.com/kijai/ComfyUI-KJNodes "$COMFY/custom_nodes/ComfyUI-KJNodes" || true
else
  git -C "$COMFY/custom_nodes/ComfyUI-KJNodes" pull || true
fi
if [ ! -d "$COMFY/custom_nodes/rgthree-comfy/.git" ]; then
  git clone --depth 1 https://github.com/rgthree/rgthree-comfy "$COMFY/custom_nodes/rgthree-comfy" || true
else
  git -C "$COMFY/custom_nodes/rgthree-comfy" pull || true
fi
# Install any node requirements quietly
find "$COMFY/custom_nodes" -maxdepth 2 -type f -name requirements.txt -print0 | while IFS= read -r -d '' r; do
  python3 -m pip install -q -r "$r" || true
done

# --- 4) Models (exact filenames) ---
mkdir -p "$UNET_DIR" "$COMFY/models/text_encoders" "$COMFY/models/vae"
download () {  # resumable
  local url="$1" out="$2"
  if [ -s "$out" ]; then log "exists: $(basename "$out")"; return 0; fi
  log "downloading: $(basename "$out")"
  curl -H "Accept: application/octet-stream" -fL -C - -o "$out" "$url"
}
download "$VAE_URL"   "$COMFY/models/vae/ae.safetensors"
download "$CLIP_URL"  "$COMFY/models/text_encoders/clip_l.safetensors"
download "$T5XXL_URL" "$COMFY/models/text_encoders/t5xxl_fp16.safetensors"

# UNet: expected filename
if [ ! -s "$UNET_EXPECTED" ]; then
  CAND="$(find "$UNET_DIR" -maxdepth 1 -type f -name 'flux*.safetensors' | head -n1 || true)"
  if [ -n "${CAND:-}" ]; then
    ln -sf "$CAND" "$UNET_EXPECTED"
  elif [ -n "$FLUX_UNET_URL" ]; then
    download "$FLUX_UNET_URL" "$UNET_EXPECTED"
  else
    python3 - <<PY
import os
from huggingface_hub import hf_hub_download
p = hf_hub_download(repo_id=os.environ.get("UNET_FALLBACK_MODEL_ID","black-forest-labs/FLUX.1-dev"),
                    filename=os.environ.get("UNET_FALLBACK_FILENAME","flux1-dev.safetensors"),
                    local_dir=os.path.join(os.environ["COMFY"],"models","diffusion_models"),
                    local_dir_use_symlinks=False,
                    token=os.environ.get("HF_TOKEN"))
print("downloaded:", p)
PY
    [ -f "$UNET_DIR/$UNET_FALLBACK_FILENAME" ] && ln -sf "$UNET_DIR/$UNET_FALLBACK_FILENAME" "$UNET_EXPECTED"
  fi
fi

# --- 5) Launch ---
cd "$COMFY"
exec python3 main.py --listen 0.0.0.0 --port "$PORT" --enable-cors-header --disable-metadata
