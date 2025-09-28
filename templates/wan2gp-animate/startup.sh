#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Wan2GP • RunPod one-click ==="

# ---------- Config ----------
export WAN2GP_PORT="${WAN2GP_PORT:-8188}"
export WORKDIR="/workspace"
export APP_DIR="$WORKDIR/Wan2GP"
export VENV_DIR="$WORKDIR/venv-wan2gp"
export HF_HOME="$WORKDIR/hf-home"
export HUGGINGFACE_HUB_CACHE="$WORKDIR/hf-cache"
export XDG_CACHE_HOME="$WORKDIR/.cache"
export WAN2GP_SETTINGS_DIR="$WORKDIR/wan2gp-settings"
export WAN2GP_OUTPUTS_DIR="$WORKDIR/wan2gp-outputs"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$WORKDIR/pip-cache}"

# perf/stability
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-max_split_size_mb:128,expandable_segments:True}"
export WAN2GP_ONNX_CUDA="${WAN2GP_ONNX_CUDA:-0}"      # 1 to enable
export WAN2GP_ONNX_VER="${WAN2GP_ONNX_VER:-1.20.1}"

# ---------- System deps ----------
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y --no-install-recommends \
    git git-lfs curl ca-certificates ffmpeg \
    build-essential python3-dev pkg-config \
    libgl1 libglib2.0-0
  git lfs install || true
fi

# ---------- Folders ----------
mkdir -p "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$XDG_CACHE_HOME" \
         "$WAN2GP_SETTINGS_DIR" "$WAN2GP_OUTPUTS_DIR" "$PIP_CACHE_DIR"

# ---------- Fetch App ----------
if [ ! -d "$APP_DIR/.git" ]; then
  git clone --depth=1 https://github.com/deepbeepmeep/Wan2GP.git "$APP_DIR"
else
  git -C "$APP_DIR" fetch --all -p
  git -C "$APP_DIR" reset --hard origin/HEAD || true
fi
if [ -n "${WAN2GP_COMMIT:-}" ]; then
  git -C "$APP_DIR" checkout "$WAN2GP_COMMIT"
fi

# ---------- Python / Torch ----------
python3 -m venv "$VENV_DIR" 2>/dev/null || true
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
python -V
pip install -U pip wheel setuptools

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo unknown)"
echo "GPU: $GPU_NAME"
if echo "$GPU_NAME" | grep -Eiq '50|Blackwell'; then
  echo "Torch 2.7.0 cu128"
  pip install --index-url https://download.pytorch.org/whl/cu128 \
    torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0
else
  echo "Torch 2.6.0 cu124"
  pip install --index-url https://download.pytorch.org/whl/cu124 \
    torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0
fi

# ---------- Python deps (prefer wheels, retry) ----------
pip install --upgrade --prefer-binary -r "$APP_DIR/requirements.txt" || {
  echo "Retrying requirements install…"
  pip install --upgrade --prefer-binary -r "$APP_DIR/requirements.txt"
}

# Stabilize ONNX
if [ "$WAN2GP_ONNX_CUDA" = "1" ]; then
  pip install --upgrade --no-deps "onnxruntime-gpu==${WAN2GP_ONNX_VER}" || true
else
  export ORT_DISABLE_CUDA=1
fi

# ---------- Persist outputs ----------
if [ -d "$APP_DIR/outputs" ] && [ ! -L "$APP_DIR/outputs" ]; then
  rm -rf "$APP_DIR/outputs"
  ln -s "$WAN2GP_OUTPUTS_DIR" "$APP_DIR/outputs"
fi

# ---------- Ensure port is free ----------
echo "Freeing port ${WAN2GP_PORT} if occupied…"
ss -ltnp 2>/dev/null | grep -q ":${WAN2GP_PORT} " && \
  fuser -k "${WAN2GP_PORT}/tcp" || true
sleep 1

# ---------- Launch (supervised) ----------
cd "$APP_DIR"
LOG_FILE="$WORKDIR/wan2gp.log"
touch "$LOG_FILE"

cleanup() { echo "Shutting down…"; pkill -f "python.*wgp.py" || true; }
trap cleanup INT TERM

start_app() {
  echo "Launching WanGP on :${WAN2GP_PORT} (log: $LOG_FILE)"
  PYTHONUNBUFFERED=1 \
  GRADIO_SERVER_NAME="0.0.0.0" \
  GRADIO_SERVER_PORT="$WAN2GP_PORT" \
  python wgp.py \
    --listen \
    --server-port "${WAN2GP_PORT}" \
    --settings "${WAN2GP_SETTINGS_DIR}" \
    >>"$LOG_FILE" 2>&1
}

( while true; do start_app || true; echo "App exited; restart in 5s…"; sleep 5; done ) & APP_WATCH=$!

# ---------- Health: wait for real app ----------
echo "Waiting for server to answer on / …"
for _ in $(seq 1 300); do
  if curl -fsS "http://127.0.0.1:${WAN2GP_PORT}/" >/dev/null; then
    echo "HTTP service ready on port ${WAN2GP_PORT}"
    break
  fi
  sleep 2
done

# Dump tail if still not ready
curl -fsS "http://127.0.0.1:${WAN2GP_PORT}/" >/dev/null || {
  echo "Service not ready yet. Last 120 log lines:"
  tail -n 120 "$LOG_FILE" || true
}

wait "$APP_WATCH"
exit 1
