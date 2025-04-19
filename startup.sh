#!/bin/bash

set -e  # Stop script if any command fails
echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# Set timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# Authenticate Hugging Face
huggingface-cli login --token $HF_TOKEN

# Step 1: Clone ComfyUI (clean before reattempt)
if [ ! -d "/workspace/ComfyUI" ]; then
    echo "🟢 Cloning ComfyUI..."
    git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
else
    echo "✅ ComfyUI already exists. Skipping clone."
fi

cd /workspace/ComfyUI || { echo "❌ ComfyUI folder not found. Exiting."; exit 1; }

# Step 2: Clean + Download custom nodes & workflows
echo "📦 Pulling custom nodes and workflows from GitHub..."
rm -rf /tmp/lnodes
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes

# Ensure directories exist
mkdir -p /workspace/ComfyUI/custom_nodes
mkdir -p /workspace/ComfyUI/workflows

# Copy them into correct paths
cp -r /tmp/lnodes/custom_nodes/* /workspace/ComfyUI/custom_nodes/
cp -r /tmp/lnodes/workflows/* /workspace/ComfyUI/workflows/

# Step 3: Download models from Hugging Face
echo "📥 Downloading models from Hugging Face..."
mkdir -p /workspace/ComfyUI/models
cd /workspace/ComfyUI/models

for folder in checkpoints clip configs controlnet ipadapter upscale_models vae clip_vision; do
    echo "⏬ Downloading $folder..."
    mkdir -p "$folder"
    wget -q --show-progress -r -nH --cut-dirs=1 -np -R "index.html*" \
        https://huggingface.co/ArpitKhurana/comfyui-models/resolve/main/$folder/ \
        -P "$folder/"
done

# Step 4: Final launch
echo "🚀 Launching ComfyUI on port 8188..."
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188
