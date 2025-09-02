#!/usr/bin/env bash
set -euo pipefail

# ========= Settings (override via env) =========
ROOT="${ROOT:-/workspace}"
COMFY="$ROOT/ComfyUI"
PORT="${PORT:-8188}"

# Official ComfyUI S2V JSON (override to pin your own copy if you wish)
WORKFLOW_URL="${WORKFLOW_URL:-https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_wan2_2_14B_s2v.json}"

# Model precision variant for diffusion weights
WAN_VARIANT="${WAN_VARIANT:-fp8}"     # fp8 | bf16

# Optional: HF token for faster/ratelimit-proof downloads
HF_TOKEN="${HF_TOKEN:-}"

# ========= Helpers =========
log(){ echo "==> $*"; }
auth_header(){ if [[ -n "$HF_TOKEN" ]]; then echo "Authorization: Bearer $HF_TOKEN"; fi; }

# resumable curl (works on older curl too)
fetch () {
  local url="$1" out="$2"
  if [[ -s "$out" ]]; then log "exists: $(basename "$out")"; ls -lh "$out"; return 0; fi
  log "downloading: $(basename "$out")"
  # shellcheck disable=SC2046
  curl -fL -C - -o "$out" -H "Accept: application/octet-stream" $( [[ -n "$HF_TOKEN" ]] && echo -H "$(auth_header)" ) "$url"
  ls -lh "$out"
}

# Try mirrors until one succeeds
fetch_mirror () {
  local out="$1"; shift
  for u in "$@"; do
    if fetch "$u" "$out"; then return 0; fi
    log "mirror failed: $u"
  done
  log "ERROR: all mirrors failed for $(basename "$out")"; return 9
}

py(){ command -v python3 >/dev/null 2>&1 && echo python3 || echo /opt/conda/bin/python3; }

# ========= Step 0: prepare & sanity checks =========
log "Step 0: prepare dirs and GPU check"
mkdir -p "$ROOT"

# GPU must be visible
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: GPU driver not visible. Exiting."; exit 2
fi

"$(py)" - <<'PY'
import torch, sys
sys.exit(0 if torch.cuda.is_available() else 3)
PY

# Holding page so :8188 isn’t 404 while models pull
cat > "$ROOT/hold.html" <<HTML
<!doctype html><meta charset="utf-8"><title>ComfyUI — preparing…</title>
<style>body{font:16px system-ui;margin:3rem;color:#111}</style>
<h1>ComfyUI is preparing…</h1>
<p>Wan 2.2 S2V weights are downloading. This will switch automatically.</p>
HTML

"$(py)" - <<'PY' &
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

# ========= Step 1: ensure ComfyUI (nightly) =========
log "Step 1: ensure ComfyUI (nightly)"
if [[ -d "$COMFY/.git" ]]; then
  git -C "$COMFY" pull || true
else
  rm -rf "$COMFY"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
fi

# ========= Step 1c: install ComfyUI Python deps (frontend + DB) =========
log "Step 1c: install ComfyUI Python deps (frontend + DB)"
"$(py)" -m pip install -U pip wheel setuptools
"$(py)" -m pip install -U -r "$COMFY/requirements.txt"
# New split-frontend + Alembic DB requirements
"$(py)" -m pip install -U 'comfyui_frontend_package>=1.25.11' alembic pydantic-settings

# ========= Step 1b: install workflow(s) into sidebars =========
log "Step 1b: install S2V workflow(s)"
WF_TMP="$COMFY/Wan2.2_S2V.json"
curl -fsSL "$WORKFLOW_URL" -o "$WF_TMP"

# Use a filename without special unicode chars to avoid FS issues
install -Dm644 "$WF_TMP" "$COMFY/web/assets/workflows/Wan/Wan2.2_14B_S2V_Audio_Image_to_Video.json"
install -Dm644 "$WF_TMP" "$COMFY/user/default/workflows/Wan2.2_14B_S2V_Audio_Image_to_Video.json"
install -Dm644 "$WF_TMP" "$COMFY/custom_nodes/ComfyUI-Manager/workflows/Wan/Wan2.2_14B_S2V_Audio_Image_to_Video.json" || true

# ========= Step 2: models =========
log "Step 2: prepare model folders"
mkdir -p \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/vae" \
  "$COMFY/models/audio_encoders" \
  "$COMFY/models/loras"

export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"

# ---- diffusion model (pick one by env) ----
case "$WAN_VARIANT" in
  fp8)  WAN_DIFF_NAME="wan2.2_s2v_14B_fp8_scaled.safetensors" ;;
  bf16) WAN_DIFF_NAME="wan2.2_s2v_14B_bf16.safetensors" ;;
  *)    echo "Invalid WAN_VARIANT=$WAN_VARIANT (use fp8|bf16)"; exit 10 ;;
esac

fetch_mirror "$COMFY/models/diffusion_models/$WAN_DIFF_NAME" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/$WAN_DIFF_NAME"

# ---- text encoder (UMT5) ----
fetch_mirror "$COMFY/models/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
  "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

# ---- VAE ----
fetch_mirror "$COMFY/models/vae/wan_2.1_vae.safetensors" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"

# ---- Audio encoder ----
fetch_mirror "$COMFY/models/audio_encoders/wav2vec2_large_english_fp16.safetensors" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/audio_encoders/wav2vec2_large_english_fp16.safetensors"

# ---- Lightning LoRAs — ALWAYS install (both variants) ----
fetch_mirror "$COMFY/models/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"

fetch_mirror "$COMFY/models/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"

# ========= Step 3: launch =========
log "Step 3: launch ComfyUI"
if ! command -v ffmpeg >/dev/null 2>&1; then
  log "WARN: ffmpeg not found; video writer may fail. (Install ffmpeg in your image.)"
fi

kill "$HOLD_PID" || true
cd "$COMFY"
"$(py)" "$COMFY/main.py" --listen 0.0.0.0 --port "$PORT" &
APP_PID=$!

# Readiness probe → print proxy URL
for i in $(seq 1 200); do
  if curl -fsS "http://127.0.0.1:${PORT}" >/dev/null 2>&1; then
    [[ -n "${RUNPOD_POD_ID:-}" ]] && echo "READY: https://${RUNPOD_POD_ID}-${PORT}.proxy.runpod.net"
    break
  fi
  sleep 2
done

wait "$APP_PID"
