#!/usr/bin/env bash
# DyPE + FLUX on top of an existing ComfyUI container
# - No Dockerfile edits
# - Pins PyTorch 2.4.x only if needed (skips if already correct)
# - Installs required node packs (DyPE, KJNodes, rgthree-comfy)
# - Ensures exact models are present in exact folders ComfyUI expects
# - Preloads the Flux-DyPE workflow JSON from this repo into ComfyUI

set -euo pipefail

# ---- Paths & config ----
ROOT="${ROOT:-/workspace}"
COMFY="$ROOT/ComfyUI"
PORT="${PORT:-8188}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"

# Directory of this script (your comfyui-lnodes repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== [DyPE] bootstrap @ $(date) ==="
echo "[cfg] ROOT=$ROOT  COMFY=$COMFY  PORT=$PORT"
echo "[cfg] SCRIPT_DIR=$SCRIPT_DIR"

# ---- ComfyUI repo ----
if [[ ! -f "$COMFY/main.py" ]]; then
  echo "[ComfyUI] Not found, cloning..."
  rm -rf "$COMFY"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  echo "[ComfyUI] Found — pulling latest (safe)..."
  (cd "$COMFY" && git fetch --all -p && git pull --rebase || true)
fi

# ---- PyTorch 2.4.x check + install (only if needed) ----
echo "[Py] Checking if Torch 2.4.1/cu121 stack is already installed..."
if ! python3 - <<'PY'
import sys

required = {
    "torch": "2.4.1",
    "torchvision": "0.19.1",
    "torchaudio": "2.4.1",
}

for name, want in required.items():
    try:
        m = __import__(name)
    except Exception:
        sys.exit(1)
    ver = getattr(m, "__version__", "")
    base = ver.split("+", 1)[0]
    if base != want:
        sys.exit(1)

sys.exit(0)
PY
then
  echo "[Py] Installing Torch 2.4.1/cu121 stack (first time only, large download)..."
  python3 -m pip install -U pip >/dev/null
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
else
  echo "[Py] Torch stack already at required versions – skipping reinstall."
fi

# ---- SageAttention for KJNodes PatchSageAttentionKJ ----
echo "[Py] Ensuring SageAttention is installed..."
python3 - <<'PY'
import importlib, subprocess, sys

try:
    importlib.import_module("sageattention")
except Exception:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "sageattention==1.0.6", "--no-build-isolation"])
PY

# Ensure huggingface-cli exists (small, one-time)
python3 -m pip install -q "huggingface_hub" >/dev/null 2>&1 || true

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
    HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" huggingface-cli download "$repo" "$file" \
      --local-dir "$(dirname "$out")" --local-dir-use-symlinks False
  else
    huggingface-cli download "$repo" "$file" \
      --local-dir "$(dirname "$out")" --local-dir-use-symlinks False
  fi
  if [[ ! -s "$out" ]]; then
    # try to move from cache name to final path if needed
    local fpath
    fpath="$(find "$(dirname "$out")" -maxdepth 3 -type f -name "$(basename "$out")" | head -n1 || true)"
    [[ -n "${fpath:-}" && "$fpath" != "$out" ]] && mv -f "$fpath" "$out"
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

# ---- Preload DyPE workflow from this repo ----
TEMPLATE_WORKFLOW="$SCRIPT_DIR/templates/dype/workflow/Flux-DyPE.json"
TARGET_DIR="$COMFY/user/default/workflows"
TARGET_FILE="$TARGET_DIR/Flux-DyPE.json"

if [[ -f "$TEMPLATE_WORKFLOW" ]]; then
  echo "[Workflow] Installing DyPE template -> $TARGET_FILE"
  mkdir -p "$TARGET_DIR"
  cp -f "$TEMPLATE_WORKFLOW" "$TARGET_FILE"
else
  echo "[Workflow] Template not found at $TEMPLATE_WORKFLOW (skipping)"
fi

# ---- Launch ComfyUI (clean boot) ----
echo "[Run] Starting ComfyUI on :$PORT"
pkill -f "ComfyUI/main.py" 2>/dev/null || true
cd "$COMFY"
exec python3 main.py --listen 0.0.0.0 --port "$PORT" --enable-cors-header --disable-metadata
