#!/bin/bash

set -xe

# 🔁 Clean previous logs
rm -rf /app/startup.log

# ✅ Log all output to a file
exec > >(tee /app/startup.log) 2>&1

echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# ✅ Set timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata

# ✅ Authenticate Hugging Face
echo "🔐 Authenticating Hugging Face..."
huggingface-cli login --token "$HF_TOKEN" || true

# ✅ Setup persistent model path
export COMFYUI_MODELS_PATH="/workspace/models"
mkdir -p "$COMFYUI_MODELS_PATH"

# ✅ Navigate to /workspace
cd /workspace || exit 1

# ✅ Clone ComfyUI if missing
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "🧹 Cloning fresh ComfyUI..."
    rm -rf /workspace/ComfyUI
    git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
fi

# ✅ Symlink models folder
rm -rf /workspace/ComfyUI/models
ln -s "$COMFYUI_MODELS_PATH" /workspace/ComfyUI/models

cd /workspace/ComfyUI

# ✅ Sync custom nodes & workflows
echo "📦 Syncing custom nodes and workflows..."
rm -rf /tmp/lnodes

# Replace this repo URL with yours
NODE_REPO="https://github.com/ArpitKhurana-ai/comfyui-lnodes.git"
git clone "$NODE_REPO" /tmp/lnodes
mkdir -p custom_nodes workflows
cp -r /tmp/lnodes/custom_nodes/* custom_nodes/ || true
cp -r /tmp/lnodes/workflows/* workflows/ || true

# ✅ Install ComfyUI Manager
rm -rf custom_nodes/ComfyUI-Manager
git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager

# ✅ Install ComfyUI Impact-Pack
rm -rf custom_nodes/ComfyUI-Impact-Pack
git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git custom_nodes/ComfyUI-Impact-Pack

# ✅ Ensure __init__.py in Impact-Pack
impact_path="custom_nodes/ComfyUI-Impact-Pack"
if [ -d "$impact_path" ] && [ ! -f "$impact_path/__init__.py" ]; then
    touch "$impact_path/__init__.py"
fi

# ✅ Upgrade pip and install Python dependencies
pip install --upgrade pip
pip install --quiet huggingface_hub onnxruntime-gpu insightface piexif segment-anything jupyterlab notebook

# ✅ Create required model folders
folders=(
    "checkpoints" "clip" "configs" "controlnet" "ipadapter"
    "upscale_models" "vae" "clip_vision" "instantid" "insightface/models/antelopev2"
)
for folder in "${folders[@]}"; do
    mkdir -p "$COMFYUI_MODELS_PATH/$folder"
    chmod -R 777 "$COMFYUI_MODELS_PATH/$folder"
done

# ✅ Sync models from Hugging Face
echo "⬇️ Syncing models from Hugging Face..."
declare -A hf_files
hf_files["checkpoints"]="realisticVisionV60B1_v51HyperVAE.safetensors sd_xl_base_1.0.safetensors"
hf_files["vae"]="sdxl.vae.safetensors"
hf_files["ipadapter"]="ip-adapter-plus-face_sdxl_vit-h.safetensors"
hf_files["controlnet"]="OpenPoseXL2.safetensors"
hf_files["upscale_models"]="RealESRGAN_x4plus.pth"
hf_files["clip"]="CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
hf_files["clip_vision"]="sdxl_vision_encoder.safetensors"
hf_files["instantid"]="ip-adapter.bin"
hf_files["insightface/models/antelopev2"]="1k3d68.onnx 2d106det.onnx genderage.onnx scrfd_10g_bnkps.onnx glintr100.onnx"

for folder in "${!hf_files[@]}"; do
  for filename in ${hf_files[$folder]}; do
    local_path="$COMFYUI_MODELS_PATH/$folder/$filename"
    if [ ! -f "$local_path" ]; then
      echo "⏳ Downloading $folder/$filename"
      python3 -c "
import os
from huggingface_hub import hf_hub_download
hf_hub_download(
  repo_id='ArpitKhurana/comfyui-models',
  filename='$folder/$filename',
  local_dir='$COMFYUI_MODELS_PATH/$folder',
  repo_type='model',
  token=os.environ['HF_TOKEN']
)"
    else
      echo "✅ Found (skipping): $folder/$filename"
    fi
  done
  chmod -R 777 "$COMFYUI_MODELS_PATH/$folder"
done

# ✅ Launch ComfyUI
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188 > /workspace/comfyui.log 2>&1 &

# ✅ Launch JupyterLab
python3 -m jupyter lab \
    --ip=0.0.0.0 \
    --port=8888 \
    --no-browser \
    --allow-root \
    --NotebookApp.token='e1224bcd5b82a0bf4153a47c3f7668fddd1310cc0422f35c' \
    > /workspace/jupyter.log 2>&1 &

# ✅ Install and launch FileBrowser
echo "🌐 Installing FileBrowser..."
curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
mkdir -p /workspace/filebrowser
chmod -R 777 /workspace/filebrowser
./filebrowser -r /workspace -p 8080 -d /workspace/filebrowser/filebrowser.db > /workspace/filebrowser.log 2>&1 &

# ✅ Show ports and tail logs
netstat -tulpn | grep LISTEN || true

echo "📄 Tailing logs..."
tail -f /workspace/comfyui.log /workspace/jupyter.log /workspace/filebrowser.log
