#!/bin/bash

set -xe

# ✅ Log everything to /app/startup.log
exec > >(tee /app/startup.log) 2>&1

echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# Set timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata

# Hugging Face login
echo "🔐 Authenticating Hugging Face..."
huggingface-cli login --token "$HF_TOKEN" || true

# Ensure we are in /workspace
cd /workspace || exit 1

# Clean broken ComfyUI if main.py missing
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "🧹 Cleaning broken ComfyUI (if exists)..."
    rm -rf /workspace/ComfyUI
    git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
fi

# Final check
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "❌ main.py still missing. Aborting."
    exit 1
fi

cd /workspace/ComfyUI

# Step 2: Sync custom nodes/workflows
echo "📦 Syncing custom nodes/workflows..."
rm -rf /tmp/lnodes
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes
mkdir -p custom_nodes workflows
cp -r /tmp/lnodes/custom_nodes/* custom_nodes/ || true
cp -r /tmp/lnodes/workflows/* workflows/ || true

# Step 3: Install ComfyUI Manager
echo "🧠 Installing ComfyUI Manager..."
rm -rf custom_nodes/ComfyUI-Manager
git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager

# Step 4: Install huggingface_hub if not already
echo "📦 Installing huggingface_hub..."
python3 -m pip install --quiet huggingface_hub

# Step 5: Create model folders safely
echo "📁 Creating model folders..."
cd /workspace/ComfyUI/models

folders=(
    "checkpoints"
    "clip"
    "configs"
    "controlnet"
    "ipadapter"
    "upscale_models"
    "vae"
    "clip_vision"
    "insightface/models/antelopev2"
    "instantid"
)

for folder in "${folders[@]}"; do
    echo "📁 Making folder: /workspace/ComfyUI/models/$folder"
    mkdir -p "/workspace/ComfyUI/models/$folder"
done

# Step 6: Download models from Hugging Face
echo "⬇️ Downloading model files..."

declare -A hf_files
hf_files["checkpoints"]="realisticVisionV60B1_v51HyperVAE.safetensors sd_xl_base_1.0.safetensors"
hf_files["vae"]="sdxl_vae.safetensors"
hf_files["ipadapter"]="ip-adapter-plus-face_sdxl_vit-h.safetensors"
hf_files["controlnet"]="OpenPoseXL2.safetensors"
hf_files["upscale_models"]="RealESRGAN_x4plus.pth"
hf_files["clip"]="CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
hf_files["instantid"]="ip-adapter.bin"
hf_files["insightface/models/antelopev2"]="1k3d68.onnx 2d106det.onnx genderage.onnx glintr100.onnx scrfd_10g_bnkps.onnx"

for folder in "${!hf_files[@]}"; do
  for filename in ${hf_files[$folder]}; do
    echo "⏬ Downloading $folder/$filename"
    python3 -c "
from huggingface_hub import hf_hub_download
hf_hub_download(
    repo_id='ArpitKhurana/comfyui-models',
    filename='$folder/$filename',
    local_dir='/workspace/ComfyUI/models/$folder',
    repo_type='model',
    token='$HF_TOKEN'
)"
  done
done

# ✅ Final Launch
echo "🚀 Launching ComfyUI on port 8188..."
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188
