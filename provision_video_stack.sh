#!/usr/bin/env bash
# provision_video_stack.sh
#
# Adds extra video stacks on top of the OpenJutsu RunPod bootstrap:
#   - H3 extras (INT8 text encoder, fp16 video VAE, timm fix)
#   - Viggle-Animate (H3 finetune for character replacement)
#   - Wan Animate 2 (motion + facial expression transfer)
#   - SeedVR2 video upscaler
#   - optional: OpenJutsu "From picture" files (FLUX 3 Klein + SolarRenderer)
#
# Nothing is stored between pods: everything is fetched at start.
# Safe to re-run: files and node packs that already exist are skipped.
#
# Settings (RunPod template -> Environment Variables):
#   STACKS         comma list of stacks to install     (default h3plus,viggle,wan,upscale)
#                  h3plus       H3 INT8 text encoder + fp16 VAE          ~32 GB
#                  h3full       unpruned H3 Ref2VA INT8                  ~34 GB
#                  viggle       Viggle-Animate pruned INT8 + r64 LoRA    ~22 GB
#                  viggle_full  Viggle-Animate unpruned INT8 + full LoRA ~51 GB
#                  wan          Wan Animate 2 INT8 + encoders            ~26 GB (estimate)
#                  wan_full     Wan Animate 2 bf16                       ~30 GB (estimate)
#                  upscale      SeedVR2 nodes (models download on first use)
#                  picture      FLUX 3 Klein + SolarRenderer for "From picture" ~25 GB
#   HF_TOKEN       Hugging Face token, only needed for gated repos (picture stack)
#   PARALLEL       simultaneous downloads              (default 3)
#
# Usually left alone:
#   MODE           all | nodes | models   (bootstrap.sh calls 'models' in the background and 'nodes' inline)
#   COMFY_DIR      ComfyUI folder                      (default /opt/ComfyUI)
#   COMFY_PYTHON   Python that runs ComfyUI            (default: auto, /opt/venv/bin/python on this template)
#   DL_PYTHON      Python used for downloads           (default: /opt/hf-venv/bin/python when present)
#   RESTART_COMFY  1 = restart a running ComfyUI at the end so new nodes load (manual runs only)

set -uo pipefail

COMFY_DIR="${COMFY_DIR:-/opt/ComfyUI}"
STACKS="${STACKS:-h3plus,viggle,wan,upscale}"
MODE="${MODE:-all}"
PARALLEL="${PARALLEL:-3}"
WAIT_SECS="${WAIT_SECS:-900}"
LOG="${PROVISION_LOG:-/tmp/provision.log}"

log() { echo "[$(date +%H:%M:%S)] [extra:$MODE] $*" | tee -a "$LOG"; }
has() { case ",${STACKS// /}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
do_nodes() { [ "$MODE" = all ] || [ "$MODE" = nodes ]; }
do_models() { [ "$MODE" = all ] || [ "$MODE" = models ]; }

case "$MODE" in
  all | nodes | models) ;;
  *) echo "MODE must be all, nodes or models (got: $MODE)"; exit 2 ;;
esac

# Keep torch exactly as the bootstrap installed it.
if [ -f /opt/constraints.txt ]; then export PIP_CONSTRAINT=/opt/constraints.txt; fi

# ---------------------------------------------------------------- wait for ComfyUI
log "stacks: $STACKS"
waited=0
until [ -f "$COMFY_DIR/main.py" ]; do
  if [ "$waited" -eq 0 ]; then log "waiting for $COMFY_DIR/main.py"; fi
  sleep 5
  waited=$((waited + 5))
  if [ "$waited" -ge "$WAIT_SECS" ]; then
    log "ERROR: $COMFY_DIR/main.py not found after ${WAIT_SECS}s. Set COMFY_DIR to the right folder."
    exit 1
  fi
done

# The ComfyUI process itself: a python process running main.py (not a shell wrapper that mentions it).
comfy_pid() {
  local p exe
  for p in $(pgrep -f "main.py" || true); do
    exe="$(tr '\0' '\n' < "/proc/$p/cmdline" 2> /dev/null | head -n 1)"
    case "$(basename "${exe:-x}")" in
      python*) echo "$p"; return ;;
    esac
  done
}

find_python() {
  if [ -n "${COMFY_PYTHON:-}" ]; then echo "$COMFY_PYTHON"; return; fi
  local pid py c
  pid="$(comfy_pid)"
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    py="$(tr '\0' '\n' < "/proc/$pid/cmdline" | head -n 1)"
    if command -v "$py" > /dev/null 2>&1; then echo "$py"; return; fi
  fi
  for c in /opt/venv/bin/python "$COMFY_DIR/venv/bin/python" "$COMFY_DIR/.venv/bin/python" /venv/bin/python; do
    if [ -x "$c" ]; then echo "$c"; return; fi
  done
  command -v python3 || command -v python
}

pip_install() { # pip_install <python> <pip args...>
  local py="$1"
  shift
  "$py" -m pip install --quiet "$@" >> "$LOG" 2>&1 \
    || "$py" -m pip install --quiet --break-system-packages "$@" >> "$LOG" 2>&1 \
    || log "WARN: pip install failed: $* (see $LOG)"
}

