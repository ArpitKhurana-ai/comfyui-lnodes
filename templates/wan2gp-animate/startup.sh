#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Wan2GP One-Click Startup (RunPod • FAST) ==="

# ---------- Paths & config ----------
export WAN2GP_PORT="${WAN2GP_PORT:-8188}"
export WORKDIR="/workspace"
export APP_DIR="$WORKDIR/Wan2GP"
export VENV_DIR="$WORKDIR/venv-wan2gp"
export HF_HOME="${HF_HOME:-$WORKDIR/hf-home}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$WORKDIR/hf-cache}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$WORKDIR/.cache}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$WORKDIR/pip-cache}"
export WAN2GP_SETTINGS_DIR="$WORKDIR/wan2gp-settings"
export WAN2GP_OUTPUTS_DIR="$WORKDIR/wan2gp-outputs"
export LOG_FILE="$WORKDIR/wan2gp.log"

# stability/perf
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-max_split_size_mb:128,expandable_segments:True}"
export GRADIO_SERVER_NAME="0.0.0.0"
export GRADIO_SERVER_PORT="$WAN2GP_PORT"
export UVICORN_TIMEOUT_KEEP_ALIVE="${UVICORN_TIMEOUT_KEEP_ALIVE:-75}"

# ONNX: GPU can crash on some cards; default to CPU (diffusion stays on GPU)
export WAN2GP_ONNX_CUDA="${WAN2GP_ONNX_CUDA:-0}"
export WAN2GP_ONNX_VER="${WAN2GP_ONNX_VER:-1.20.1}"
# -----------------------------------

step() { echo -e "\n[${1}] ${2}"; }

step 1 "System prep (apt-lite)…"
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y -o=Dpkg::Use-Pty=0
  apt-get install -y --no-install-recommends ffmpeg git-lfs python3-venv curl ca-certificates
  git lfs install || true
fi

step 2 "Create folders…"
mkdir -p "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$XDG_CACHE_HOME" \
         "$WAN2GP_SETTINGS_DIR" "$WAN2GP_OUTPUTS_DIR" "$PIP_CACHE_DIR"
touch "$LOG_FILE"

step 3 "Clone/Update Wan2GP…"
if [ ! -d "$APP_DIR/.git" ]; then
  git clone --depth=1 https://github.com/deepbeepmeep/Wan2GP.git "$APP_DIR"
else
  git -C "$APP_DIR" fetch --all -p
  git -C "$APP_DIR" reset --hard origin/HEAD || true
fi
# (Optional pin) if set from env
if [ -n "${WAN2GP_COMMIT:-}" ]; then
  git -C "$APP_DIR" checkout "$WAN2GP_COMMIT"
fi

step 4 "Python venv…"
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
python -V
python -m pip install -U pip wheel setuptools

step 5 "Torch check (skip if base image already has it)…"
python - <<'PY' || true
import sys
try:
  import torch, torch.version
  print("Torch OK:", torch.__version__, "CUDA:", torch.version.cuda)
except Exception as e:
  sys.exit(1)
PY
if [ $? -ne 0 ]; then
  echo "Installing Torch 2.6.0 (cu124) because base image lacked it…"
  python -m pip install --index-url https://download.pytorch.org/whl/cu124 \
    torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0
else
  echo "Torch already present; skipping heavy CUDA wheels."
fi

step 6 "Wan2GP requirements (prefer wheels, cache on) …"
# General pip speed knobs
export PIP_NO_INPUT=1
# Install CPU ONNX by default (smaller & more stable); you can switch later
if [ "${WAN2GP_ONNX_CUDA}" = "1" ]; then
  ONNX_PKGS="onnxruntime-gpu==${WAN2GP_ONNX_VER}"
else
  export ORT_DISABLE_CUDA=1
  ONNX_PKGS="onnxruntime==${WAN2GP_ONNX_VER}"
fi

# Do Wan2GP core first (diffusers/transformers/open_clip etc.)
python -m pip install -r "$APP_DIR/requirements.txt" --no-deps
# Then add the pinned heavy deps with wheels (lets pip resolve quickly)
python -m pip install $ONNX_PKGS --upgrade --prefer-binary || true
# Now resolve the rest (this two-phase approach avoids slow source builds)
python -m pip install -r "$APP_DIR/requirements.txt" --prefer-binary

step 7 "Persist outputs…"
if [ -d "$APP_DIR/outputs" ] && [ ! -L "$APP_DIR/outputs" ]; then
  rm -rf "$APP_DIR/outputs"
  ln -s "$WAN2GP_OUTPUTS_DIR" "$APP_DIR/outputs"
fi

step 8 "Start Wan2GP (supervised)…"
cd "$APP_DIR"

cleanup() {
  echo "Shutdown requested; stopping Wan2GP…" | tee -a "$LOG_FILE"
  pkill -f "python.*wgp.py" || true
}
trap cleanup INT TERM

run_app() {
  echo "Launching wgp.py on 0.0.0.0:${WAN2GP_PORT} (logs: $LOG_FILE)"
  PYTHONUNBUFFERED=1 \
  UVICORN_TIMEOUT_KEEP_ALIVE="$UVICORN_TIMEOUT_KEEP_ALIVE" \
  python wgp.py \
    --listen \
    --server-port "${WAN2GP_PORT}" \
    --settings "${WAN2GP_SETTINGS_DIR}" \
    >> "$LOG_FILE" 2>&1
}

( while true; do run_app || true; echo "Wan2GP exited. Restart in 5s…" | tee -a "$LOG_FILE"; sleep 5; done ) &

APP_PID=$!

step 9 "Health probe (TCP + real HTTP)…"
# Wait TCP first (port actually listening)
for _ in $(seq 1 120); do
  if ss -ltn 2>/dev/null | grep -q ":${WAN2GP_PORT}"; then
    echo "TCP listening on ${WAN2GP_PORT}"
    break
  fi
  sleep 2
done

# Then require HTTP 200 so RunPod flips to Ready only when UI works
if ! command -v curl >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends curl >/dev/null 2>&1 || true
fi

READY=0
for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${WAN2GP_PORT}/" >/dev/null; then
    READY=1
    echo "[READY] Wan2GP UI is answering on port ${WAN2GP_PORT}"
    break
  fi
  sleep 2
done

if [ "$READY" -ne 1 ]; then
  echo "Warning: UI not HTTP-ready yet. Tail of log:"
  tail -n 120 "$LOG_FILE" || true
fi

# keep foreground so container stays up; if supervisor dies, exit non-zero
wait "$APP_PID"
exit 1
