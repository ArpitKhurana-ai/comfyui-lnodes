#!/bin/bash

set -e

echo "\U0001F7E1 Starting ComfyUI LinkedIn Edition Setup..."

# Timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata

# Hugging Face login
echo "\U0001F512 Authenticating Hugging Face..."
huggingface-cli login --token "$HF_TOKEN" || true

# Ensure we are not in the ComfyUI directory when removing it
cd /workspace || exit 1

# Clean broken ComfyUI if main.py missing
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "\U0001F9F9 Cleaning broken ComfyUI (if exists)..."
    rm -rf /workspace/ComfyUI
    git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
fi

# Safety check again
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "\u274C main.py still missing. Aborting."
    exit 1
fi

cd /workspace/ComfyUI

# Step 2: Custom nodes & workflows
echo "\U0001F4E6 Syncing custom nodes/workflows..."
rm -rf /tmp/lnodes

# Clone your GitHub repo with nodes
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes
mkdir -p custom_nodes workflows
cp -r /tmp/lnodes/custom_nodes/* custom_nodes/ || true
cp -r /tmp/lnodes/workflows/* workflows/ || true

# Step 3: ComfyUI Manager
echo "\U0001F9E9 Installing ComfyUI Manager..."
rm -rf custom_nodes/ComfyUI-Manager

git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager

# Step 4: Download models from Hugging Face
echo "\U0001F4E5 Downloading models from Hugging Face..."
pip install -q huggingface_hub

cd /workspace/ComfyUI/models

# Create all folders required by InstantID and others
for folder in checkpoints clip configs controlnet ipadapter upscale_models vae clip_vision insightface/models/antelopev2 instantid; do
    mkdir -p "$folder"
done

declare -A hf_files
hf_files["checkpoints"]="realisticVisionV60B1_v51HyperVAE.safetensors"
hf_files["checkpoints"]+=" sd_xl_base_1.0.safetensors"
hf_files["vae"]="sdxl_vae.safetensors"
hf_files["ipadapter"]="ip-adapter-plus-face_sdxl_vit-h.safetensors"
hf_files["controlnet"]="OpenPoseXL2.safetensors"
hf_files["upscale_models"]="RealESRGAN_x4plus.pth"
hf_files["clip"]="CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
hf_files["instantid"]="ip-adapter.bin"
hf_files["insightface/models/antelopev2"]="det_10g.onnx genderage.onnx glintr100.onnx w600k_r50.onnx"

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
echo "\U0001F680 Launching ComfyUI on port 8188..."
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188
