#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Wan2GP One-Click Startup (RunPod • stable) ==="

### ---------- Config ----------
export WAN2GP_PORT="${WAN2GP_PORT:-8188}"
export WORKDIR="/workspace"
export APP_DIR="$WORKDIR/Wan2GP"
export VENV_DIR="$WORKDIR/venv-wan2gp"
export HF_HOME="$WORKDIR/hf-home"
export HUGGINGFACE_HUB_CACHE="$WORKDIR/hf-cache"
export XDG_CACHE_HOME="$WORKDIR/.cache"
export WAN2GP_SETTINGS_DIR="$WORKDIR/wan2gp-settings"
export WAN2GP_OUTPUTS_DIR="$WORKDIR/wan2gp-outputs"
# Optional: pin repo commit for reproducibility
# export WAN2GP_COMMIT=abcdef1234567890

# Stability/perf knobs (can override in template env)
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-max_split_size_mb:128,expandable_segments:True}"
# ONNX GPU is a common crash point; default to CPU for ONNX bits (diffusion still uses GPU).
# Set WAN2GP_ONNX_CUDA=1 to keep ONNX on GPU, or WAN2GP_ONNX_VER to pin a version (e.g. 1.20.1)
export WAN2GP_ONNX_CUDA="${WAN2GP_ONNX_CUDA:-0}"
export WAN2GP_ONNX_VER="${WAN2GP_ONNX_VER:-1.20.1}"

# Gradio/uvicorn stability behind proxies
export GRADIO_SERVER_NAME="0.0.0.0"
export GRADIO_SERVER_PORT="$WAN2GP_PORT"
export UVICORN_TIMEOUT_KEEP_ALIVE="${UVICORN_TIMEOUT_KEEP_ALIVE:-75}"
### ----------------------------

echo "[1/9] System prep…"
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y --no-install-recommends ffmpeg git-lfs python3-venv curl ca-certificates
  git lfs install || true
else
  echo "apt-get not available; skipping."
fi

echo "[2/9] Folders…"
mkdir -p "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$XDG_CACHE_HOME" \
         "$WAN2GP_SETTINGS_DIR" "$WAN2GP_OUTPUTS_DIR"

echo "[3/9] Clone/Update Wan2GP…"
if [ ! -d "$APP_DIR/.git" ]; then
  git clone --depth=1 https://github.com/deepbeepmeep/Wan2GP.git "$APP_DIR"
else
  git -C "$APP_DIR" fetch --all -p
  git -C "$APP_DIR" reset --hard origin/HEAD || true
fi
if [ -n "${WAN2GP_COMMIT:-}" ]; then
  git -C "$APP_DIR" checkout "$WAN2GP_COMMIT"
fi

echo "[4/9] Python venv…"
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
python -V
pip install -U pip wheel setuptools

echo "[5/9] Install PyTorch…"
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo unknown)"
echo "Detected GPU: $GPU_NAME"
if echo "$GPU_NAME" | grep -Eiq '50|Blackwell'; then
  echo "RTX 50xx/Blackwell → Torch 2.7.0 (cu128)"
  pip install --index-url https://download.pytorch.org/whl/cu128 torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0
else
  echo "Installing Torch 2.6.0 (cu124)"
  pip install --index-url https://download.pytorch.org/whl/cu124 torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0
fi

echo "[6/9] Wan2GP requirements…"
pip install -r "$APP_DIR/requirements.txt"

# Stabilize ONNX: default to CPU (most reliable), or pin safer GPU build if requested
if [ "${WAN2GP_ONNX_CUDA}" = "1" ]; then
  echo "Using ONNX Runtime on GPU (pinned ${WAN2GP_ONNX_VER})"
  pip install --upgrade --no-deps "onnxruntime-gpu==${WAN2GP_ONNX_VER}" || true
else
  echo "Disabling ONNX CUDA to improve stability"
  export ORT_DISABLE_CUDA=1
fi

echo "[7/9] Persist outputs…"
if [ -d "$APP_DIR/outputs" ] && [ ! -L "$APP_DIR/outputs" ]; then
  rm -rf "$APP_DIR/outputs"
  ln -s "$WAN2GP_OUTPUTS_DIR" "$APP_DIR/outputs"
fi

echo "[8/9] Start Wan2GP (supervised)…"
cd "$APP_DIR"

# Make sure we log to a persistent file
LOG_FILE="$WORKDIR/wan2gp.log"
touch "$LOG_FILE"

# Clean stop on signals
cleanup() {
  echo "Shutdown requested; stopping Wan2GP…"
  pkill -f "python.*wgp.py" || true
}
trap cleanup INT TERM

# Supervised run: auto-restart on crash
start_app() {
  echo "Launching wgp.py on 0.0.0.0:${WAN2GP_PORT} (logs: $LOG_FILE)"
  # Unbuffered/stdout flush for immediate logs
  PYTHONUNBUFFERED=1 \
  UVICORN_TIMEOUT_KEEP_ALIVE="$UVICORN_TIMEOUT_KEEP_ALIVE" \
  python wgp.py \
    --listen \
    --server-port "${WAN2GP_PORT}" \
    --settings "${WAN2GP_SETTINGS_DIR}" \
    >> "$LOG_FILE" 2>&1
}

# Kick off in background with an auto-restart loop
(
  while true; do
    start_app || true
    echo "Wan2GP exited. Restarting in 5s…" | tee -a "$LOG_FILE"
    sleep 5
  done
) &

APP_WATCH_PID=$!

echo "[9/9] Health probes…"
# 1) Wait for TCP listen
for _ in $(seq 1 120); do
  if ss -ltn 2>/dev/null | grep -q ":${WAN2GP_PORT}"; then
    echo "Port ${WAN2GP_PORT} is listening."
    break
  fi
  sleep 2
done

# 2) Require real HTTP-200 so RunPod turns Ready
# Install curl if missing (for custom bases)
if ! command -v curl >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends curl >/dev/null 2>&1 || true
  fi
fi

READY=0
for _ in $(seq 1 90); do
  if curl -fsS "http://127.0.0.1:${WAN2GP_PORT}/" >/dev/null; then
    READY=1
    echo "HTTP service ready on port ${WAN2GP_PORT}"
    break
  fi
  sleep 2
done

if [ "$READY" -ne 1 ]; then
  echo "Warning: UI didn't return HTTP 200 yet. Last 100 log lines:"
  tail -n 100 "$LOG_FILE" || true
fi

# Keep script in foreground; if supervisor loop dies, exit non-zero
wait "$APP_WATCH_PID"
exit 1
