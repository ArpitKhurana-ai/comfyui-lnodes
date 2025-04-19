#!/bin/bash

set -e
echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# Set timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && \
dpkg-reconfigure -f noninteractive tzdata

# Hugging Face login
echo "🔐 Authenticating Hugging Face..."
huggingface-cli login --token $HF_TOKEN || true

# Avoid being inside ComfyUI before deleting
cd /workspace || exit 1

# Clean if broken
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "🧹 Cleaning bad ComfyUI folder..."
    rm -rf /workspace/ComfyUI
    git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
fi

# Safety check again
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "❌ main.py missing. Aborting."
    exit 1
fi

cd /workspace/ComfyUI

# Step 2: Nodes + workflows
echo "📦 Syncing custom nodes/workflows..."
rm -rf /tmp/lnodes
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes

mkdir -p custom_nodes workflows
cp -r /tmp/lnodes/custom_nodes/* custom_nodes/ || true
cp -r /tmp/lnodes/workflows/* workflows/ || true

# Step 2b: ComfyUI Manager
echo "🧩 Installing ComfyUI Manager..."
rm -rf custom_nodes/ComfyUI-Manager
git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager

# Step 3: Models
echo "📥 Downloading models from Hugging Face..."
pip install -q huggingface_hub

cd /workspace/ComfyUI/models
for folder in checkpoints clip configs controlnet ipadapter upscale_models vae clip_vision insightface/antelopev2 instantid; do
    mkdir -p "$folder"
done

declare -A hf_files
hf_files["checkpoints"]="realisticVisionV60B1_v51HyperVAE.safetensors"
hf_files["checkpoints2"]="sd_xl_base_1.0.safetensors"
hf_files["vae"]="sdxl_vae.safetensors"
hf_files["ipadapter"]="ip-adapter-plus-face_sdxl_vit-h.safetensors"
hf_files["controlnet"]="OpenPoseXL2.safetensors"
hf_files["upscale_models"]="RealESRGAN_x4plus.pth"
hf_files["clip_vision"]="CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
hf_files["instantid"]="ip-adapter.bin"

for folder in "${!hf_files[@]}"; do
    filename="${hf_files[$folder]}"
    echo "⏬ $folder/$filename"
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

# ✅ Launch ComfyUI
echo "🚀 Starting ComfyUI on port 8188..."
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188
