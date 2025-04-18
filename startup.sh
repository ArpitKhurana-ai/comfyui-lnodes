#!/bin/bash

echo "🔄 Starting ComfyUI setup..."

# Set ComfyUI working directory
cd /workspace/ComfyUI || exit 1

# Clone your GitHub repo (custom nodes + workflows)
echo "📥 Cloning GitHub repo for custom nodes and workflows..."
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/comfyui-lnodes

# Copy custom nodes
echo "📂 Copying custom nodes..."
cp -r /tmp/comfyui-lnodes/custom_nodes/* /workspace/ComfyUI/custom_nodes/

# Copy workflows
echo "📂 Copying workflows..."
mkdir -p /workspace/ComfyUI/user/default/workflows
cp -r /tmp/comfyui-lnodes/workflows/* /workspace/ComfyUI/user/default/workflows/

# Clean up
rm -rf /tmp/comfyui-lnodes

# ✅ Start ComfyUI
echo "🚀 Launching ComfyUI..."
python3 main.py --listen 0.0.0.0 --port 8188
