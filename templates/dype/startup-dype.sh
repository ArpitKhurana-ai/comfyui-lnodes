#!/usr/bin/env bash
# DyPE + FLUX (FP16) minimal bootstrap for ComfyUI
# Works with Docker image: pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime
# Expects HF_TOKEN (or HUGGING_FACE_HUB_TOKEN) in env if you pull any gated models.

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
  apt-get install -y --no-install-recommends git curl ffmpeg libgl1 ca-certificates aria2
  rm -rf /var/lib/apt/lists/*
}

# -----------------------------
# 1) System deps
# -----------------------------
echo "[Sys] Installing apt deps..."
apt_install

echo "[Py] Ensuring pip deps..."
python3 -m pip install -U pip >/dev/null
python3 -m pip install "huggingface_hub>=0.23" requests >/dev/null

# -----------------------------
# 2) ComfyUI (force a healthy clone if needed)
# -----------------------------
cd /workspace
if [[ -d "ComfyUI" && (! -d "ComfyUI/.git" || ! -f "ComfyUI/requirements.txt") ]]; then
  echo "[ComfyUI] Found broken/incomplete dir. Removing..."
  rm -rf /workspace/ComfyUI
fi

if [[ ! -d "ComfyUI" ]]; then
  echo "[ComfyUI] Cloning fresh..."
  git clone https://github.com/comfyanonymous/ComfyUI.git /workspace/ComfyUI
else
  echo "[ComfyUI] Repo exists. Pulling latest..."
  git -C /workspace/ComfyUI fetch --all || true
  git -C /workspace/ComfyUI pull --rebase || true
fi

echo "[ComfyUI] Installing requirements..."
python3 -m pip install -r /workspace/ComfyUI/requirements.txt

# -----------------------------
# 3) Custom nodes needed by DyPE
# -----------------------------
mkdir -p /workspace/ComfyUI/custom_nodes
cd /workspace/ComfyUI/custom_nodes

if [[ ! -d "ComfyUI-KJNodes" ]]; then
  echo "[DyPE] Cloning KJNodes (Sage Attention / Torch Patch)..."
  git clone https://github.com/kijai/ComfyUI-KJNodes.git
fi

if [[ ! -d "ComfyUI-DyPE" ]]; then
  echo "[DyPE] Cloning ComfyUI-DyPE node..."
  git clone https://github.com/wildminder/ComfyUI-DyPE.git
fi

# Optional: research code (not needed to run)
if [[ ! -d "/workspace/DyPE" ]]; then
  git clone https://github.com/guyyariv/DyPE.git /workspace/DyPE || true
fi

# -----------------------------
# 4) (Optional) Models – comment out if you preload via volume
#    Keep FP16 stack for quality; sizes/filenames can be overridden via env.
# -----------------------------
MODEL_ROOT="/workspace/ComfyUI/models"
mkdir -p "$MODEL_ROOT/diffusion_models" "$MODEL_ROOT/text_encoders" "$MODEL_ROOT/vae"

: "${FLUX_REPO:=black-forest-labs/FLUX.1-dev}"
: "${FLUX_FILE:=flux1-dev.safetensors}"

: "${CLIP_REPO:=black-forest-labs/CLIP-L}"
: "${CLIP_FILE:=clip_l.safetensors}"

: "${T5_REPO:=black-forest-labs/T5-XXL}"
: "${T5_FILE:=t5xxl_fp16.safetensors}"

: "${VAE_REPO:=madebyollin/ae-sdxl-v1}"
: "${VAE_FILE:=ae.safetensors}"

dl_hf() {
  local repo="$1" file="$2" target_dir="$3"
  mkdir -p "$target_dir"
  if [[ -f "${target_dir}/${file}" ]]; then
    echo "[DyPE] Already present: ${target_dir}/${file}"
    return 0
  fi
  if [[ -n "$HF_TOKEN" ]]; then
    echo "[DyPE] Download (auth): ${repo}/${file}"
    HUGGING_FACE_HUB_TOKEN="$HF_TOKEN" huggingface-cli download "$repo" "$file" --local-dir "$target_dir" --resume
  else
    echo "[DyPE] Download (public try): ${repo}/${file}"
    huggingface-cli download "$repo" "$file" --local-dir "$target_dir" --resume || true
  fi
}

# Uncomment only if you actually need auto-pull here; otherwise rely on your volume
# dl_hf "$FLUX_REPO" "$FLUX_FILE" "$MODEL_ROOT/diffusion_models"
# dl_hf "$CLIP_REPO" "$CLIP_FILE" "$MODEL_ROOT/text_encoders"
# dl_hf "$T5_REPO"   "$T5_FILE"   "$MODEL_ROOT/text_encoders"
# dl_hf "$VAE_REPO"  "$VAE_FILE"  "$MODEL_ROOT/vae"

echo "[DyPE] Model folders present:"
ls -lh "$MODEL_ROOT/diffusion_models" 2>/dev/null || true
ls -lh "$MODEL_ROOT/text_encoders"    2>/dev/null || true
ls -lh "$MODEL_ROOT/vae"              2>/dev/null || true

# -----------------------------
# 5) Launch ComfyUI
# -----------------------------
cd /workspace/ComfyUI

PORT="${COMFY_PORT:-8188}"
echo "==============================================================="
echo "[DyPE] Starting ComfyUI on 0.0.0.0:${PORT}"
echo " Presets via workflow:"
echo "   • Square    4096×4096"
echo "   • Landscape 4096×2304"
echo "   • Portrait  2304×4096"
echo " DyPE node 1024×1024 internal; Sage Attention ON; FP16 accumulation ON."
echo "==============================================================="

exec python3 main.py --listen 0.0.0.0 --port "${PORT}" --enable-cors-header --disable-metadata
