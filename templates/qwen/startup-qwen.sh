#!/usr/bin/env bash
set -euo pipefail

# --- settings (overridable via env) ---
ROOT="${ROOT:-/workspace/qwen}"
COMFY="$ROOT/ComfyUI"
PORT="${PORT:-8188}"

# Optional: speed up HF downloads if the wheel is present
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"

# Hugging Face auth (if you set HF_TOKEN in RunPod env/secrets)
HF_AUTH=()
if [ -n "${HF_TOKEN:-}" ]; then
  HF_AUTH=(-H "Authorization: Bearer ${HF_TOKEN}")
fi

log(){ echo "==> $*"; }

# --- sanity: GPU attached? (RunPod stop→start sometimes loses it) ---
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
  echo "❌ GPU not found (nvidia-smi failed). Terminate and redeploy on a GPU instance."
  exit 1
fi

# --- layout ---
log "Preparing folders at $ROOT ..."
mkdir -p "$ROOT"
cd "$ROOT"

# --- ComfyUI (clone or update) ---
log "Ensuring ComfyUI..."
if [ ! -d "$COMFY" ]; then
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
else
  if git -C "$COMFY" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$COMFY" pull --ff-only || true
  else
    rm -rf "$COMFY"
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
  fi
fi

# --- stop ComfyUI-Manager prestartup from erroring on 'uv' ---
if ! python3 -m uv --version >/dev/null 2>&1; then
  log "Installing 'uv' once (for ComfyUI-Manager)..."
  pip install -q uv || true
fi

# --- holding page (so proxy isn’t 502 while we prep) ---
log "Starting holding page on :$PORT"
cat > "$ROOT/hold.html" <<HTML
<!doctype html><meta charset="utf-8"><title>ComfyUI – preparing…</title>
<style>body{font:16px system-ui;margin:3rem}</style>
<h1>ComfyUI is preparing…</h1>
<p>Models are downloading to the pod. This page will switch to ComfyUI automatically when ready.</p>
HTML

python3 - <<'PY' &
import http.server, socketserver, os
PORT=int(os.getenv("PORT","8188")); ROOT=os.getenv("ROOT","/workspace/qwen")
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.end_headers()
        with open(os.path.join(ROOT,"hold.html"),"rb") as f: self.wfile.write(f.read())
socketserver.ThreadingTCPServer.allow_reuse_address=True
with socketserver.ThreadingTCPServer(("0.0.0.0", PORT), H) as httpd: httpd.serve_forever()
PY
HOLD_PID=$!
log "Holding page PID: $HOLD_PID"

# --- model dirs ---
mkdir -p \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/vae" \
  "$COMFY/models/loras"

# --- resumable download helper (no --retry-all-errors; the curl in some bases lacks it) ---
fetch () {
  local url="$1" out="$2"
  if [ -s "$out" ]; then
    log "✓ exists: $(basename "$out")"
  else
    log "↓ downloading: $(basename "$out")"
    curl -fL -C - "${HF_AUTH[@]}" -H "Accept: application/octet-stream" -o "$out.part" "$url"
    mv "$out.part" "$out"
  fi
  ls -lh "$out"
}

# --- Qwen + Lightning (required) ---
log "Fetching Qwen-Image-Edit weights..."
fetch "https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_fp8_e4m3fn.safetensors" \
      "$COMFY/models/diffusion_models/qwen_image_edit_fp8_e4m3fn.safetensors"
fetch "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors" \
      "$COMFY/models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
fetch "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors" \
      "$COMFY/models/vae/qwen_image_vae.safetensors"
fetch "https://huggingface.co/lightx2v/Qwen-Image-Lightning/resolve/main/Qwen-Image-Lightning-4steps-V1.0.safetensors" \
      "$COMFY/models/loras/Qwen-Image-Lightning-4steps-V1.0.safetensors"

# --- launch ComfyUI ---
log "Launching ComfyUI on 0.0.0.0:${PORT}"
cd "$COMFY"
# (Optional) write a tiny hint file
cat > "$ROOT/README_QWEN.txt" <<'TXT'
Qwen Image Edit installed.
Templates → Image → Qwen Image Edit (set Steps=4 for Lightning).
TXT

# start app
python3 main.py --listen 0.0.0.0 --port "$PORT" &
APP_PID=$!

# readiness probe (switch off holding page once UI is up)
for i in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
    log "READY: https://${RUNPOD_POD_ID:-pod}-${PORT}.proxy.runpod.net"
    break
  fi
  sleep 2
done

kill "$HOLD_PID" 2>/dev/null || true
wait "$APP_PID"
