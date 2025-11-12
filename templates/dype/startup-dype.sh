#!/usr/bin/env bash
# DyPE + FLUX (FP16) minimal bootstrap for ComfyUI
# Works with Docker image: pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime
# Expects HF_TOKEN (or HUGGING_FACE_HUB_TOKEN) in the environment for gated downloads.

set -euo pipefail

LOG="/workspace/boot-dype.log"
exec > >(tee -a "$LOG") 2>&1

echo "==== [DyPE] Start @ $(date) ===="

# -----------------------------
# 0) Env & helpers
# -----------------------------
export DEBIAN_FRONTEND=noninteractive
export HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  apt-get update -y
  apt-get install -y --no-install-recommends git curl ffmpeg libgl1 ca-certificates
  rm -rf /var/lib/apt/lists/*
}

# -----------------------------
# 1) System deps
# -----------------------------
apt_install

# -----------------------------
# 2) ComfyUI (no venv; use image Python)
# -----------------------------
cd /workspace
if [ ! -d "ComfyUI" ]; then
  echo "[DyPE] Cloning ComfyUI..."
  git clone https://github.com/comfyanonymous/ComfyUI.git
fi

echo "[DyPE] Installing ComfyUI requirements..."
pip install --upgrade pip
pip install -r /workspace/ComfyUI/requirements.txt

# -----------------------------
# 3) Custom nodes required by DyPE
#    - KJNodes (Sage Attention + Torch Patch)
#    - ComfyUI-DyPE (the actual DyPE node)
# -----------------------------
mkdir -p /workspace/ComfyUI/custom_nodes
cd /workspace/ComfyUI/custom_nodes

if [ ! -d "ComfyUI-KJNodes" ]; then
  echo "[DyPE] Cloning KJNodes..."
  git clone https://github.com/kijai/ComfyUI-KJNodes.git
fi

if [ ! -d "ComfyUI-DyPE" ]; then
  echo "[DyPE] Cloning ComfyUI-DyPE..."
  git clone https://github.com/wildminder/ComfyUI-DyPE.git
fi

# (Optional: keep the original research repo for reference – not required at runtime)
if [ ! -d "/workspace/DyPE" ]; then
  git clone https://github.com/guyyariv/DyPE.git /workspace/DyPE || true
fi

# -----------------------------
# 4) Models (FP16 stack)
#    You can override these via env if you ever change filenames.
# -----------------------------
MODEL_ROOT="/workspace/ComfyUI/models"
mkdir -p "$MODEL_ROOT/diffusion_models" "$MODEL_ROOT/text_encoders" "$MODEL_ROOT/vae"

# Default (FP16) – adjust names if your account sees different filenames
: "${FLUX_REPO:=black-forest-labs/FLUX.1-dev}"
: "${FLUX_FILE:=flux1-dev.safetensors}"

: "${CLIP_REPO:=black-forest-labs/CLIP-L}"
: "${CLIP_FILE:=clip_l.safetensors}"

: "${T5_REPO:=black-forest-labs/T5-XXL}"
: "${T5_FILE:=t5xxl_fp16.safetensors}"

: "${VAE_REPO:=madebyollin/ae-sdxl-v1}"
: "${VAE_FILE:=ae.safetensors}"

# huggingface-cli (no login file persisted)
pip show huggingface_hub >/dev/null 2>&1 || pip install "huggingface_hub>=0.23"

dl_hf() {
  local repo="$1" file="$2" target_dir="$3"
  if [ -f "${target_dir}/${file}" ]; then
    echo "[DyPE] Already present: ${target_dir}/${file}"
    return 0
  fi
  if [ -z "$HF_TOKEN" ]; then
    echo "[DyPE][WARN] HF_TOKEN is not set; attempting public download (may fail for gated models): ${repo}/${file}"
    huggingface-cli download "${repo}" "${file}" --local-dir "${target_dir}" --resume || true
  else
    echo "[DyPE] Downloading: ${repo}/${file}"
    HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" huggingface-cli download "${repo}" "${file}" --local-dir "${target_dir}" --resume
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
echo "[DyPE] Presets (set in your workflow):"
echo "   • Square    4096×4096 (A40 48GB)"
echo "   • Landscape 4096×2304"
echo "   • Portrait  2304×4096"
echo "   DyPE node @ 1024×1024 internal; KJNodes Sage Attention ON;"
echo "   Torch Patch enable_fp16_accumulation=true"
echo "==============================================================="

# Keep the process in the foreground so RunPod proxy stays happy
exec python3 main.py --listen 0.0.0.0 --port "${PORT}" --enable-cors-header --disable-metadata
