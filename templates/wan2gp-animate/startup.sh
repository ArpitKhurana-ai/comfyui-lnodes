#!/usr/bin/env bash
set -Eeuo pipefail

echo "=== Wan2GP • RunPod one-click (hardened) ==="

# ---------------- Config ----------------
export WAN2GP_PORT="${WAN2GP_PORT:-8188}"
export WORKDIR="/workspace"
export APP_DIR="$WORKDIR/Wan2GP"
export VENV_DIR="$WORKDIR/venv-wan2gp"

# Caches / persistence
export HF_HOME="${HF_HOME:-$WORKDIR/hf-home}"
export HUGGINGFACE_HUB_CACHE="${HUGGINGFACE_HUB_CACHE:-$WORKDIR/hf-cache}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$WORKDIR/.cache}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$WORKDIR/pip-cache}"
export WAN2GP_SETTINGS_DIR="${WAN2GP_SETTINGS_DIR:-$WORKDIR/wan2gp-settings}"
export WAN2GP_OUTPUTS_DIR="${WAN2GP_OUTPUTS_DIR:-$WORKDIR/wan2gp-outputs}"

# Perf / stability
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-max_split_size_mb:128,expandable_segments:True}"
export WAN2GP_ONNX_CUDA="${WAN2GP_ONNX_CUDA:-0}"   # set 1 later if you want to try GPU ONNX
export WAN2GP_ONNX_VER="${WAN2GP_ONNX_VER:-1.20.1}"
export UVICORN_TIMEOUT_KEEP_ALIVE="${UVICORN_TIMEOUT_KEEP_ALIVE:-75}"
export TOKENIZERS_PARALLELISM="false"
export HF_HUB_ENABLE_HF_TRANSFER="1"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"

LOG_FILE="$WORKDIR/wan2gp.log"
BOOT_OK="$WORKDIR/.wan2gp_boot_ok"
mkdir -p "$WORKDIR" && : > "$LOG_FILE"

# ------------- Helpers -------------
log(){ echo "$@" | tee -a "$LOG_FILE"; }

detect_mem_cap(){
  local lim="max"
  if [ -f /sys/fs/cgroup/memory.max ]; then
    lim=$(cat /sys/fs/cgroup/memory.max || echo max)
  elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes || echo 9223372036854771712)
  fi
  # ~512MiB detection
  if [[ "$lim" =~ ^(5|53|536870912)$ ]]; then
    log "[WARN] Container memory appears capped (~512MiB). Remove any --memory=512m Docker Arg in your Template. Add --shm-size 2g."
  fi
}

free_port(){
  log "[NET] Freeing :$WAN2GP_PORT if occupied…"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -q ":${WAN2GP_PORT} " && fuser -k "${WAN2GP_PORT}/tcp" || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$WAN2GP_PORT" -sTCP:LISTEN -t 2>/dev/null | xargs -r kill -9 || true
  else
    # best effort
    fuser -k "${WAN2GP_PORT}/tcp" 2>/dev/null || true
  fi
  sleep 1
}

gpu_name(){
  nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo unknown
}

has_torch(){
  python - <<'PY'
try:
  import torch, torchvision, torchaudio
  print("OK")
except Exception:
  raise SystemExit(1)
PY
}

sanity_imports(){
  python - <<'PY'
mods = ["mmgp","diffusers","transformers","gradio"]
for m in mods:
  __import__(m)
print("OK")
PY
}

# ------------- Bootstrap (first run only) -------------
detect_mem_cap

