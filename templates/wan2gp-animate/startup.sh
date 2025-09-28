#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Wan2GP One-Click Startup (RunPod) ==="

# -------- Config (edit if you want) --------
export WAN2GP_PORT=${WAN2GP_PORT:-8188}
export WORKDIR=/workspace
export APP_DIR="$WORKDIR/Wan2GP"
export VENV_DIR="$WORKDIR/venv-wan2gp"
export HF_HOME="$WORKDIR/hf-home"
export HUGGINGFACE_HUB_CACHE="$WORKDIR/hf-cache"
export XDG_CACHE_HOME="$WORKDIR/.cache"
export WAN2GP_SETTINGS_DIR="$WORKDIR/wan2gp-settings"
export WAN2GP_OUTPUTS_DIR="$WORKDIR/wan2gp-outputs"
# Optionally pin a commit: export WAN2GP_COMMIT=abcdef1234567890
# -------------------------------------------

echo "[1/7] System prep (apt, ffmpeg, git-lfs)..."
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y --no-install-recommends ffmpeg git-lfs python3-venv
  git lfs install
else
  echo "apt-get not available (custom base image?) — skipping apt installs."
fi

echo "[2/7] Folders..."
mkdir -p "$WORKDIR" "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$XDG_CACHE_HOME" \
         "$WAN2GP_SETTINGS_DIR" "$WAN2GP_OUTPUTS_DIR"

echo "[3/7] Clone/Update Wan2GP..."
if [ ! -d "$APP_DIR/.git" ]; then
  git clone --depth=1 https://github.com/deepbeepmeep/Wan2GP.git "$APP_DIR"
else
  git -C "$APP_DIR" fetch --all -p
  git -C "$APP_DIR" pull --ff-only || true
fi
if [ -n "${WAN2GP_COMMIT:-}" ]; then
  git -C "$APP_DIR" checkout "$WAN2GP_COMMIT"
fi

echo "[4/7] Python venv + pip basics..."
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
python -V
pip install -U pip wheel setuptools

echo "[5/7] Install PyTorch (choose CUDA wheel by GPU gen)..."
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo unknown)"
echo "Detected GPU: $GPU_NAME"

# Default to stable CUDA 12.4 (good for RTX 10xx–40xx). Use 2.7.0/cu128 only for RTX 50xx (Blackwell).
if echo "$GPU_NAME" | grep -Eiq '50|Blackwell'; then
  echo "RTX 50xx/Blackwell detected → installing Torch 2.7.0 (cu128) [beta]"
  pip install --index-url https://download.pytorch.org/whl/cu128 torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0
else
  echo "Installing Torch 2.6.0 (cu124) [stable]"
  pip install --index-url https://download.pytorch.org/whl/cu124 torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0
fi

echo "[6/7] Wan2GP requirements..."
pip install -r "$APP_DIR/requirements.txt"

# Ensure outputs are persistent; Wan2GP writes to its repo by default, so link it to our volume path.
if [ -d "$APP_DIR/outputs" ] && [ ! -L "$APP_DIR/outputs" ]; then
  echo "Redirecting outputs to $WAN2GP_OUTPUTS_DIR"
  rm -rf "$APP_DIR/outputs"
  ln -s "$WAN2GP_OUTPUTS_DIR" "$APP_DIR/outputs"
fi

echo "[7/7] Launch Wan2GP UI on 0.0.0.0:${WAN2GP_PORT} ..."
cd "$APP_DIR"

# Helpful run flags from CLI docs:
# --listen exposes on 0.0.0.0, --server-port sets port, --settings persists UI defaults.
# (You can add performance flags later: --compile, --attention sage2, --profile 3, etc.)
PYTHONUNBUFFERED=1 \
python wgp.py \
  --listen \
  --server-port "${WAN2GP_PORT}" \
  --settings "${WAN2GP_SETTINGS_DIR}" &

# Simple health loop: wait for port then print the exact line RunPod watchers look for.
for i in {1..120}; do
  sleep 2
  if ss -ltn 2>/dev/null | grep -q ":${WAN2GP_PORT}"; then
    echo "HTTP service ready on port ${WAN2GP_PORT}"
    wait -n  # keep python in foreground if it dies
    exit 0
  fi
done

echo "Wan2GP UI failed to bind on port ${WAN2GP_PORT} within timeout."
exit 1
