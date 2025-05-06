#!/bin/bash
set -xe

# 🔁 Clean logs
rm -rf /app/startup.log
exec > >(tee /app/startup.log) 2>&1

echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# Timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata

# Hugging Face login
echo "🔐 Authenticating Hugging Face..."
huggingface-cli login --token "$HF_TOKEN" || true

# Set persistent model path
export COMFYUI_MODELS_PATH="/workspace/models"
mkdir -p "$COMFYUI_MODELS_PATH"

cd /workspace || exit 1

# Clone ComfyUI if needed
if [ ! -f "ComfyUI/main.py" ]; then
    echo "🧹 Cloning ComfyUI..."
    rm -rf ComfyUI
    git clone https://github.com/comfyanonymous/ComfyUI.git
fi

# Link models folder
rm -rf ComfyUI/models
ln -s "$COMFYUI_MODELS_PATH" ComfyUI/models

# ✅ Symlink validation
if [ ! -L /workspace/ComfyUI/models ]; then
  echo "❌ Symlink creation failed for models folder."
  ls -l /workspace/ComfyUI
  exit 1
else
  echo "✅ Verified: /workspace/ComfyUI/models ➝ $COMFYUI_MODELS_PATH"
fi

cd ComfyUI

# Custom nodes & workflows
echo "📦 Syncing custom nodes..."
rm -rf /tmp/lnodes
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes
mkdir -p custom_nodes workflows
cp -r /tmp/lnodes/custom_nodes/* custom_nodes/ || true
cp -r /tmp/lnodes/workflows/* workflows/ || true

# Manager and Impact Pack
rm -rf custom_nodes/ComfyUI-Manager custom_nodes/ComfyUI-Impact-Pack
git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager
git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git custom_nodes/ComfyUI-Impact-Pack
touch custom_nodes/ComfyUI-Impact-Pack/__init__.py

# Dependencies
pip install --upgrade pip
pip install --quiet huggingface_hub onnxruntime-gpu insightface piexif segment-anything

# Model subfolders
for folder in checkpoints clip configs controlnet ipadapter upscale_models vae clip_vision instantid insightface/models/antelopev2; do
  mkdir -p "$COMFYUI_MODELS_PATH/$folder"
  chmod -R 777 "$COMFYUI_MODELS_PATH/$folder"
done

# 🧹 Cleanup nested clip_vision folder if exists
rm -rf "$COMFYUI_MODELS_PATH/clip_vision/clip_vision"

# ✅ Download all models via snapshot_download
echo "⬇️ Syncing all models using snapshot_download..."
python3 - <<EOF
import os
from huggingface_hub import snapshot_download

dst_dir = os.environ['COMFYUI_MODELS_PATH']
snapshot_download(
    repo_id='ArpitKhurana/comfyui-models',
    repo_type='model',
    local_dir=dst_dir,
    local_dir_use_symlinks=False,
    token=os.environ.get('HF_TOKEN', None)
)
EOF
chmod -R 777 "$COMFYUI_MODELS_PATH"

# ✅ Sanity checks (critical model presence)
echo "🔍 Checking critical model files..."

check_model() {
  local path="$COMFYUI_MODELS_PATH/$1"
  if [ ! -f "$path" ]; then
    echo "❌ ERROR: Required model not found: $path"
    exit 1
  else
    echo "✅ Found: $path"
  fi
}

check_model "checkpoints/sd_xl_base_1.0.safetensors"
check_model "checkpoints/realisticVisionV60B1_v51HyperVAE.safetensors"
check_model "vae/sdxl.vae.safetensors"
check_model "instantid/ip-adapter.bin"
check_model "controlnet/OpenPoseXL2.safetensors"
check_model "insightface/models/antelopev2/1k3d68.onnx"
check_model "insightface/models/antelopev2/glintr100.onnx"
check_model "clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"

echo "✅ All critical models are in place."

# ✅ Launch ComfyUI
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188 > /workspace/comfyui.log 2>&1 &

# ✅ Install and launch FileBrowser
cd /workspace
wget https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz -O fb.tar.gz
tar --no-same-owner -xvzf fb.tar.gz
chmod +x filebrowser
mv filebrowser /usr/local/bin/filebrowser
mkdir -p /workspace/filebrowser
chmod -R 777 /workspace/filebrowser

filebrowser \
  -r /workspace \
  --address 0.0.0.0 \
  -p 8080 \
  -d /workspace/filebrowser/filebrowser.db \
  > /workspace/filebrowser.log 2>&1 &

# ✅ Show open ports
ss -tulpn | grep LISTEN || true

# ✅ Tail logs
echo "📄 Tailing all logs..."
tail -f /workspace/comfyui.log /workspace/filebrowser.log
