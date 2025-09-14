#!/usr/bin/env bash
set -euo pipefail

# ========= Settings (override via env) =========
ROOT="${ROOT:-/workspace}"
COMFY="$ROOT/ComfyUI"
PORT="${PORT:-8188}"

# Official ComfyUI S2V workflow JSON
WORKFLOW_URL="${WORKFLOW_URL:-https://raw.githubusercontent.com/Comfy-Org/workflow_templates/main/templates/video_wan2_2_14B_s2v.json}"

# Diffusion weights precision: fp8 | bf16
WAN_VARIANT="${WAN_VARIANT:-fp8}"

# Hugging Face (optional, avoids throttling on big files)
HF_TOKEN="${HF_TOKEN:-}"

# Install ComfyUI-Manager real plugin? (0/1). If 1, we clone the node.
INSTALL_MANAGER="${INSTALL_MANAGER:-0}"

log(){ echo "==> $*"; }
auth_header(){ if [[ -n "$HF_TOKEN" ]]; then echo "Authorization: Bearer $HF_TOKEN"; fi; }

# resumable curl with auth header if provided
fetch () {
  local url="$1" out="$2"
  if [[ -s "$out" ]]; then log "exists: $(basename "$out")"; ls -lh "$out"; return 0; fi
  log "downloading: $(basename "$out")"
  # shellcheck disable=SC2046
  curl -fL -C - -o "$out" -H "Accept: application/octet-stream" $( [[ -n "$HF_TOKEN" ]] && echo -H "$(auth_header)" ) "$url"
  ls -lh "$out"
}

fetch_mirror () {
  local out="$1"; shift
  for u in "$@"; do
    if fetch "$u" "$out"; then return 0; fi
    log "mirror failed: $u"
  done
  log "ERROR: all mirrors failed for $(basename "$out")"; return 9
}

ensure_min_size () {
  # ensure_min_size <path> <min_bytes>
  local f="$1" min="$2"
  if [[ ! -f "$f" ]]; then log "ERROR: missing $f"; return 9; fi
  local sz; sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
  if [[ "$sz" -lt "$min" ]]; then
    log "ERROR: $(basename "$f") too small ($sz bytes), expected >= $min; removing and failing."
    rm -f "$f"
    return 9
  fi
  return 0
}

py(){ command -v python3 >/dev/null 2>&1 && echo python3 || echo /opt/conda/bin/python3; }

# ========= Step 0: prepare & quick GPU check =========
log "Step 0: prepare dirs and GPU check"
mkdir -p "$ROOT"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: GPU driver not visible. Exiting."; exit 2
fi

"$(py)" - <<'PY'
import torch, sys
sys.exit(0 if torch.cuda.is_available() else 3)
PY

# Temporary holding page so :8188 isn’t blank while models pull
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
trap 'kill "$HOLD_PID" >/dev/null 2>&1 || true' EXIT

# ========= Step 1: ensure ComfyUI =========
log "Step 1: ensure ComfyUI (nightly)"
if [[ -d "$COMFY/.git" ]]; then
  git -C "$COMFY" pull || true
else
  rm -rf "$COMFY"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY"
fi

log "Step 1c: install ComfyUI Python deps (frontend + DB)"
"$(py)" -m pip install -U pip wheel setuptools
"$(py)" -m pip install -U -r "$COMFY/requirements.txt"
"$(py)" -m pip install -U 'comfyui_frontend_package>=1.25.11' alembic pydantic-settings

# Optional: real ComfyUI-Manager (only if requested)
if [[ "$INSTALL_MANAGER" = "1" ]]; then
  if [[ ! -d "$COMFY/custom_nodes/ComfyUI-Manager/.git" ]]; then
    log "Installing ComfyUI-Manager node"
    git clone --depth 1 https://github.com/ltdrdata/ComfyUI-Manager "$COMFY/custom_nodes/ComfyUI-Manager"
  else
    git -C "$COMFY/custom_nodes/ComfyUI-Manager" pull || true
  fi
fi

