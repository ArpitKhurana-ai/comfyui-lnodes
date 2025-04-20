#!/bin/bash

set -xe

# ✅ Log all output to a file
exec > >(tee /app/startup.log) 2>&1

echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# Set timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata

# Hugging Face login
echo "🔐 Authenticating Hugging Face..."
huggingface-cli login --token "$HF_TOKEN" || true

# ✅ Persistent model path
export COMFYUI_MODELS_PATH="/workspace/models"
mkdir -p "$COMFYUI_MODELS_PATH"

# Ensure we are in /workspace
cd /workspace || exit 1

# ✅ Clean ComfyUI if broken
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    echo "🧹 Cleaning broken ComfyUI (if exists)..."
    rm -rf /workspace/ComfyUI
    git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
fi

# ✅ Symlink persistent models into ComfyUI's expected path (after cloning)
rm -rf /workspace/ComfyUI/models
ln -s "$COMFYUI_MODELS_PATH" /workspace/ComfyUI/models

cd /workspace/ComfyUI

# ✅ Sync custom nodes & workflows
echo "📦 Syncing custom nodes and workflows..."
rm -rf /tmp/lnodes
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes
mkdir -p custom_nodes workflows
cp -r /tmp/lnodes/custom_nodes/* custom_nodes/ || true
cp -r /tmp/lnodes/workflows/* workflows/ || true

# ✅ Install ComfyUI Manager
rm -rf custom_nodes/ComfyUI-Manager
git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager

# ✅ Install ComfyUI Impact-Pack
rm -rf custom_nodes/ComfyUI-Impact-Pack
git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git custom_nodes/ComfyUI-Impact-Pack

# ✅ Fix __init__.py in Impact-Pack
impact_path="custom_nodes/ComfyUI-Impact-Pack"
if [ -d "$impact_path" ] && [ ! -f "$impact_path/__init__.py" ]; then
    touch "$impact_path/__init__.py"
    echo "✅ __init__.py added to $impact_path"
fi

# ✅ Install Python dependencies
echo "📦 Installing Python dependencies..."
pip install --quiet huggingface_hub onnxruntime-gpu insightface piexif segment-anything pycocotools

# ✅ Performance optimizations
echo "⚡ Applying performance optimizations..."
export PYTORCH_CUDA_ALLOC_CONF="max_split_size_mb:128"
export ATTENTION_OPTIMIZE_MEMORY=1
export CUDA_MODULE_LOADING=LAZY

# Update PyTorch to avoid unsafe loading warnings
pip install --quiet --upgrade torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

# ✅ Create persistent model folders
echo "📁 Creating model folders in $COMFYUI_MODELS_PATH..."
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
    mkdir -p "$COMFYUI_MODELS_PATH/$folder"
done

# ✅ Download model files if missing
echo "⬇️ Syncing Hugging Face models..."
declare -A hf_files
hf_files["checkpoints"]="realisticVisionV60B1_v51HyperVAE.safetensors sd_xl_base_1.0.safetensors"
hf_files["vae"]="sdxl.vae.safetensors"
hf_files["ipadapter"]="ip-adapter-plus-face_sdxl_vit-h.safetensors"
hf_files["controlnet"]="OpenPoseXL2.safetensors"
hf_files["upscale_models"]="RealESRGAN_x4plus.pth"
hf_files["clip"]="CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
hf_files["clip_vision"]="sdxl_vision_encoder.safetensors"
hf_files["instantid"]="ip-adapter.bin"
hf_files["insightface/models/antelopev2"]="1k3d68.onnx 2d106det.onnx genderage.onnx glintr100.onnx scrfd_10g_bnkps.onnx"

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
done

# ✅ Final fix for IPAdapterUnifiedLoader's ClipVision check
echo "🧠 Ensuring ClipVision model is in place..."
CLIP_VISION_PATH="/workspace/models/clip_vision"
mkdir -p "$CLIP_VISION_PATH"

# Download the model if missing
if [ ! -f "$CLIP_VISION_PATH/sdxl_vision_encoder.safetensors" ]; then
    python3 -c "
import os
from huggingface_hub import hf_hub_download
hf_hub_download(
    repo_id='ArpitKhurana/comfyui-models',
    filename='clip_vision/sdxl_vision_encoder.safetensors',
    local_dir='$CLIP_VISION_PATH',
    repo_type='model',
    token=os.environ['HF_TOKEN']
)"
fi

# Create the expected symlink name that IPAdapter+ looks for
ln -sf "$CLIP_VISION_PATH/sdxl_vision_encoder.safetensors" "$CLIP_VISION_PATH/clip_vision.safetensors"

# Verify model integrity
echo "🔍 Verifying ClipVision model..."
if [ -f "$CLIP_VISION_PATH/clip_vision.safetensors" ]; then
    echo "✅ ClipVision model verified at $CLIP_VISION_PATH/clip_vision.safetensors"
    echo "📏 Size: $(du -h "$CLIP_VISION_PATH/clip_vision.safetensors" | cut -f1)"
else
    echo "❌ ClipVision model not found after download attempt"
    exit 1
fi

# ✅ Launch ComfyUI
echo "🚀 Launching ComfyUI on port 8188..."
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188
