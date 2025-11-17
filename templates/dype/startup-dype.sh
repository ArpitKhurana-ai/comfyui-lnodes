#!/usr/bin/env bash
# DyPE + FLUX FP8 + FLUX FP16 bootstrap for ComfyUI
# Safe: minimal changes, only model installs + workflow preload

set -euo pipefail

ROOT="${ROOT:-/workspace}"
COMFY="$ROOT/ComfyUI"
PORT="${PORT:-8188}"
HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"

echo "=== [DyPE Bootstrap] $(date) ==="
echo "[cfg] ROOT=$ROOT | COMFY=$COMFY | PORT=$PORT"

# -------------------------------
# Ensure ComfyUI exists
# -------------------------------
if [[ ! -f "$COMFY/main.py" ]]; then
  echo "[ComfyUI] Missing — cloning..."
  rm -rf "$COMFY"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  echo "[ComfyUI] Found — pulling latest..."
  (cd "$COMFY" && git fetch --all -p && git pull --rebase || true)
fi

# -------------------------------
# Python deps: Torch 2.4.1
# -------------------------------
echo "[Py] Installing Torch 2.4.1 (cu121 wheels)..."
python3 -m pip install -U pip >/dev/null

python3 - <<'PY'
import subprocess, sys
def pip(*args): subprocess.check_call([sys.executable, "-m", "pip", *args])
pip("install","--upgrade","--extra-index-url","https://download.pytorch.org/whl/cu121",
    "torch==2.4.1","torchvision==0.19.1","torchaudio==2.4.1")
PY

echo "[Py] Installing SageAttention..."
python3 -m pip install "sageattention==1.0.6" --no-build-isolation


# -------------------------------
# Custom nodes
# -------------------------------
echo "[Nodes] Installing custom nodes..."
mkdir -p "$COMFY/custom_nodes"
cd "$COMFY/custom_nodes"

install_node() {
  local repo="$1"
  local folder="$2"
  if [[ ! -d "$folder" ]]; then
    git clone "$repo" "$folder"
  else
    (cd "$folder" && git pull --rebase || true)
  fi
}

install_node https://github.com/wildminder/ComfyUI-DyPE.git ComfyUI-DyPE
install_node https://github.com/kijai/ComfyUI-KJNodes.git ComfyUI-KJNodes
install_node https://github.com/rgthree/rgthree-comfy.git rgthree-comfy
install_node https://github.com/ltdrdata/ComfyUI-Manager.git ComfyUI-Manager || true


# -------------------------------
# Models
# -------------------------------
MODEL_DIR="$COMFY/models"
mkdir -p "$MODEL_DIR/diffusion_models" "$MODEL_DIR/text_encoders" "$MODEL_DIR/vae"

dl() {
  local repo="$1"; local file="$2"; local out="$3"

  if [[ -s "$out" ]]; then
    echo "[OK] Already downloaded: $(basename "$out")"
    return
  fi

  echo "[DL] $file from $repo"
  mkdir -p "$(dirname "$out")"

  if [[ -n "$HF_TOKEN" ]]; then
    HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" huggingface-cli download "$repo" "$file" \
      --local-dir "$(dirname "$out")" \
      --local-dir-use-symlinks False \
      --resume
  else
    huggingface-cli download "$repo" "$file" \
      --local-dir "$(dirname "$out")" \
      --local-dir-use-symlinks False \
      --resume
  fi

  # Fix nested dirs if needed
  if [[ ! -s "$out" ]]; then
    f="$(find "$(dirname "$out")" -maxdepth 3 -type f -name "$(basename "$out")" | head -n1 || true)"
    [[ -n "${f:-}" ]] && mv -f "$f" "$out"
  fi
}

# FLUX FP8
dl "black-forest-labs/FLUX.1-dev" \
   "flux1-dev.safetensors" \
   "$MODEL_DIR/diffusion_models/flux1-dev.safetensors"

# FLUX FP16 (NEW)
dl "black-forest-labs/FLUX.1-dev-fp16" \
   "flux1-dev-fp16.safetensors" \
   "$MODEL_DIR/diffusion_models/flux1-dev-fp16.safetensors"

# Text encoders
dl "comfyanonymous/flux_text_encoders" \
   "clip_l.safetensors" \
   "$MODEL_DIR/text_encoders/clip_l.safetensors"

dl "comfyanonymous/flux_text_encoders" \
   "t5xxl_fp16.safetensors" \
   "$MODEL_DIR/text_encoders/t5xxl_fp16.safetensors"

# VAE (Lumina VAE)
curl -L \
  "https://huggingface.co/Comfy-Org/Lumina_Image_2.0_Repackaged/resolve/main/split_files/vae/ae.safetensors" \
  -o "$MODEL_DIR/vae/ae.safetensors"


# -------------------------------
# Preload your workflow
# -------------------------------
echo "[Workflow] Injecting Flux-DyPE.json"

mkdir -p "$COMFY/workflows"

# THIS IS THE KEY FIX — correct repo path
WF_SRC="$ROOT/comfyui-lnodes/templates/dype/workflow/Flux-DyPE.json"
WF_DEST="$COMFY/workflows/Flux-DyPE.json"

if [[ -f "$WF_SRC" ]]; then
  cp "$WF_SRC" "$WF_DEST"
  echo "[Workflow] Copied: $WF_SRC → $WF_DEST"
else
  echo "[Workflow] WARNING: Workflow file missing at: $WF_SRC"
fi


# -------------------------------
# Launch ComfyUI
# -------------------------------
echo "[Run] Starting ComfyUI on :$PORT"
pkill -f "ComfyUI/main.py" || true
cd "$COMFY"

exec python3 main.py \
  --listen 0.0.0.0 \
  --port "$PORT" \
  --enable-cors-header \
  --disable-metadata
