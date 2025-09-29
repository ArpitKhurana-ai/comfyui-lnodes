#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Wan2GP • RunPod one-click (hardened) ==="

# ---------- Config ----------
export WAN2GP_PORT="${WAN2GP_PORT:-8188}"
export WORKDIR="/workspace"
export APP_DIR="$WORKDIR/Wan2GP"
export VENV_DIR="$WORKDIR/venv-wan2gp"

# Caches/persistence
export HF_HOME="${HF_HOME:-$WORKDIR/hf-home}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$WORKDIR/hf-cache}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$WORKDIR/.cache}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$WORKDIR/pip-cache}"
export WAN2GP_SETTINGS_DIR="${WAN2GP_SETTINGS_DIR:-$WORKDIR/wan2gp-settings}"
export WAN2GP_OUTPUTS_DIR="${WAN2GP_OUTPUTS_DIR:-$WORKDIR/wan2gp-outputs}"

# Perf / stability
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-max_split_size_mb:128,expandable_segments:True}"
export WAN2GP_ONNX_CUDA="${WAN2GP_ONNX_CUDA:-0}"     # keep default CPU for ONNX bits; set 1 later if stable
export WAN2GP_ONNX_VER="${WAN2GP_ONNX_VER:-1.20.1}"
export UVICORN_TIMEOUT_KEEP_ALIVE="${UVICORN_TIMEOUT_KEEP_ALIVE:-75}"
export TOKENIZERS_PARALLELISM="false"
export HF_HUB_ENABLE_HF_TRANSFER="1"

LOG_FILE="$WORKDIR/wan2gp.log"
mkdir -p "$WORKDIR" && : > "$LOG_FILE"

# Detect pathological Docker memory caps early
detect_mem_cap() {
  local lim="max"
  if [ -f /sys/fs/cgroup/memory.max ]; then
    lim=$(cat /sys/fs/cgroup/memory.max || echo max)
  elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes || echo 9223372036854771712)
  fi
  if [[ "$lim" =~ ^(5|53|536870912)$ ]]; then
    echo "[WARN] Container memory appears capped (~512MiB). Clear Docker Args memory limits in Template." | tee -a "$LOG_FILE"
  fi
}
detect_mem_cap

# ---------- System deps ----------
export DEBIAN_FRONTEND=noninteractive
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y >>"$LOG_FILE" 2>&1 || true
  apt-get install -y --no-install-recommends \
    git git-lfs curl ca-certificates ffmpeg \
    build-essential python3-dev pkg-config \
    libgl1 libglib2.0-0 libsm6 libxrender1 libxext6 libsndfile1 \
    iproute2 net-tools >>"$LOG_FILE" 2>&1 || true
  git lfs install >>"$LOG_FILE" 2>&1 || true
fi

# ---------- Folders ----------
mkdir -p "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$XDG_CACHE_HOME" \
         "$WAN2GP_SETTINGS_DIR" "$WAN2GP_OUTPUTS_DIR" "$PIP_CACHE_DIR"

# ---------- Fetch App ----------
if [ ! -d "$APP_DIR/.git" ]; then
  echo "[CLONE] Wan2GP…" | tee -a "$LOG_FILE"
  git clone --depth=1 https://github.com/deepbeepmeep/Wan2GP.git "$APP_DIR" >>"$LOG_FILE" 2>&1
else
  echo "[UPDATE] Wan2GP…" | tee -a "$LOG_FILE"
  git -C "$APP_DIR" fetch --all -p >>"$LOG_FILE" 2>&1 || true
  git -C "$APP_DIR" reset --hard origin/HEAD >>"$LOG_FILE" 2>&1 || true
fi
if [ -n "${WAN2GP_COMMIT:-}" ]; then
  git -C "$APP_DIR" checkout "$WAN2GP_COMMIT" >>"$LOG_FILE" 2>&1 || true
fi

# ---------- Python / Torch ----------
python3 -m venv "$VENV_DIR" 2>/dev/null || true
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
python -V | tee -a "$LOG_FILE"

# Toolchain for reliable PEP517 builds (pin a bit to avoid churn)
pip install -U pip wheel "setuptools<75" "Cython<3.2" ninja --no-cache-dir >>"$LOG_FILE" 2>&1
# Let packages reuse current env for build deps (diffq needs Cython)
export PIP_NO_BUILD_ISOLATION=1

GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo unknown)"
echo "GPU: $GPU_NAME" | tee -a "$LOG_FILE"

