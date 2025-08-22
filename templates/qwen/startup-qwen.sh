#!/usr/bin/env bash
set -euo pipefail

# --- Settings (you can override via env) ---
ROOT="${ROOT:-/workspace/qwen}"
COMFY="$ROOT/ComfyUI"
INNER_PORT="${INNER_PORT:-8189}"     # ComfyUI internal
PUBLIC_PORT="${PUBLIC_PORT:-3001}"   # Exposed via Caddy
USER="${BASIC_AUTH_USER:-arpit}"
PASS="${BASIC_AUTH_PASS:-changeme}"

echo "==> Preparing folders at $ROOT ..."
mkdir -p "$ROOT"
cd "$ROOT"

echo "==> Ensuring ComfyUI..."
if [ ! -d "$COMFY" ]; then
  git clone https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
fi
git -C "$COMFY" pull || true

echo "==> Minimal deps ..."
python3 -m pip install -q --upgrade pip
python3 -m pip install -q huggingface_hub requests

echo "==> Fetching Qwen-Image-Edit weights ..."
python3 - <<'PY'
from huggingface_hub import hf_hub_download
import os, shutil
base = os.path.join(os.environ.get("COMFY","/workspace/qwen/ComfyUI"), "models")
items = [
  ("Comfy-Org/Qwen-Image-Edit_ComfyUI","qwen_image_edit_fp8_e4m3fn.safetensors","diffusion_models"),
  ("Comfy-Org/Qwen-Image_ComfyUI","qwen_2.5_vl_7b_fp8_scaled.safetensors","text_encoders"),
  ("Comfy-Org/Qwen-Image_ComfyUI","qwen_image_vae.safetensors","vae"),
  ("Comfy-Org/Qwen-Image_ComfyUI","Qwen-Image-Lightning-4steps-V1.0.safetensors","loras"), # optional
]
for repo,fname,dst in items:
    dst_dir = os.path.join(base, dst)
    os.makedirs(dst_dir, exist_ok=True)
    p = hf_hub_download(repo_id=repo, filename=fname)
    shutil.copy(p, os.path.join(dst_dir, fname))
    print("✓", dst, fname)
PY

echo "==> Launching ComfyUI on 127.0.0.1:${INNER_PORT} ..."
cd "$COMFY"
nohup python3 main.py --listen 127.0.0.1 --port "${INNER_PORT}" > "$ROOT/comfy.log" 2>&1 &

echo "==> Installing Caddy reverse proxy ..."
cd "$ROOT"
if [ ! -f "$ROOT/caddy" ]; then
  curl -L https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_amd64.tar.gz -o caddy.tgz
  tar -xzf caddy.tgz
fi
HASH="$("$ROOT/caddy" hash-password --plaintext "$PASS")"

cat > "$ROOT/Caddyfile" <<EOF
:${PUBLIC_PORT} {
  encode gzip
  basicauth /* {
    ${USER} ${HASH}
  }
  reverse_proxy 127.0.0.1:${INNER_PORT}
}
EOF

echo "==> Starting Caddy on :${PUBLIC_PORT} ..."
exec "$ROOT/caddy" run --config "$ROOT/Caddyfile"
