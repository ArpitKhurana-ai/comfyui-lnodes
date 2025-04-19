#!/bin/bash

set -e  # Stop script on error
echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# Set timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && dpkg-reconfigure -f noninteractive tzdata

# Authenticate Hugging Face (if using HF_TOKEN env var)
huggingface-cli login --token $HF_TOKEN || true

# Step 1: Clone ComfyUI
if [ ! -d "/workspace/ComfyUI" ]; then
    echo "🟢 Cloning ComfyUI..."
    git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
else
    echo "✅ ComfyUI folder already exists. Skipping clone."
fi

# Check if main.py exists
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "❌ ComfyUI main.py not found. Exiting."
    exit 1
fi

cd /workspace/ComfyUI || { echo "❌ Failed to cd into /workspace/ComfyUI"; exit 1; }

# Step 2: Custom nodes + workflows
echo "📦 Pulling custom nodes & workflows from GitHub..."

# Clean existing lnodes temp folder
rm -rf /tmp/lnodes
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes

# Ensure target directories exist
mkdir -p /workspace/ComfyUI/custom_nodes
mkdir -p /workspace/ComfyUI/workflows

# Copy them
cp -r /tmp/lnodes/custom_nodes/* /workspace/ComfyUI/custom_nodes/
cp -r /tmp/lnodes/workflows/* /workspace/ComfyUI/workflows/

# ✅ Add ComfyUI-Manager if not already there
if [ ! -d "/workspace/ComfyUI/custom_nodes/ComfyUI-Manager" ]; then
    echo "🧩 Installing ComfyUI-Manager..."
    git clone https://github.com/ltdrdata/ComfyUI-Manager.git /workspace/ComfyUI/custom_nodes/ComfyUI-Manager
else
    echo "✅ ComfyUI-Manager already installed."
fi

# Step 3: Models from Hugging Face
echo "📥 Downloading models from Hugging Face..."
mkdir -p /workspace/ComfyUI/models
cd /workspace/ComfyUI/models

for folder in checkpoints clip configs controlnet ipadapter upscale_models vae clip_vision; do
    echo "⏬ Downloading $folder"
    mkdir -p "$folder"
    wget -q --show-progress -r -nH --cut-dirs=1 -np -R "index.html*" \
        https://huggingface.co/ArpitKhurana/comfyui-models/resolve/main/$folder/ \
        -P "$folder/"
done

# Step 4: Launch ComfyUI
echo "🚀 Launching ComfyUI on port 8188..."
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188

