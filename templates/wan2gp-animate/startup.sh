#!/usr/bin/env bash
# WanGP one-click (RunPod) — fast first boot + stable restarts
set -uo pipefail

echo "=== WanGP bootstrap (fast) ==="

# ---------- Config ----------
export WAN2GP_PORT="${WAN2GP_PORT:-8188}"        # external (proxy) port
export WAN2GP_INNER_PORT=8189                    # internal WanGP port (we proxy 8188->8189)
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

# perf/stability
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-max_split_size_mb:128,expandable_segments:True}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
export WAN2GP_ONNX_CUDA="${WAN2GP_ONNX_CUDA:-0}"
export WAN2GP_ONNX_VER="${WAN2GP_ONNX_VER:-1.20.1}"
export UVICORN_TIMEOUT_KEEP_ALIVE="${UVICORN_TIMEOUT_KEEP_ALIVE:-120}"

# ---------- Helpers ----------
retry() {
  # retry <attempts> <sleep> <command...>
  local -r attempts="$1"; shift
  local -r delay="$1"; shift
  local n=1
  until "$@"; do
    if (( n >= attempts )); then return 1; fi
    echo "retry: attempt $n failed; retrying in ${delay}s…" >&2
    sleep "$delay"; n=$((n+1))
  done
}

log() { echo "[$(date +'%F %T')] $*" | tee -a "$LOG_FILE"; }

finish() {
  log "Shutdown requested."
  pkill -f "python.*http.server.*${WAN2GP_PORT}" || true
  pkill -f "socat.*:${WAN2GP_PORT}" || true
  pkill -f "python.*wgp.py" || true
}
trap finish INT TERM

mkdir -p "$WORKDIR" "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$XDG_CACHE_HOME" \
         "$WAN2GP_SETTINGS_DIR" "$WAN2GP_OUTPUTS_DIR" "$PIP_CACHE_DIR"
touch "$LOG_FILE"

ulimit -n 524288 || true

# ---------- Warm page to avoid 502 ----------
log "Starting warm-up page on :${WAN2GP_PORT}…"
cat > "$WORKDIR/index.html" <<'HTML'
<!doctype html><meta charset="utf-8">
<title>WanGP is starting…</title>
<style>body{font-family:system-ui;margin:40px;max-width:720px}code{background:#f2f2f2;padding:2px 6px;border-radius:4px}</style>
<h1>WanGP is starting…</h1>
<p>First boot installs dependencies and downloads models. This page will switch to the app automatically when ready.</p>
HTML

# Serve immediately so RunPod proxy never shows 502
python -m http.server "$WAN2GP_PORT" --directory "$WORKDIR" >/dev/null 2>&1 &
WARM_PID=$!

# ---------- System deps ----------
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  retry 5 5 bash -lc 'apt-get update -y' || true
  retry 5 5 bash -lc 'apt-get install -y --no-install-recommends git git-lfs ffmpeg python3-venv curl ca-certificates socat iproute2' || true
  git lfs install || true
else
  log "apt-get not available; skipping system packages."
fi

# ---------- Clone/Update Wan2GP ----------
if [ ! -d "$APP_DIR/.git" ]; then
  log "Cloning Wan2GP…"
  retry 5 5 git clone --depth=1 https://github.com/deepbeepmeep/Wan2GP.git "$APP_DIR" || {
    log "ERROR: clone failed"; sleep 3; exit 1; }
else
  log "Updating Wan2GP…"
  ( cd "$APP_DIR" && git fetch --all -p && git reset --hard origin/HEAD ) || true
fi

# ---------- Python venv ----------
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
python -V
pip install -U pip wheel setuptools -q

# ---------- Torch ----------
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo unknown)"
log "Detected GPU: $GPU_NAME"
if echo "$GPU_NAME" | grep -Eiq '50|Blackwell'; then
  log "Installing Torch 2.7.0 (cu128)…"
  retry 3 5 pip install --prefer-binary --retries 5 --timeout 120 \
    --index-url https://download.pytorch.org/whl/cu128 \
    torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 || true
else
  log "Installing Torch 2.6.0 (cu124)…"
  retry 3 5 pip install --prefer-binary --retries 5 --timeout 120 \
    --index-url https://download.pytorch.org/whl/cu124 \
    torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 || true
fi

# ---------- Requirements ----------
log "Installing Wan2GP requirements…"
retry 3 5 pip install --prefer-binary --retries 5 --timeout 180 -r "$APP_DIR/requirements.txt" || true

# ONNX stability
if [ "${WAN2GP_ONNX_CUDA}" = "1" ]; then
  log "Using onnxruntime-gpu ${WAN2GP_ONNX_VER}"
  retry 3 5 pip install --no-deps --retries 5 --timeout 120 "onnxruntime-gpu==${WAN2GP_ONNX_VER}" || true
else
  export ORT_DISABLE_CUDA=1
  log "ONNX CUDA disabled for stability."
fi

# Persist outputs
if [ -d "$APP_DIR/outputs" ] && [ ! -L "$APP_DIR/outputs" ]; then
  rm -rf "$APP_DIR/outputs"
  ln -s "$WAN2GP_OUTPUTS_DIR" "$APP_DIR/outputs"
fi

# ---------- Start WanGP on inner port ----------
cd "$APP_DIR"
log "Launching WanGP on :${WAN2GP_INNER_PORT} (logs: $LOG_FILE)…"
(
  PYTHONUNBUFFERED=1 \
  UVICORN_TIMEOUT_KEEP_ALIVE="$UVICORN_TIMEOUT_KEEP_ALIVE" \
  python wgp.py \
    --listen \
    --server-port "${WAN2GP_INNER_PORT}" \
    --settings "${WAN2GP_SETTINGS_DIR}" \
    >> "$LOG_FILE" 2>&1
) &
WGP_PID=$!

# ---------- Wait until WanGP is healthy, then proxy 8188 -> 8189 ----------
log "Waiting for WanGP HTTP 200…"
for _ in $(seq 1 240); do
  if curl -fsS "http://127.0.0.1:${WAN2GP_INNER_PORT}/" >/dev/null 2>&1; then
    log "WanGP is up."
    break
  fi
  sleep 2
done

# Switch 8188 from warm page to TCP proxy
log "Switching 8188 to proxy WanGP…"
kill "$WARM_PID" 2>/dev/null || true
sleep 1
socat TCP-LISTEN:${WAN2GP_PORT},fork,reuseaddr TCP:127.0.0.1:${WAN2GP_INNER_PORT} &
SOCAT_PID=$!

log "Ready at http://127.0.0.1:${WAN2GP_PORT} (proxied to :${WAN2GP_INNER_PORT})"

# ---------- Supervise ----------
# If either child dies, print tail and exit non-zero so RunPod can restart.
( tail -n +1 -F "$LOG_FILE" & ) 2>/dev/null
wait -n "$WGP_PID" "$SOCAT_PID"
log "WanGP/proxy exited. Last 100 lines:"
tail -n 100 "$LOG_FILE" || true
exit 1
