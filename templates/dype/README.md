# DyPE (FLUX FP16) – ComfyUI Template

Minimal, public-safe DyPE setup that piggybacks on your existing `comfyui-lnodes` repo structure.

## Base image (recommended)
Use a Docker image compatible with RunPod pools offering CUDA ≥ 12.4:
- `pytorch/pytorch:2.4.0-cuda12.4-cudnn9-runtime`  ← tested & stable on A40 48GB

## RunPod Template settings
- **Type:** Pod  
- **GPU:** A40 (48 GB)  
- **HTTP Port:** 8188  
- **Volume Mount:** `/workspace`  
- **Environment Variables:**  
  - `HF_TOKEN=hf_xxx` *(required for gated models)*

**Start Command (single line):**
```bash
/bin/bash -lc 'cd /workspace && \
  if [ ! -d comfyui-lnodes ]; then git clone https://github.com/ArpitKhurana-ai/comfyui-lnodes.git; fi && \
  bash comfyui-lnodes/templates/dype/startup-dype.sh 2>&1 | tee -a /workspace/boot-dype.log'
