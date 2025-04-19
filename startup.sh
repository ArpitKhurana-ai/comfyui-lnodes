#!/bin/bash
set -e  # Stop if anything fails

echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# Set timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && dpkg-reconfigure -f noninteractive tzdata

# HuggingFace Auth (if token provided)
huggingface-cli login --token $HF_TOKEN || true

# Step 1: Clone ComfyUI if not already present
if [ ! -d "/workspace/ComfyUI" ]; then
    echo "🟢 Cloning ComfyUI..."
    git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
else
    echo "✅ ComfyUI already exists"
fi

cd /workspace/ComfyUI || { echo "❌ ComfyUI folder missing"; exit 1; }

# Step 2: Download custom nodes & workflows
echo "📦 Pulling nodes & workflows..."

rm -rf /tmp/lnodes  # 💥 Important fix to allow re-run!
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes

mkdir -p /workspace/ComfyUI/custom_nodes
mkdir -p /workspace/ComfyUI/workflows

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
      -P $folder/
done

# Step 4: Start ComfyUI
echo "🚀 Launching ComfyUI on port 8188..."
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188
