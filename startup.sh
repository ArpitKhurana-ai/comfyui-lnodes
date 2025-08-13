#!/bin/bash
set -euo pipefail

# ===== Logging =====
mkdir -p /app
rm -f /app/startup.log || true
exec > >(tee -a /app/startup.log) 2>&1

echo "🟡 Starting ComfyUI LinkedIn Edition Setup..."

# ===== Basics & TZ =====
export DEBIAN_FRONTEND=noninteractive
ln -fs /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
dpkg-reconfigure -f noninteractive tzdata || true

# Minimal build tools for packages like insightface when needed
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl wget git unzip tar build-essential
rm -rf /var/lib/apt/lists/*

umask 000 # make files group-writable for safety with mounted volumes

# ===== Hugging Face login (optional) =====
if [[ -n "${HF_TOKEN:-}" ]]; then
  echo "🔐 Authenticating Hugging Face..."
  huggingface-cli login --token "$HF_TOKEN" || true
else
  echo "ℹ️ HF_TOKEN not set; proceeding without HF auth"
fi

# ===== Persistent paths =====
export WORKDIR="/workspace"
export COMFY_DIR="$WORKDIR/ComfyUI"
export MODELS_DIR="$WORKDIR/models"
export FB_DIR="$WORKDIR/filebrowser"
export BIN_DIR="$WORKDIR/bin"

mkdir -p "$WORKDIR" "$MODELS_DIR" "$FB_DIR" "$BIN_DIR"
chmod -R 777 "$WORKDIR"

# ===== ComfyUI clone/link (idempotent) =====
cd "$WORKDIR"
if [[ ! -f "$COMFY_DIR/main.py" ]]; then
  echo "🧹 Cloning ComfyUI..."
  rm -rf "$COMFY_DIR"
  git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  echo "🔄 Updating ComfyUI..."
  (cd "$COMFY_DIR" && git fetch --all -p && git pull --rebase || true)
fi

# Link /workspace/models → ComfyUI/models (symlink)
if [[ -L "$COMFY_DIR/models" || -d "$COMFY_DIR/models" ]]; then
  rm -rf "$COMFY_DIR/models"
fi
ln -s "$MODELS_DIR" "$COMFY_DIR/models"

if [[ ! -L "$COMFY_DIR/models" ]]; then
  echo "❌ Symlink creation failed for models folder."
  ls -l "$COMFY_DIR"
  exit 1
else
  echo "✅ Verified: $COMFY_DIR/models ➝ $MODELS_DIR"
fi

# ===== Python deps =====
python3 -m pip install --upgrade pip
python3 -m pip install -q huggingface_hub onnxruntime-gpu insightface piexif segment-anything

# ===== Prepare model folders (idempotent) =====
for folder in checkpoints clip configs controlnet ipadapter upscale_models vae clip_vision instantid insightface/models/antelopev2; do
  mkdir -p "$MODELS_DIR/$folder"
done
chmod -R 777 "$MODELS_DIR"

# Clean accidental nested clip_vision
rm -rf "$MODELS_DIR/clip_vision/clip_vision" || true

# ===== Sync models from Hugging Face (idempotent) =====
echo "⬇️ Syncing models via snapshot_download..."
python3 - <<'PY'
import os
from huggingface_hub import snapshot_download
dst_dir = os.environ['MODELS_DIR']
token = os.environ.get('HF_TOKEN', None)
snapshot_download(
    repo_id='ArpitKhurana/comfyui-models',
    repo_type='model',
    local_dir=dst_dir,
    local_dir_use_symlinks=False,
    token=token
)
PY
chmod -R 777 "$MODELS_DIR"

# ===== Sanity checks (critical models) =====
echo "🔍 Checking critical model files..."
check() { [[ -f "$MODELS_DIR/$1" ]] && echo "✅ Found: $MODELS_DIR/$1" || { echo "❌ Missing: $MODELS_DIR/$1"; exit 1; }; }
check "checkpoints/sd_xl_base_1.0.safetensors"
check "checkpoints/realisticVisionV60B1_v51HyperVAE.safetensors"
check "vae/sdxl.vae.safetensors"
check "instantid/ip-adapter.bin"
check "controlnet/OpenPoseXL2.safetensors"
check "insightface/models/antelopev2/1k3d68.onnx"
check "insightface/models/antelopev2/glintr100.onnx"
check "clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"
echo "✅ All critical models are in place."

# ===== Sync custom nodes & workflows from your repo (NON-DESTRUCTIVE) =====
echo "📦 Syncing custom nodes & workflows from comfyui-lnodes..."
TMP_LNODES="/tmp/lnodes"
rm -rf "$TMP_LNODES"
git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git "$TMP_LNODES" || true

mkdir -p "$COMFY_DIR/custom_nodes" "$COMFY_DIR/workflows"
# copy new files, keep existing ones (do NOT delete local changes)
rsync -a --ignore-existing "$TMP_LNODES/custom_nodes/" "$COMFY_DIR/custom_nodes/" || true
rsync -a --ignore-existing "$TMP_LNODES/workflows/" "$COMFY_DIR/workflows/" || true

# Optional: ensure ComfyUI-Manager & Impact-Pack exist (only if missing)
if [[ ! -d "$COMFY_DIR/custom_nodes/ComfyUI-Manager" ]]; then
  git clone https://github.com/ltdrdata/ComfyUI-Manager.git "$COMFY_DIR/custom_nodes/ComfyUI-Manager" || true
fi
if [[ ! -d "$COMFY_DIR/custom_nodes/ComfyUI-Impact-Pack" ]]; then
  git clone https://github.com/ltdrdata/ComfyUI-Impact-Pack.git "$COMFY_DIR/custom_nodes/ComfyUI-Impact-Pack" || true
  touch "$COMFY_DIR/custom_nodes/ComfyUI-Impact-Pack/__init__.py"
fi

# ===== Launch ComfyUI (idempotent) =====
echo "🚀 Launching ComfyUI..."
pkill -f "ComfyUI/main.py" 2>/dev/null || true
nohup python3 "$COMFY_DIR/main.py" --listen 0.0.0.0 --port 8188 > "$WORKDIR/comfyui.log" 2>&1 &

# ===== FileBrowser: install once, keep DB on /workspace =====
echo "🗂 Setting up FileBrowser..."
FB_BIN="$BIN_DIR/filebrowser"
if [[ ! -x "$FB_BIN" ]]; then
  echo "⬇️ Downloading FileBrowser binary (persisted in $BIN_DIR)"
  cd "$WORKDIR"
  wget -q https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz -O fb.tar.gz
  tar --no-same-owner -xzf fb.tar.gz
  rm -f fb.tar.gz
  mv filebrowser "$FB_BIN"
  chmod +x "$FB_BIN"
fi

mkdir -p "$FB_DIR"
chmod -R 777 "$FB_DIR"

# If DB missing, initialize and optionally create admin user from env
FB_DB="$FB_DIR/filebrowser.db"
if [[ ! -f "$FB_DB" ]]; then
  echo "🆕 Initializing FileBrowser DB..."
  "$FB_BIN" -d "$FB_DB" -r "$WORKDIR" config init
  # Create admin user if creds provided via env
  if [[ -n "${FILEBROWSER_USER:-}" && -n "${FILEBROWSER_PASS:-}" ]]; then
    PASS_HASH=$("$FB_BIN" hash "$FILEBROWSER_PASS")
    "$FB_BIN" -d "$FB_DB" users add "$FILEBROWSER_USER" "$PASS_HASH" --perm.admin --password-hash
    echo "✅ FileBrowser admin user created: $FILEBROWSER_USER"
  else
    echo "ℹ️ FILEBROWSER_USER/PASS not set. Use default or set via env for first boot."
  fi
fi

echo "🚀 Starting FileBrowser..."
pkill -f "$FB_BIN" 2>/dev/null || true
nohup "$FB_BIN" -r "$WORKDIR" --address 0.0.0.0 -p 8080 -d "$FB_DB" > "$WORKDIR/filebrowser.log" 2>&1 &

# ===== Show open ports (best-effort) =====
ss -tulpn | grep LISTEN || true

# ===== Tail logs =====
echo "📄 Tailing logs..."
tail -f "$WORKDIR/comfyui.log" "$WORKDIR/filebrowser.log"
