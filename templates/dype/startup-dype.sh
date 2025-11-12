#!/usr/bin/env bash
# DyPE + FLUX (FP16) minimal bootstrap for ComfyUI on RunPod
# Tested base image: pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime
# Requires: HF_TOKEN in environment with access to black-forest-labs/FLUX.1-dev.
# Starts ComfyUI on port 8188 and keeps process in foreground.

set -euo pipefail

LOG="/workspace/boot-dype.log"
exec > >(tee -a "$LOG") 2>&1

echo "==== [DyPE] Start @ $(date) ===="

export DEBIAN_FRONTEND=noninteractive
export HF_TOKEN="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
export HF_HOME="/workspace/.cache/huggingface"
export TRANSFORMERS_CACHE="$HF_HOME"
export HF_HUB_ENABLE_HF_TRANSFER=1

mkdir -p "$HF_HOME"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  echo "[Sys] Installing apt deps..."
  apt-get update -y
  apt-get install -y --no-install-recommends git curl ffmpeg libgl1 ca-certificates aria2
  rm -rf /var/lib/apt/lists/*
}

pip_install() {
  echo "[Py] Ensuring pip deps..."
  pip install --upgrade pip
  pip install "huggingface_hub>=0.23" "requests>=2.31"
}

retry() {
  # retry <max_tries> <sleep_seconds> <command...>
  local -r max="$1"; shift
  local -r sleep_s="$1"; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    if [ "$n" -ge "$max" ]; then
      return 1
    fi
    echo "[Retry] Attempt $n failed. Sleeping ${sleep_s}s..."
    sleep "$sleep_s"
  done
}

hf_dl_cli() {
  # hf_dl_cli <repo> <remote_path> <target_dir>
  local repo="$1" remote="$2" outdir="$3"
  mkdir -p "$outdir"
  local extra=()
  [ -n "${HF_TOKEN:-}" ] && extra=( "--token" "$HF_TOKEN" )
  huggingface-cli download "$repo" "$remote" --local-dir "$outdir" --local-dir-use-symlinks False --resume "${extra[@]}"
}

hf_dl_https() {
  # Fallback: direct HTTPS with Authorization header
  # hf_dl_https <repo> <remote_path> <target_file>
  local repo="$1" remote="$2" target="$3"
  local base="https://huggingface.co/${repo}/resolve/main/${remote}"
  mkdir -p "$(dirname "$target")"
  if [ -n "${HF_TOKEN:-}" ]; then
    echo "[HF HTTPS] GET (auth) $repo/$remote -> $target"
    curl -L --fail -H "Authorization: Bearer ${HF_TOKEN}" -o "$target" "$base"
  else
    echo "[HF HTTPS] GET (public) $repo/$remote -> $target"
    curl -L --fail -o "$target" "$base"
  fi
}

safe_fetch() {
  # safe_fetch <repo> <remote_path> <target_file>
  local repo="$1" remote="$2" target="$3"
  if [ -s "$target" ]; then
    echo "[Fetch] Exists: $target"
    return 0
  fi
  echo "[Fetch] Trying huggingface-cli for ${repo}/${remote}"
  if ! retry 3 5 hf_dl_cli "$repo" "$remote" "$(dirname "$target")"; then
    echo "[Fetch] CLI failed. Falling back to HTTPS..."
    retry 3 5 hf_dl_https "$repo" "$remote" "$target"
  else
    # hf-cli downloads into a directory keeping the same filename; ensure final path exists
    if [ ! -s "$target" ]; then
      # Move if it landed under local-dir/<remote_basename>
      local basename
      basename="$(basename "$remote")"
      if [ -s "$(dirname "$target")/$basename" ]; then
        mv -f "$(dirname "$target")/$basename" "$target"
      fi
    fi
  fi
  [ -s "$target" ] || { echo "[Fetch][FATAL] Missing $target after download."; exit 1; }
}

# -----------------------------
# 1) System + Python deps
# -----------------------------
apt_install
pip_install

# -----------------------------
# 2) ComfyUI
# -----------------------------
cd /workspace
if [ ! -d "ComfyUI" ]; then
  echo "[ComfyUI] Cloning..."
  git clone https://github.com/comfyanonymous/ComfyUI.git
else
  echo "[ComfyUI] Found. (pulling latest)"
  (cd ComfyUI && git pull --ff-only || true)
fi

echo "[ComfyUI] Installing requirements..."
pip install -r /workspace/ComfyUI/requirements.txt

# -----------------------------
# 3) Nodes: KJNodes (SageAttention/TorchPatch) + DyPE
# -----------------------------
mkdir -p /workspace/ComfyUI/custom_nodes
cd /workspace/ComfyUI/custom_nodes

if [ ! -d "ComfyUI-KJNodes" ]; then
  echo "[Nodes] Cloning KJNodes..."
  git clone https://github.com/kijai/ComfyUI-KJNodes.git
else
  (cd ComfyUI-KJNodes && git pull --ff-only || true)
fi

if [ ! -d "ComfyUI-DyPE" ]; then
  echo "[Nodes] Cloning ComfyUI-DyPE..."
  git clone https://github.com/wildminder/ComfyUI-DyPE.git
else
  (cd ComfyUI-DyPE && git pull --ff-only || true)
fi

# Optional: research repo (not required)
if [ ! -d "/workspace/DyPE" ]; then
  git clone https://github.com/guyyariv/DyPE.git /workspace/DyPE || true
fi

# -----------------------------
# 4) Models (FP16 stack)
#    NOTE: All FLUX.1-dev artifacts come from the SAME repo (subpaths!)
# -----------------------------
MODEL_ROOT="/workspace/ComfyUI/models"
mkdir -p "$MODEL_ROOT/diffusion_models" "$MODEL_ROOT/text_encoders" "$MODEL_ROOT/vae"

FLUX_REPO="black-forest-labs/FLUX.1-dev"
VAE_REPO="madebyollin/ae-sdxl-v1"

# Targets
DM_TGT="$MODEL_ROOT/diffusion_models/flux1-dev.safetensors"
CLIP_TGT="$MODEL_ROOT/text_encoders/clip_l.safetensors"
T5_TGT="$MODEL_ROOT/text_encoders/t5xxl_fp16.safetensors"
VAE_TGT="$MODEL_ROOT/vae/ae.safetensors"

echo "[Models] Downloading FLUX.1-dev (diffusion)"
safe_fetch "$FLUX_REPO" "flux1-dev.safetensors" "$DM_TGT"

echo "[Models] Downloading FLUX.1-dev (text_encoders/clip_l)"
safe_fetch "$FLUX_REPO" "text_encoders/clip_l.safetensors" "$CLIP_TGT"

echo "[Models] Downloading FLUX.1-dev (text_encoders/t5xxl_fp16)"
safe_fetch "$FLUX_REPO" "text_encoders/t5xxl_fp16.safetensors" "$T5_TGT"

echo "[Models] Downloading VAE (madebyollin/ae-sdxl-v1)"
safe_fetch "$VAE_REPO" "ae.safetensors" "$VAE_TGT"

echo "[Models] Inventory:"
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
echo "[DyPE] Use the DyPE+FLUX workflow; set:"
echo "   • Square    4096×4096 (A40 48GB)"
echo "   • Landscape 4096×2304"
echo "   • Portrait  2304×4096"
echo "   DyPE node @ 1024×1024 internal; KJNodes Sage Attention ON."
echo "   TorchPatch enable_fp16_accumulation=true (in KJNodes node)."
echo "==============================================================="

exec python3 main.py --listen 0.0.0.0 --port "${PORT}" --enable-cors-header --disable-metadata
