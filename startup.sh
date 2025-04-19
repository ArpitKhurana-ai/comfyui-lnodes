#!/bin/bash

set -e
echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# Set timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && \
dpkg-reconfigure -f noninteractive tzdata

# Hugging Face login
echo "🔐 Authenticating Hugging Face..."
huggingface-cli login --token $HF_TOKEN || true

# Move to safe working directory
cd /workspace || exit 1

# Clone or fix ComfyUI
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "🧹 Cleaning broken ComfyUI (if exists)..."
    rm -rf /workspace/ComfyUI
    git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
fi

# Safety check
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "❌ main.py missing. Aborting."
    exit 1
fi

cd /workspace/ComfyUI

# Step 2: Nodes + Workflows
echo "📦 Syncing custom nodes/workflows..."
rm -rf /tmp/lnodes
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes

mkdir -p custom_nodes workflows
cp -r /tmp/lnodes/custom_nodes/* custom_nodes/ || true
cp -r /tmp/lnodes/workflows/* workflows/ || true

# ComfyUI Manager
echo "🧩 Installing ComfyUI Manager..."
rm -rf custom_nodes/ComfyUI-Manager
git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager

# Step 3: Download models
echo "📥 Downloading models from Hugging Face..."
pip install -q huggingface_hub

cd /workspace/ComfyUI/models
for folder in checkpoints clip configs controlnet ipadapter upscale_models vae clip_vision insightface/antelopev2 instantid; do
    mkdir -p "$folder"
done

# List of models to fetch
declare -A hf_files
hf_files["checkpoints"]="realisticVisionV60B1_v51HyperVAE.safetensors"
hf_files["checkpoints2"]="sd_xl_base_1.0.safetensors"
hf_files["vae"]="sdxl_vae.safetensors"
hf_files["ipadapter"]="ip-adapter-plus-face_sdxl_vit-h.safetensors"
hf_files["controlnet"]="OpenPoseXL2.safetensors"
hf_files["upscale_models"]="RealESRGAN_x4plus.pth"
hf_files["clip_vision"]="CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
hf_files["instantid"]="ip-adapter.bin"
hf_files["insightface/antelopev2"]="det_10g.onnx"
hf_files["insightface/antelopev2_2"]="gf_10g.onnx"
hf_files["insightface/antelopev2_3"]="w600k_r50.onnx"

# Download each model
for key in "${!hf_files[@]}"; do
    folder=$(echo $key | cut -d_ -f1)  # strip _ suffix for subfolders
    filename="${hf_files[$key]}"
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

# Step 4: Run
echo "🚀 Launching ComfyUI on port 8188..."
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188

