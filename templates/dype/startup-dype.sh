#!/usr/bin/env bash
# DyPE + FLUX (FP16) minimal bootstrap for ComfyUI
# Tested with: pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime
# Requires: set HF_TOKEN (or HUGGING_FACE_HUB_TOKEN) in RunPod env for gated models.

set -euo pipefail

LOG="/workspace/boot-dype.log"
exec > >(tee -a "$LOG") 2>&1

echo "==== [DyPE] Start @ $(date) ===="

# -----------------------------
# 0) Env & helpers
# -----------------------------
export DEBIAN_FRONTEND=noninteractive
export HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
export PYTHONUNBUFFERED=1

need_cmd() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  echo "[DyPE] Installing base packages..."
  apt-get update -y
  apt-get install -y --no-install-recommends \
    git git-lfs curl ffmpeg libgl1 ca-certificates \
    build-essential pkg-config
  rm -rf /var/lib/apt/lists/*
  git lfs install || true
}

# -----------------------------
# 1) System deps
# -----------------------------
apt_install

# -----------------------------
# 2) ComfyUI (ensure valid checkout)
# -----------------------------
cd /workspace

# If ComfyUI folder exists but looks broken (no requirements.txt), reclone
if [ ! -f "/workspace/ComfyUI/requirements.txt" ]; then
  echo "[DyPE] (Re)cloning ComfyUI..."
  rm -rf /workspace/ComfyUI
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
else
  echo "[DyPE] ComfyUI already present."
fi

echo "[DyPE] Upgrading pip + installing ComfyUI requirements..."
pip install --upgrade pip wheel setuptools
pip install -r /workspace/ComfyUI/requirements.txt

# -----------------------------
# 3) Custom nodes required by DyPE
#    - KJNodes (Sage Attention + Torch Patch)
#    - ComfyUI-DyPE
# -----------------------------
mkdir -p /workspace/ComfyUI/custom_nodes
cd /workspace/ComfyUI/custom_nodes

if [ ! -d "ComfyUI-KJNodes" ]; then
  echo "[DyPE] Cloning KJNodes..."
  git clone --depth=1 https://github.com/kijai/ComfyUI-KJNodes.git
else
  echo "[DyPE] KJNodes already present."
fi

if [ ! -d "ComfyUI-DyPE" ]; then
  echo "[DyPE] Cloning ComfyUI-DyPE..."
  git clone --depth=1 https://github.com/wildminder/ComfyUI-DyPE.git
else
  echo "[DyPE] ComfyUI-DyPE already present."
fi

# (Optional reference repo; not required at runtime)
if [ ! -d "/workspace/DyPE" ]; then
  git clone --depth=1 https://github.com/guyyariv/DyPE.git /workspace/DyPE || true
fi

# -----------------------------
# 4) Models (FP16 stack)
# -----------------------------
MODEL_ROOT="/workspace/ComfyUI/models"
mkdir -p "$MODEL_ROOT/diffusion_models" "$MODEL_ROOT/text_encoders" "$MODEL_ROOT/vae"

# Repos/files (override via env if needed)
: "${FLUX_REPO:=black-forest-labs/FLUX.1-dev}"
: "${FLUX_FILE:=flux1-dev.safetensors}"

: "${CLIP_REPO:=black-forest-labs/CLIP-L}"
: "${CLIP_FILE:=clip_l.safetensors}"

: "${T5_REPO:=black-forest-labs/T5-XXL}"
: "${T5_FILE:=t5xxl_fp16.safetensors}"

: "${VAE_REPO:=madebyollin/ae-sdxl-v1}"
: "${VAE_FILE:=ae.safetensors}"

# huggingface-cli
if ! pip show huggingface_hub >/dev/null 2>&1; then
  pip install "huggingface_hub>=0.23"
fi

dl_hf() {
  local repo="$1" file="$2" target_dir="$3"
  mkdir -p "$target_dir"
  if [ -f "${target_dir}/${file}" ]; then
    echo "[DyPE] Already present: ${target_dir}/${file}"
    return 0
  fi
  if [ -z "${HF_TOKEN}" ]; then
    echo "[DyPE][WARN] HF_TOKEN not set; trying anonymous download (may fail for gated): ${repo}/${file}"
    huggingface-cli download "${repo}" "${file}" --local-dir "${target_dir}" --resume || true
  else
    echo "[DyPE] Downloading: ${repo}/${file}"
    HUGGING_FACE_HUB_TOKEN="${HF_TOKEN}" \
      huggingface-cli download "${repo}" "${file}" --local-dir "${target_dir}" --resume
  fi
}

dl_hf "$FLUX_REPO" "$FLUX_FILE" "$MODEL_ROOT/diffusion_models"
dl_hf "$CLIP_REPO" "$CLIP_FILE" "$MODEL_ROOT/text_encoders"
dl_hf "$T5_REPO"   "$T5_FILE"   "$MODEL_ROOT/text_encoders"
dl_hf "$VAE_REPO"  "$VAE_FILE"  "$MODEL_ROOT/vae"

echo "[DyPE] Model inventory:"
ls -lh "$MODEL_ROOT/diffusion_models" || true
ls -lh "$MODEL_ROOT/text_encoders" || true
ls -lh "$MODEL_ROOT/vae" || true

# -----------------------------
# 5) Launch ComfyUI
# -----------------------------
cd /workspace/ComfyUI

PORT="${COMFY_PORT:-8188}"
echo "==============================================================="
echo "[DyPE] Starting ComfyUI on 0.0.0.0:${PORT}"
echo "[DyPE] Presets (Latent sizes in workflow):"
echo "   • Square    4096×4096   (A40 48GB)"
echo "   • Landscape 4096×2304"
echo "   • Portrait  2304×4096"
echo "   DyPE node @ 1024×1024 internal; KJNodes Sage Attention ON;"
echo "   Torch Patch: enable_fp16_accumulation=true"
echo "==============================================================="

# Keep process in foreground so RunPod proxy sees a live service on 8188
exec python3 main.py --listen 0.0.0.0 --port "${PORT}" --enable-cors-header --disable-metadata