# ================================================================ NODES
NEW_NODES=0
if do_nodes; then
  PY="$(find_python)"
  log "ComfyUI python: $PY"
  pip_install "$PY" timm   # needed by the Metric3D node (OpenJutsu 'From picture')

  if ! command -v git > /dev/null 2>&1; then
    log "git not found, installing"
    (apt-get update -qq && apt-get install -y -qq git) >> "$LOG" 2>&1 || log "WARN: could not install git"
  fi

  clone_node() { # clone_node <git url> [yes = install its requirements.txt when newly cloned]
    local url="$1" name dir
    name="$(basename "$url" .git)"
    dir="$COMFY_DIR/custom_nodes/$name"
    if [ -d "$dir" ]; then
      log "node already present: $name"
      return
    fi
    log "cloning node: $name"
    if ! git clone --depth 1 "$url" "$dir" >> "$LOG" 2>&1; then
      log "WARN: clone failed: $url"
      return
    fi
    NEW_NODES=1
    if [ "${2:-no}" = "yes" ] && [ -f "$dir/requirements.txt" ]; then
      pip_install "$PY" -r "$dir/requirements.txt"
    fi
  }

  copy_workflows() { # example workflows -> ComfyUI's Workflows sidebar
    local src="$COMFY_DIR/custom_nodes/$1/example_workflows"
    local dst="$COMFY_DIR/user/default/workflows"
    if [ -d "$src" ]; then
      mkdir -p "$dst"
      cp -n "$src"/*.json "$dst"/ 2> /dev/null && log "example workflows copied from $1"
    fi
  }

  if has viggle || has viggle_full; then
    clone_node https://github.com/Saganaki22/ComfyUI-Viggle-Animate-H3
    clone_node https://github.com/kijai/ComfyUI-KJNodes yes
    copy_workflows ComfyUI-Viggle-Animate-H3
  fi
  if has upscale; then
    clone_node https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler yes
    copy_workflows ComfyUI-SeedVR2_VideoUpscaler
  fi
fi

# ================================================================ MODELS
RUN_OUT="$(mktemp)"
if do_models; then
  # one job per line: <repo or repo1|repo2 fallbacks> <file name> <folder under models/>
  JOBS=""
  add() { JOBS+="$1 $2 $3"$'\n'; }

  if has h3plus; then
    add Comfy-Org/MiniMax-H3 qwen3vl_32b_minimax_h3_int8_convrot.safetensors text_encoders
    add Comfy-Org/MiniMax-H3 minimax_h3_video_vae_fp16.safetensors vae
  fi
  if has h3full; then
    add Comfy-Org/MiniMax-H3 minimax_h3_ref2va_int8_convrot.safetensors diffusion_models
  fi
  if has viggle || has viggle_full; then
    add drbaph/Viggle-Animate-ComfyUI fixed_embed_fwd_anyframe.safetensors text_cond
    add Comfy-Org/MiniMax-H3 minimax_h3_video_vae_fp16.safetensors vae
    add Comfy-Org/MiniMax-H3 minimax_h3_audio_vae_fp32.safetensors vae
  fi
  if has viggle; then
    add drbaph/Viggle-Animate-ComfyUI minimax_h3_ref2va_viggle_pruned_int8_convrot.safetensors diffusion_models
    add drbaph/Viggle-Animate-ComfyUI viggle_animate_dmd_lora_r64.safetensors loras
  fi
  if has viggle_full; then
    add drbaph/Viggle-Animate-ComfyUI minimax_h3_ref2va_viggle_int8_convrot.safetensors diffusion_models
    add drbaph/Viggle-Animate-ComfyUI viggle_animate_dmd_lora.safetensors loras
  fi
  if has wan || has wan_full; then
    add Comfy-Org/Wan-Animate-2 lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors loras
    add Comfy-Org/Wan-Animate-2 umt5_xxl_fp8_e4m3fn_scaled.safetensors text_encoders
    add Comfy-Org/Wan-Animate-2 clip_vision_h.safetensors clip_vision
    add Comfy-Org/Wan-Animate-2 Wan2_1_VAE_bf16.safetensors vae
  fi
  if has wan; then
    add Comfy-Org/Wan-Animate-2 wan_animate_2_int8_convrot.safetensors diffusion_models
  fi
  if has wan_full; then
    add Comfy-Org/Wan-Animate-2 wan_animate_2_bf16.safetensors diffusion_models
  fi
  if has picture; then
    add DeepBeepMeep/Flux3 flux3_image_klein_sd_int8_convrot.safetensors diffusion_models
    add Comfy-Org/Krea-2 qwen3vl_4b_fp8_scaled.safetensors text_encoders
    add "Comfy-Org/flux2-dev|black-forest-labs/flux-3-image-klein-comfy" flux2-vae.safetensors vae
    add black-forest-labs/flux-3-image-klein-comfy qwen3.5_9b_flux3_prompt_upsampler_int8_convrot.safetensors text_encoders
    add Enderfga/SolarRenderer solarrenderer_4step_lora.safetensors loras
    add Enderfga/SolarRenderer solarrenderer_control_lora.safetensors loras
  fi

  JOBS="$(printf '%s' "$JOBS" | awk 'NF && !seen[$0]++')"

  # only one download run at a time
  exec 9> /tmp/provision_models.lock
  if ! flock -n 9; then
    log "another download run is active; skipping downloads in this run."
    JOBS=""
  fi

  if [ -n "$JOBS" ]; then
    DL_PY="${DL_PYTHON:-}"
    if [ -z "$DL_PY" ]; then
      if [ -x /opt/hf-venv/bin/python ]; then DL_PY=/opt/hf-venv/bin/python; else DL_PY="$(find_python)"; fi
    fi
    "$DL_PY" -c "import huggingface_hub" 2> /dev/null || pip_install "$DL_PY" huggingface_hub
    log "download python: $DL_PY"

    # leftovers from an interrupted run
    find "$COMFY_DIR/models" -maxdepth 2 -type d -name '.dl_*' -exec rm -rf {} + 2> /dev/null

    log "disk before downloads: $(df -h "$COMFY_DIR" | awk 'NR==2 {print $4 " free of " $2}')"
    log "downloading $(printf '%s\n' "$JOBS" | wc -l) files, $PARALLEL at a time"
    export DL_JOBS="$JOBS"
    "$DL_PY" - "$COMFY_DIR/models" "$PARALLEL" << 'PYEOF' 2>&1 | tee -a "$LOG" "$RUN_OUT"
import concurrent.futures as cf
import os
import shutil
import sys
import tempfile
import threading

from huggingface_hub import HfApi, hf_hub_download

models_dir, parallel = sys.argv[1], int(sys.argv[2])
jobs = [line.split() for line in os.environ.get("DL_JOBS", "").splitlines() if line.strip()]
api = HfApi()
listing, lock = {}, threading.Lock()


def repo_files(repo):
    with lock:
        if repo not in listing:
            listing[repo] = api.list_repo_files(repo)
        return listing[repo]


def fetch(job):
    repos, name, sub = job
    dest_dir = os.path.join(models_dir, sub)
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, name)
    if os.path.exists(dest) and os.path.getsize(dest) > 1024 * 1024:
        return f"skip    {sub}/{name} (already there)"
    errors = []
    for repo in repos.split("|"):
        tmp = None
        try:
            match = [f for f in repo_files(repo) if f.split("/")[-1] == name]
            if not match:
                errors.append(f"{repo}: file not in repo")
                continue
            tmp = tempfile.mkdtemp(dir=dest_dir, prefix=".dl_")
            path = hf_hub_download(repo, match[0], local_dir=tmp)
            shutil.move(path, dest)
            return f"ok      {sub}/{name} ({os.path.getsize(dest) / 2**30:.1f} GiB)"
        except Exception as exc:  # report and try the next repo
            errors.append(f"{repo}: {type(exc).__name__}")
        finally:
            if tmp:
                shutil.rmtree(tmp, ignore_errors=True)
    return f"FAILED  {sub}/{name} <- " + "; ".join(errors)


with cf.ThreadPoolExecutor(parallel) as pool:
    for result in pool.map(fetch, jobs):
        print("[download]", result, flush=True)
PYEOF
    log "disk after downloads: $(df -h "$COMFY_DIR" | awk 'NR==2 {print $4 " free of " $2}')"
  fi
fi

# ================================================================ ComfyUI restart (manual runs)
if do_nodes; then
  pid="$(comfy_pid)"
  if [ -z "$pid" ]; then
    log "ComfyUI is not running yet; new nodes load when it starts."
  elif [ "$NEW_NODES" != "1" ]; then
    log "no new node packs; ComfyUI restart not needed."
  elif [ "${RESTART_COMFY:-0}" != "1" ]; then
    log "ComfyUI is running (pid $pid). New node packs load only after a restart: re-run with RESTART_COMFY=1 or restart it yourself."
  else
    mapfile -d '' -t COMFY_ARGS < "/proc/$pid/cmdline"
    cwd="$(readlink "/proc/$pid/cwd")"
    log "restarting ComfyUI: ${COMFY_ARGS[*]}"
    kill "$pid"
    for _ in $(seq 1 30); do kill -0 "$pid" 2> /dev/null || break; sleep 1; done
    sleep 5
    if [ -n "$(comfy_pid)" ]; then
      log "ComfyUI was restarted by the pod's own supervisor."
    else
      (cd "$cwd" && nohup "${COMFY_ARGS[@]}" >> /tmp/comfyui.log 2>&1 &)
      log "ComfyUI relaunched; follow it with: tail -f /tmp/comfyui.log"
    fi
  fi
fi

if grep -q "^\[download\] FAILED" "$RUN_OUT" 2> /dev/null; then
  log "finished with failed downloads (listed above). Gated repos need HF_TOKEN."
else
  log "finished."
fi
rm -f "$RUN_OUT"