# ========= Step 1b: place workflows (safe paths only) =========
log "Step 1b: install S2V workflow(s)"
WF_TMP="$COMFY/Wan2.2_S2V.json"
curl -fsSL "$WORKFLOW_URL" -o "$WF_TMP"
# visible in sidebar
install -Dm644 "$WF_TMP" "$COMFY/web/assets/workflows/Wan/Wan2.2_14B_S2V_Audio_Image_to_Video.json"
install -Dm644 "$WF_TMP" "$COMFY/user/default/workflows/Wan2.2_14B_S2V_Audio_Image_to_Video.json"
# NOTE: do NOT create a fake 'custom_nodes/ComfyUI-Manager' dir just to stash workflows;
# it makes ComfyUI try to import a non-existent node and slows startup.

# ========= Step 2: models =========
log "Step 2: prepare model folders"
mkdir -p \
  "$COMFY/models/diffusion_models" \
  "$COMFY/models/text_encoders" \
  "$COMFY/models/vae" \
  "$COMFY/models/audio_encoders" \
  "$COMFY/models/loras"

export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-1}"

# ---- diffusion model (fp8 or bf16) ----
case "$WAN_VARIANT" in
  fp8)  WAN_DIFF_NAME="wan2.2_s2v_14B_fp8_scaled.safetensors" ;;
  bf16) WAN_DIFF_NAME="wan2.2_s2v_14B_bf16.safetensors" ;;
  *)    echo "Invalid WAN_VARIANT=$WAN_VARIANT (use fp8|bf16)"; exit 10 ;;
esac
WAN_DIFF_PATH="$COMFY/models/diffusion_models/$WAN_DIFF_NAME"
fetch_mirror "$WAN_DIFF_PATH" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/$WAN_DIFF_NAME"
# expect ~15 GB (fp8) — sanity: >= 10 GB
ensure_min_size "$WAN_DIFF_PATH" $((10*1024*1024*1024))

# ---- text encoder (UMT5 fp8) ----
TXT_NAME="umt5_xxl_fp8_e4m3fn_scaled.safetensors"
TXT_PATH="$COMFY/models/text_encoders/$TXT_NAME"
fetch_mirror "$TXT_PATH" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/text_encoders/$TXT_NAME" \
  "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/$TXT_NAME"
# expect multiple GB — sanity: >= 5 GB
ensure_min_size "$TXT_PATH" $((5*1024*1024*1024))

# ---- VAE ----
VAE_NAME="wan_2.1_vae.safetensors"
VAE_PATH="$COMFY/models/vae/$VAE_NAME"
fetch_mirror "$VAE_PATH" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/$VAE_NAME"
ensure_min_size "$VAE_PATH" $((100*1024*1024))

# ---- Audio encoder (Wav2Vec2 EN fp16) ----
AENC_NAME="wav2vec2_large_english_fp16.safetensors"
AENC_PATH="$COMFY/models/audio_encoders/$AENC_NAME"
fetch_mirror "$AENC_PATH" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/audio_encoders/$AENC_NAME"
# ~600 MB — sanity: >= 400 MB
ensure_min_size "$AENC_PATH" $((400*1024*1024))

# ---- Lightning LoRAs (both variants) ----
LORA_HI="wan2.2_t2v_lightx2v_4steps_lora_v1.1_high_noise.safetensors"
LORA_LO="wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors"
fetch_mirror "$COMFY/models/loras/$LORA_HI" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/$LORA_HI"
fetch_mirror "$COMFY/models/loras/$LORA_LO" \
  "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/$LORA_LO"
ensure_min_size "$COMFY/models/loras/$LORA_HI" $((10*1024*1024))
ensure_min_size "$COMFY/models/loras/$LORA_LO" $((10*1024*1024))

log "Models present:"
ls -lh "$COMFY/models/diffusion_models" || true
ls -lh "$COMFY/models/audio_encoders" || true
ls -lh "$COMFY/models/text_encoders" || true
ls -lh "$COMFY/models/vae" || true
ls -lh "$COMFY/models/loras" || true

# ========= Step 3: launch ComfyUI =========
log "Step 3: launch ComfyUI"
if ! command -v ffmpeg >/dev/null 2>&1; then
  log "WARN: ffmpeg not found; video writer nodes may fail."
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
