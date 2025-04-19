#!/bin/bash

set -e
echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# ⏱️ Timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && dpkg-reconfigure -f noninteractive tzdata

# 🔐 HuggingFace login
echo "🔐 Authenticating Hugging Face..."
huggingface-cli login --token $HF_TOKEN || true

# 🧠 Clone ComfyUI if not already
if [ ! -d "/workspace/ComfyUI" ]; then
    echo "🧠 Cloning ComfyUI..."
    git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
fi

# Safety check
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "❌ main.py missing. Aborting."
    exit 1
fi

cd /workspace/ComfyUI

# 📦 Pull nodes + workflows
echo "📦 Pulling custom nodes + workflows..."
rm -rf /tmp/lnodes
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes

mkdir -p custom_nodes workflows
cp -r /tmp/lnodes/custom_nodes/* custom_nodes/
cp -r /tmp/lnodes/workflows/* workflows/

# 🧩 Install ComfyUI Manager (redundant safety)
if [ ! -d "custom_nodes/ComfyUI-Manager" ]; then
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager
fi

# ✅ InstantID Requirements
echo "📁 Creating InstantID + FaceID folders..."
mkdir -p models/instantid
mkdir -p models/insightface/models/antelopev2

# 📥 Auto-download core models
echo "📥 Downloading LinkedIn essential models from Hugging Face..."
cd /workspace/ComfyUI/models

# Create base dirs
for folder in checkpoints clip configs controlnet ipadapter upscale_models vae clip_vision; do
    mkdir -p "$folder"
done

# Define needed files
declare -A hf_files
hf_files["checkpoints"]="realisticVisionV60B1_v51HyperVAE.safetensors"
hf_files["checkpoints-sdxl"]="sd_xl_base_1.0.safetensors"
hf_files["vae"]="sdxl_vae.safetensors"
hf_files["ipadapter"]="ip-adapter-plus-face_sdxl_vit-h.safetensors"
hf_files["controlnet"]="OpenPoseXL2.safetensors"
hf_files["upscale_models"]="RealESRGAN_x4plus.pth"
hf_files["clip_vision"]="CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"

# Download
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

# 🚀 Run ComfyUI
echo "🚀 Launching ComfyUI on port 8188..."
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188
