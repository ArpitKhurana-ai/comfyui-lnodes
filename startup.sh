#!/bin/bash
set -xe

# 🔁 Clean logs
rm -rf /app/startup.log
exec > >(tee /app/startup.log) 2>&1

echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# Timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && dpkg-reconfigure -f noninteractive tzdata

# HF login
echo "🔐 Authenticating Hugging Face..."
huggingface-cli login --token "$HF_TOKEN" || true

# Set model path
export COMFYUI_MODELS_PATH="/workspace/models"
mkdir -p "$COMFYUI_MODELS_PATH"

cd /workspace || exit 1

# Clone ComfyUI if missing
if [ ! -f "ComfyUI/main.py" ]; then
    echo "🧹 Cloning ComfyUI..."
    rm -rf ComfyUI
    git clone https://github.com/comfyanonymous/ComfyUI.git
fi

# Link persistent models folder
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

# Custom nodes + workflows
echo "📦 Syncing custom nodes..."
rm -rf /tmp/lnodes
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes
mkdir -p custom_nodes workflows
cp -r /tmp/lnodes/custom_nodes/* custom_nodes/ || true
cp -r /tmp/lnodes/workflows/* workflows/ || true

# Manager + Impact Pack
rm -rf custom_nodes/ComfyUI-Manager custom_nodes/ComfyUI-Impact-Pack
git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager
git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git custom_nodes/ComfyUI-Impact-Pack
touch custom_nodes/ComfyUI-Impact-Pack/__init__.py

# Python dependencies
pip install --upgrade pip
pip install --quiet huggingface_hub onnxruntime-gpu insightface piexif segment-anything

# Prepare model subfolders
for folder in checkpoints clip configs controlnet ipadapter upscale_models vae clip_vision instantid insightface/models/antelopev2; do
  mkdir -p "$COMFYUI_MODELS_PATH/$folder"
  chmod -R 777 "$COMFYUI_MODELS_PATH/$folder"
done

# 🧹 OPTIONAL CLEANUP: Remove incorrect nesting from previous runs
rm -rf "$COMFYUI_MODELS_PATH/clip_vision/clip_vision"

# ✅ Download required model files (no nesting error)
declare -A hf_files=(
  [checkpoints]="realisticVisionV60B1_v51HyperVAE.safetensors sd_xl_base_1.0.safetensors"
  [vae]="sdxl.vae.safetensors"
  [ipadapter]="ip-adapter-plus-face_sdxl_vit-h.safetensors"
  [controlnet]="OpenPoseXL2.safetensors"
  [upscale_models]="RealESRGAN_x4plus.pth"
  [clip]="CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
  [clip_vision]="sdxl_vision_encoder.safetensors"
  [instantid]="ip-adapter.bin"
  [insightface/models/antelopev2]="1k3d68.onnx 2d106det.onnx genderage.onnx scrfd_10g_bnkps.onnx glintr100.onnx"
)

for folder in "${!hf_files[@]}"; do
  for filename in ${hf_files[$folder]}; do
    local_path="$COMFYUI_MODELS_PATH/$folder/$filename"
    if [ ! -f "$local_path" ]; then
      echo "⬇️ Downloading $folder/$filename"
      python3 - <<EOF
import os
from huggingface_hub import hf_hub_download

hf_hub_download(
    repo_id='ArpitKhurana/comfyui-models',
    filename='$filename',
    local_dir=os.path.join(os.environ['COMFYUI_MODELS_PATH'], '$folder'),
    repo_type='model',
    token=os.environ.get('HF_TOKEN', None)
)
EOF
    else
      echo "✅ Found: $folder/$filename"
    fi
    chmod -R 777 "$COMFYUI_MODELS_PATH/$folder"
  done
done

# ✅ Launch ComfyUI
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188 \
  > /workspace/comfyui.log 2>&1 &

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