# Good defaults for A40 (CUDA 12.4). Use cu128 only for 50-series/Blackwell.
if echo "$GPU_NAME" | grep -Eiq '50|Blackwell'; then
  echo "[TORCH] 2.7.0 cu128" | tee -a "$LOG_FILE"
  pip install --index-url https://download.pytorch.org/whl/cu128 \
    torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 >>"$LOG_FILE" 2>&1
else
  echo "[TORCH] 2.6.0 cu124" | tee -a "$LOG_FILE"
  pip install --index-url https://download.pytorch.org/whl/cu124 \
    torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 >>"$LOG_FILE" 2>&1
fi

# ---------- Preinstall sticky wheels ----------
# diffq needs Cython visible; do it upfront to avoid metadata build failure
pip install --no-cache-dir --prefer-binary diffq==0.2.4 >>"$LOG_FILE" 2>&1 || true

# ---------- Python deps (prefer wheels, retry once) ----------
echo "[PIP] requirements…" | tee -a "$LOG_FILE"
pip install --upgrade --prefer-binary \
  -r "$APP_DIR/requirements.txt" >>"$LOG_FILE" 2>&1 || {
  echo "[PIP] retrying…" | tee -a "$LOG_FILE"
  pip install --upgrade --prefer-binary \
    -r "$APP_DIR/requirements.txt" >>"$LOG_FILE" 2>&1 || true
}

# ---------- Stabilize ONNX ----------
if [ "$WAN2GP_ONNX_CUDA" = "1" ]; then
  echo "[ONNX] GPU ${WAN2GP_ONNX_VER}" | tee -a "$LOG_FILE"
  pip install --upgrade --no-deps "onnxruntime-gpu==${WAN2GP_ONNX_VER}" >>"$LOG_FILE" 2>&1 || true
else
  echo "[ONNX] Disable CUDA for stability" | tee -a "$LOG_FILE"
  export ORT_DISABLE_CUDA=1
fi

# ---------- Persist outputs ----------
if [ -d "$APP_DIR/outputs" ] && [ ! -L "$APP_DIR/outputs" ]; then
  rm -rf "$APP_DIR/outputs"
  ln -s "$WAN2GP_OUTPUTS_DIR" "$APP_DIR/outputs"
fi

# ---------- Free port (previous crash) ----------
echo "[NET] Freeing :$WAN2GP_PORT if occupied…" | tee -a "$LOG_FILE"
ss -ltnp 2>/dev/null | grep -q ":${WAN2GP_PORT} " && fuser -k "${WAN2GP_PORT}/tcp" || true
sleep 1

# ---------- Launch (supervised, auto-restart) ----------
cd "$APP_DIR"
touch "$LOG_FILE"

cleanup() { echo "[CLEANUP] stopping…" | tee -a "$LOG_FILE"; pkill -f "python.*wgp.py" || true; }
trap cleanup INT TERM

start_app() {
  echo "[RUN] WanGP on :${WAN2GP_PORT}" | tee -a "$LOG_FILE"
  PYTHONUNBUFFERED=1 \
  GRADIO_SERVER_NAME="0.0.0.0" \
  GRADIO_SERVER_PORT="$WAN2GP_PORT" \
  UVICORN_TIMEOUT_KEEP_ALIVE="$UVICORN_TIMEOUT_KEEP_ALIVE" \
  python wgp.py \
    --listen \
    --server-port "${WAN2GP_PORT}" \
    --settings "${WAN2GP_SETTINGS_DIR}" \
    >>"$LOG_FILE" 2>&1
}

( while true; do
    start_app || true
    echo "[SUPERVISOR] app exited; restarting in 5s…" | tee -a "$LOG_FILE"
    sleep 5
  done ) & APP_WATCH=$!

# ---------- Health: wait for real app ----------
echo "[HEALTH] Waiting for HTTP 200 on / …" | tee -a "$LOG_FILE"
READY=0
for _ in $(seq 1 180); do
  if curl -fsS "http://127.0.0.1:${WAN2GP_PORT}/" >/dev/null; then
    READY=1; break
  fi
  sleep 2
done

if [ "$READY" -eq 1 ]; then
  echo "HTTP service ready on port ${WAN2GP_PORT}" | tee -a "$LOG_FILE"
else
  echo "[HEALTH] UI not ready yet — last 200 log lines:" | tee -a "$LOG_FILE"
  tail -n 200 "$LOG_FILE" || true
fi

wait "$APP_WATCH"
exit 1
