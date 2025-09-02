# Wan 2.2 S2V (Audio + Image → Video) — ComfyUI on RunPod

This template pulls ComfyUI nightlies, downloads the four required S2V files, optionally fetches the Lightning LoRA, and installs the official S2V workflow JSON into the left sidebar and user workflows.

## Start (RunPod command)
```bash
bash -lc 'set -euo pipefail
ROOT=/workspace
mkdir -p "$ROOT"
cd "$ROOT"
curl -fsSL https://raw.githubusercontent.com/ArpitKhurana-ai/comfyui-lnodes/main/templates/wan2.2-s2v/startup-wan2.2-s2v.sh -o startup-wan2.2-s2v.sh
chmod +x startup-wan2.2-s2v.sh
ROOT="$ROOT" PORT=8188 WAN_VARIANT=fp8 WAN_DOWNLOAD_LIGHTNING=0 ./startup-wan2.2-s2v.sh
'
