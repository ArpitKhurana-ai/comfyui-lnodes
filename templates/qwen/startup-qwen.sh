#!/usr/bin/env bash
set -euo pipefail

# --- settings (can be overridden via env) ---
ROOT="${ROOT:-/workspace}"
COMFY="$ROOT/ComfyUI"
PORT="${PORT:-8188}"
WORKFLOW_URL="${WORKFLOW_URL:-https://raw.githubusercontent.com/ArpitKhurana-ai/comfyui-lnodes/main/templates/qwen/workflows/qwen_image_edit.json}"

log(){ echo "==> $*"; }

log "Step 0: prepare"
mkdir -p "$ROOT"

# Fast fail if GPU missing
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: GPU driver not visible. Exiting."; exit 2
fi
python3 - <<'PY'
import torch, sys
sys.exit(0 if torch.cuda.is_available() else 3)
PY

# Tiny holding page so 8188 isn’t 404 while models pull
cat > "$ROOT/hold.html" <<HTML
<!doctype html><meta charset="utf-8"><title>ComfyUI — preparing…</title>
<style>body{font:16px system-ui;margin:3rem;color:#111}</style>
<h1>ComfyUI is preparing…</h1><p>Qwen weights are downloading. This will switch automatically.</p>
HTML
python3 - <<'PY' &
import http.server, socketserver, os
PORT=int(os.environ.get("PORT","8188")); ROOT=os.environ["ROOT"]
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type","text/html; charset=utf-8"); self.end_headers()
        with open(os.path.join(ROOT,"hold.html"),"rb") as f: self.wfile.write(f.read())
socketserver.ThreadingTCPServer.allow_reuse_address=True
with socketserver.ThreadingTCPServer(("0.0.0.0", PORT), H) as httpd: httpd.serve_forever()
PY
HOLD_PID=$!

# --- ComfyUI (clone or pull) ---
log "Step 1: ensure ComfyUI"
if [ -d "$COMFY/.git" ]; then
  git -C "$COMFY" pull || true
else
  rm -rf "$COMFY"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
fi

# --- Put workflow where the LEFT SIDEBAR looks (permanent for template users) ---
log "Step 1b: install Qwen workflow for sidebar"
WF_TMP="$COMFY/Qwen_Image_Edit.json"
curl -fsSL "$WORKFLOW_URL" -o "$WF_TMP"

# Built-in gallery (left sidebar)
install -Dm644 "$WF_TMP" "$COMFY/web/assets/workflows/Qwen/Qwen Image Edit.json"
# User workflows (also shown in sidebar)
install -Dm644 "$WF_TMP" "$COMFY/user/default/workflows/Qwen Image Edit.json"
# Manager gallery (nice to have)
install -Dm644 "$WF_TMP" "$COMFY/custom_nodes/ComfyUI-Manager/workflows/Qwen/Qwen Image Edit.json" || true

# --- Model folders ---
mkdir -p \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/vae" \
  "$COMFY/models/loras"

# Resumable fetch helper (works on older curl)
fetch () {
  local url="$1" out="$2"
  if [ -s "$out" ]; then log "exists: $(basename "$out")"; ls -lh "$out"; return 0; fi
  log "downloading: $(basename "$out")"
  curl -H "Accept: application/octet-stream" -fL -C - -o "$out" "$url"
  ls -lh "$out"
}

# --- Qwen Image Edit + Lightning (only the four required files) ---
log "Step 2: download Qwen + Lightning"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"
fetch "https://huggingface.co/Comfy-Org/Qwen-Image-Edit_ComfyUI/resolve/main/split_files/diffusion_models/qwen_image_edit_fp8_e4m3fn.safetensors" \
      "$COMFY/models/diffusion_models/qwen_image_edit_fp8_e4m3fn.safetensors"
fetch "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors" \
      "$COMFY/models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors"
fetch "https://huggingface.co/Comfy-Org/Qwen-Image_ComfyUI/resolve/main/split_files/vae/qwen_image_vae.safetensors" \
      "$COMFY/models/vae/qwen_image_vae.safetensors"
fetch "https://huggingface.co/lightx2v/Qwen-Image-Lightning/resolve/main/Qwen-Image-Lightning-4steps-V1.0.safetensors" \
      "$COMFY/models/loras/Qwen-Image-Lightning-4steps-V1.0.safetensors"

# --- Launch ComfyUI ---
log "Step 3: launch ComfyUI"
kill "$HOLD_PID" || true
cd "$COMFY"
python3 main.py --listen 0.0.0.0 --port "$PORT" &
APP_PID=$!

# Readiness probe so the proxy flips from 404→200
for i in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
    echo "READY: https://${RUNPOD_POD_ID}-${PORT}.proxy.runpod.net"; break
  fi
  sleep 2
done
wait "$APP_PID"
