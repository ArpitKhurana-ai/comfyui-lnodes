#!/bin/bash
set -xe

# ✅ Clean logs
rm -rf /app/startup.log
exec > >(tee /app/startup.log) 2>&1

echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# ✅ Set timezone
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime && dpkg-reconfigure -f noninteractive tzdata

# ✅ Authenticate with Hugging Face
huggingface-cli login --token "$HF_TOKEN" || true

# ✅ Setup model path
export COMFYUI_MODELS_PATH="/workspace/models"
mkdir -p "$COMFYUI_MODELS_PATH"

# ✅ Clone ComfyUI if not already there
cd /workspace
if [ ! -f "/workspace/ComfyUI/main.py" ]; then
    rm -rf /workspace/ComfyUI
    git clone https://github.com/comfyanonymous/ComfyUI.git
fi

# ✅ Remove and re-symlink models folder
rm -rf /workspace/ComfyUI/models
ln -s /workspace/models /workspace/ComfyUI/models

cd /workspace/ComfyUI

# ✅ Sync custom nodes
rm -rf /tmp/lnodes
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git /tmp/lnodes
cp -r /tmp/lnodes/custom_nodes/* custom_nodes/ || true
cp -r /tmp/lnodes/workflows/* workflows/ || true

# ✅ ComfyUI Manager + Impact Pack
rm -rf custom_nodes/ComfyUI-Manager
git clone https://github.com/ltdrdata/ComfyUI-Manager.git custom_nodes/ComfyUI-Manager

rm -rf custom_nodes/ComfyUI-Impact-Pack
git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git custom_nodes/ComfyUI-Impact-Pack
touch custom_nodes/ComfyUI-Impact-Pack/__init__.py

# ✅ Install dependencies
pip install --upgrade pip
pip install huggingface_hub onnxruntime-gpu insightface piexif segment-anything jupyterlab

# ✅ Create model folders
folders=(checkpoints clip configs controlnet ipadapter upscale_models vae clip_vision instantid insightface/models/antelopev2)
for folder in "${folders[@]}"; do
  mkdir -p "$COMFYUI_MODELS_PATH/$folder"
  chmod -R 777 "$COMFYUI_MODELS_PATH/$folder"
done

# ✅ Model downloader
declare -A hf_files
hf_files["checkpoints"]="realisticVisionV60B1_v51HyperVAE.safetensors sd_xl_base_1.0.safetensors"
hf_files["vae"]="sdxl.vae.safetensors"
hf_files["ipadapter"]="ip-adapter-plus-face_sdxl_vit-h.safetensors"
hf_files["controlnet"]="OpenPoseXL2.safetensors"
hf_files["upscale_models"]="RealESRGAN_x4plus.pth"
hf_files["clip"]="CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
hf_files["clip_vision"]="sdxl_vision_encoder.safetensors"
hf_files["instantid"]="ip-adapter.bin"
hf_files["insightface/models/antelopev2"]="1k3d68.onnx 2d106det.onnx genderage.onnx scrfd_10g_bnkps.onnx glintr100.onnx"

for folder in "${!hf_files[@]}"; do
  for file in ${hf_files[$folder]}; do
    python3 -c "
from huggingface_hub import hf_hub_download
import os
hf_hub_download(repo_id='ArpitKhurana/comfyui-models', filename='$folder/$file',
  local_dir='/workspace/models/$folder', repo_type='model', token=os.environ['HF_TOKEN'])"
  done
  chmod -R 777 "$COMFYUI_MODELS_PATH/$folder"
done

# ✅ ComfyUI Launch (background)
cd /workspace/ComfyUI
python3 main.py --listen 0.0.0.0 --port 8188 > /workspace/comfyui.log 2>&1 &

# ✅ Launch JupyterLab from ROOT path so volumes are visible
cd /workspace
python3 -m jupyter lab \
    --ip=0.0.0.0 \
    --port=8888 \
    --notebook-dir='/workspace' \
    --no-browser \
    --allow-root \
    --NotebookApp.token='e1224bcd5b82a0bf4153a47c3f7668fddd1310cc0422f35c' \
    > /workspace/jupyter.log 2>&1 &

# ✅ Keep alive
tail -f /workspace/comfyui.log /workspace/jupyter.log
