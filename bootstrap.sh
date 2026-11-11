#!/usr/bin/env bash
# "Everything on RunPod" mode: installs the whole stack at pod start on a plain ubuntu:24.04 image,
# downloads the models in parallel, then runs start.sh. No Docker build needed.
# Safe to re-run after a container restart: finished steps are reused.
# RunPod template > Container Start Command:
#   bash -c "apt-get update -qq && apt-get install -y -qq git ca-certificates >/dev/null && rm -rf /opt/oj && git clone --depth 1 https://github.com/KULLANICI/openjutsu-runpod /opt/oj && bash /opt/oj/bootstrap.sh"
set -Eeuo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
COMFYUI_REF="${COMFYUI_REF:-v0.45.1}"
OPENJUTSU_REF="${OPENJUTSU_REF:-7fe118bb5a61fcfac0148e1bfea3dd29884dbf26}"
TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu130}"
export DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
       NEXT_TELEMETRY_DISABLED=1 SAM2_BUILD_CUDA=0 COMFYUI_PATH=/opt/ComfyUI
log() { echo "[$(date +%H:%M:%S)] [setup] $*"; }
# On any error: report it and keep the container alive (no restart loop; SSH stays usable for debugging)
fail() { log "ERROR: $*"; log "Setup stopped. The pod stays up so you can read the logs; fix and redeploy."; exec sleep infinity; }
trap 'fail "command failed at bootstrap.sh line $LINENO"' ERR
T0=$(date +%s)

mkdir -p /opt/scripts /opt/logs
cp "$SRC"/scripts/*.sh "$SRC"/scripts/*.py /opt/scripts/
sed -i 's/\r$//' /opt/scripts/*.sh && chmod +x /opt/scripts/*.sh

if [[ -f /opt/.installed ]]; then
  log "already installed, starting services"
  exec /opt/scripts/start.sh
fi

log "1/5 system packages + Node.js 22 + ComfyUI ${COMFYUI_REF}"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  python3 python3-venv python3-dev build-essential git curl ca-certificates procps \
  ffmpeg libgl1 libglib2.0-0 openssh-server rsync >/dev/null
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends nodejs >/dev/null
/opt/scripts/ssh_setup.sh
# ComfyUI first, so the model download below writes into an existing checkout
if [[ ! -d /opt/ComfyUI/.git ]]; then
  rm -rf /opt/ComfyUI.src
  git clone --filter=blob:none --quiet https://github.com/Comfy-Org/ComfyUI.git /opt/ComfyUI.src
  mkdir -p /opt/ComfyUI && cp -a /opt/ComfyUI.src/. /opt/ComfyUI/ && rm -rf /opt/ComfyUI.src
fi
git -C /opt/ComfyUI checkout --quiet "$COMFYUI_REF"

log "2/5 model download starts in the background"
python3 -m venv /opt/hf-venv
/opt/hf-venv/bin/pip install -q huggingface_hub
PATH="/opt/hf-venv/bin:$PATH" /opt/scripts/models_bg.sh

log "3/5 PyTorch (CUDA 13.0) + ComfyUI requirements"
python3 -m venv /opt/venv
export PATH="/opt/venv/bin:$PATH"
pip install -q --upgrade pip setuptools wheel
pip install -q torch torchvision --index-url "$TORCH_INDEX"
pip install -q torchaudio
python -c "import torch; v = torch.version.cuda or ''; assert v.startswith('13'), f'torch is not a CUDA 13 build: {v}'; print('torch', torch.__version__, 'CUDA', v)"
pip freeze | grep -iE '^(torch|torchvision|torchaudio)==' > /opt/constraints.txt
pip install -q -c /opt/constraints.txt -r /opt/ComfyUI/requirements.txt

log "4/5 custom nodes"
if ! SKIP_IMPORT_TEST=1 bash /opt/scripts/install_nodes.sh > /opt/logs/nodes_install.log 2>&1; then
  tail -n 40 /opt/logs/nodes_install.log; fail "custom node install failed (see above)"
fi

log "5/5 comfy-api-proxy + OpenJutsu"
[[ -d /opt/openjutsu/.git ]] || { rm -rf /opt/openjutsu; git clone --filter=blob:none --quiet https://github.com/D3voz/openjutsu.git /opt/openjutsu; }
git -C /opt/openjutsu checkout --quiet "$OPENJUTSU_REF"
python3 -m venv /opt/proxy-venv
/opt/proxy-venv/bin/pip install -q comfy-api-proxy==0.1.6
/opt/proxy-venv/bin/python /opt/openjutsu/patch_proxy.py
python /opt/scripts/patch_openjutsu.py
if git -C /opt/ComfyUI/custom_nodes/SolarRenderer apply /opt/openjutsu/patches/solarrenderer-long-clips.patch 2>/dev/null; then
  log "SolarRenderer long-clip patch applied"
else
  log "SolarRenderer patch skipped (already applied or not needed)"
fi
cd /opt/openjutsu
cp .env.example .env.local
if ! { npm ci --silent && npm run build > /opt/logs/next_build.log 2>&1; }; then
  tail -n 40 /opt/logs/next_build.log; fail "OpenJutsu build failed (see above)"
fi

printf 'ComfyUI %s\nOpenJutsu %s\n' "$COMFYUI_REF" "$OPENJUTSU_REF" > /opt/versions.txt
cat /opt/constraints.txt >> /opt/versions.txt
touch /opt/.installed
trap - ERR
log "install finished in $(( $(date +%s) - T0 )) s, starting services"
exec /opt/scripts/start.sh