export DEBIAN_FRONTEND=noninteractive
if [ ! -f "$BOOT_OK" ] || [ "${WAN2GP_FORCE_SETUP:-0}" = "1" ]; then
  log "[BOOTSTRAP] First-time setup…"

  # System deps (full set incl. OpenCV/audio + networking tools)
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >>"$LOG_FILE" 2>&1 || true
    apt-get install -y --no-install-recommends \
      git git-lfs curl ca-certificates ffmpeg \
      build-essential python3-dev pkg-config \
      libgl1 libglib2.0-0 libsm6 libxrender1 libxext6 libsndfile1 \
      iproute2 net-tools >>"$LOG_FILE" 2>&1 || true
    git lfs install >>"$LOG_FILE" 2>&1 || true
  fi

  # Folders
  mkdir -p "$HF_HOME" "$HUGGINGFACE_HUB_CACHE" "$XDG_CACHE_HOME" \
           "$WAN2GP_SETTINGS_DIR" "$WAN2GP_OUTPUTS_DIR" "$PIP_CACHE_DIR"

  # Fetch / update app
  if [ ! -d "$APP_DIR/.git" ]; then
    log "[CLONE] Wan2GP…"
    git clone --depth=1 https://github.com/deepbeepmeep/Wan2GP.git "$APP_DIR" >>"$LOG_FILE" 2>&1
  else
    log "[UPDATE] Wan2GP…"
    git -C "$APP_DIR" fetch --all -p >>"$LOG_FILE" 2>&1 || true
    git -C "$APP_DIR" reset --hard origin/HEAD >>"$LOG_FILE" 2>&1 || true
  fi
  if [ -n "${WAN2GP_COMMIT:-}" ]; then
    git -C "$APP_DIR" checkout "$WAN2GP_COMMIT" >>"$LOG_FILE" 2>&1 || true
  fi

  # Python / venv
  python3 -m venv "$VENV_DIR" 2>/dev/null || true
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python -V | tee -a "$LOG_FILE"

  # Build toolchain (pin to avoid PEP517 churn) + allow in-env build deps
  pip install -U pip wheel "setuptools<75" "Cython<3.2" ninja --no-cache-dir >>"$LOG_FILE" 2>&1
  export PIP_NO_BUILD_ISOLATION=1

  # Torch (install only if missing)
  GPU="$(gpu_name)"; log "GPU: $GPU"
  if ! has_torch >/dev/null 2>&1; then
    if echo "$GPU" | grep -Eiq '50|Blackwell'; then
      log "[TORCH] 2.7.0 cu128"
      pip install --index-url https://download.pytorch.org/whl/cu128 \
        torch==2.7.0 torchvision==0.22.0 torchaudio==2.7.0 >>"$LOG_FILE" 2>&1
    else
      log "[TORCH] 2.6.0 cu124"
      pip install --index-url https://download.pytorch.org/whl/cu124 \
        torch==2.6.0 torchvision==0.21.0 torchaudio==2.6.0 >>"$LOG_FILE" 2>&1
    fi
  else
    log "[TORCH] already present"
  fi

  # Preinstall sticky wheel to avoid Cython metadata failure later
  pip install --no-cache-dir --prefer-binary diffq==0.2.4 >>"$LOG_FILE" 2>&1 || true

  # Requirements (prefer wheels; one retry)
  log "[PIP] requirements…"
  pip install --upgrade --prefer-binary -r "$APP_DIR/requirements.txt" >>"$LOG_FILE" 2>&1 || {
    log "[PIP] retrying…"
    pip install --upgrade --prefer-binary -r "$APP_DIR/requirements.txt" >>"$LOG_FILE" 2>&1 || true
  }

  # ONNX toggle
  if [ "$WAN2GP_ONNX_CUDA" = "1" ]; then
    log "[ONNX] GPU ${WAN2GP_ONNX_VER}"
    pip install --upgrade --no-deps "onnxruntime-gpu==${WAN2GP_ONNX_VER}" >>"$LOG_FILE" 2>&1 || true
  else
    log "[ONNX] Disable CUDA for stability"
    export ORT_DISABLE_CUDA=1
  fi

  # Persist outputs
  if [ -d "$APP_DIR/outputs" ] && [ ! -L "$APP_DIR/outputs" ]; then
    rm -rf "$APP_DIR/outputs"
    ln -s "$WAN2GP_OUTPUTS_DIR" "$APP_DIR/outputs"
  fi

  # Sanity imports (catches mmgp/diffusers/gradio issues before we loop)
  if sanity_imports >/dev/null 2>&1; then
    touch "$BOOT_OK"
    log "[BOOTSTRAP] Done ✔  (sentinel: $BOOT_OK)"
  else
    log "[BOOTSTRAP] Sanity import failed — last 200 lines:"
    tail -n 200 "$LOG_FILE" || true
  fi

else
  # Fast path on restarts
  log "[BOOTSTRAP] Skipped (found $BOOT_OK)."
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python -V | tee -a "$LOG_FILE"
  export PIP_NO_BUILD_ISOLATION=1
  if [ "$WAN2GP_ONNX_CUDA" != "1" ]; then export ORT_DISABLE_CUDA=1; fi
fi

# ------------- Run (supervised) -------------
cd "$APP_DIR"
free_port

cleanup(){ log "[CLEANUP] stopping…"; pkill -9 -f "python.*wgp.py" || true; }
trap cleanup INT TERM

start_app(){
  log "[RUN] WanGP on :${WAN2GP_PORT}"
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
    log "[SUPERVISOR] app exited; restarting in 5s…"
    sleep 5
  done ) & APP_WATCH=$!

# ------------- Health: 6 min (180*2s) -------------
log "[HEALTH] Waiting for HTTP 200 on / …"
READY=0
for _ in $(seq 1 180); do
  if curl -fsS "http://127.0.0.1:${WAN2GP_PORT}/" >/dev/null; then READY=1; break; fi
  sleep 2
done

if [ "$READY" -eq 1 ]; then
  log "HTTP service ready on port ${WAN2GP_PORT}"
else
  log "[HEALTH] UI not ready — last 200 lines:"
  tail -n 200 "$LOG_FILE" || true
fi

wait "$APP_WATCH"
exit 1
