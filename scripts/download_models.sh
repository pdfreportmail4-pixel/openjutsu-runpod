#!/usr/bin/env bash
# Downloads OpenJutsu's model files into ComfyUI/models on the container disk.
# Files that are already there are skipped. Set HF_TOKEN for gated repos / higher rate limits.
set -uo pipefail

M="${MODELS_DIR:-/opt/ComfyUI/models}"
STAGE="${STAGE_DIR:-/opt/hf-stage}"
export HF_XET_HIGH_PERFORMANCE="${HF_XET_HIGH_PERFORMANCE:-1}"
mkdir -p "$STAGE"
rm -f "$STAGE/failed.txt"

# fetch <folder under models> <file name> <repo> [fallback repo ...]
# The file may sit in any subfolder of the repo; it is found by name and moved into place.
fetch() {
  local sub=$1 file=$2; shift 2
  local dest="$M/$sub/$file"
  if [[ -s "$dest" ]]; then echo "[models] already there: $sub/$file"; return 0; fi
  mkdir -p "$M/$sub"
  local repo tmp found
  for repo in "$@"; do
    tmp="$STAGE/${repo//\//_}__$file"
    # one glob: "*" also matches "/", so this finds the file at the repo root or in any subfolder
    if hf download "$repo" --include "*$file" --local-dir "$tmp" >/dev/null 2>"$tmp.log"; then
      found=$(find "$tmp" -type f -name "$file" -not -path '*/.cache/*' | head -n 1)
      if [[ -n "$found" ]]; then
        mv "$found" "$dest" && rm -rf "$tmp" "$tmp.log"
        echo "[models] ok: $sub/$file ($(du -h "$dest" | cut -f1), from $repo)"
        return 0
      fi
    fi
    echo "[models] $file not found in $repo (log: $tmp.log)"
    rm -rf "$tmp"
  done
  echo "$sub/$file" >> "$STAGE/failed.txt"
  return 1
}

start=$(date +%s)
echo "[models] downloading to $M ..."

fetch diffusion_models minimax_h3_ref2va_pruned_int8_convrot.safetensors Comfy-Org/MiniMax-H3 &
fetch text_encoders qwen3vl_32b_minimax_h3_int4_convrot.safetensors Merserk/MiniMax-H3-INT4-ConvRot Abiray/Minimax-H3-nvfp4-INT4-INT8-Convrot &
fetch text_encoders qwen3vl_8b_int8_convrot.safetensors Comfy-Org/Qwen3-VL &
fetch vae minimax_h3_video_vae_int8_convrot.safetensors Comfy-Org/MiniMax-H3 Kijai/MiniMax-H3-experimental &
fetch vae minimax_h3_audio_vae_fp32.safetensors Comfy-Org/MiniMax-H3 &
fetch loras minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors Kijai/MiniMax-H3-experimental &
fetch checkpoints sam3.1_multiplex_fp16.safetensors Comfy-Org/sam3.1 &

# Fix faces (small files). Set FIX_FACES_MODELS=0 in the template to skip.
if [[ "${FIX_FACES_MODELS:-1}" == "1" ]]; then
  fetch ultralytics/bbox face_yolov8m.pt Bingsu/adetailer &
  fetch ultralytics/segm person_yolov8m-seg.pt Bingsu/adetailer &
  (
    mkdir -p "$M/sams"
    if [[ ! -s "$M/sams/sam_vit_b_01ec64.pth" ]]; then
      curl -fsSL -o "$M/sams/sam_vit_b_01ec64.pth" \
        https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth \
        && echo "[models] ok: sams/sam_vit_b_01ec64.pth" \
        || { echo "sams/sam_vit_b_01ec64.pth" >> "$STAGE/failed.txt"; echo "[models] FAILED: sam_vit_b"; }
    fi
  ) &
fi

wait
echo "[models] finished in $(( $(date +%s) - start )) s; disk:"
df -h /opt | tail -n 1
if [[ -s "$STAGE/failed.txt" ]]; then
  echo "[models] MISSING:"; sed 's/^/  - /' "$STAGE/failed.txt"
  exit 1
fi
echo "[models] all files present"
