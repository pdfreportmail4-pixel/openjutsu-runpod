#!/usr/bin/env bash
# Starts the services: SSH -> model download (background) -> ComfyUI -> comfy-api-proxy -> OpenJutsu.
# Everything listens on 127.0.0.1; reach it through an SSH tunnel (windows\baglan.bat).
set -uo pipefail

LOG=/opt/logs
mkdir -p "$LOG"
log() { echo "[$(date +%H:%M:%S)] $*"; }
wait_http() { # url timeout_seconds
  local i
  for ((i = 0; i < $2; i += 3)); do
    curl -s -o /dev/null -m 3 "$1" && return 0
    sleep 3
  done
  return 1
}

# 1) SSH and model download (both are no-ops if bootstrap.sh already started them)
/opt/scripts/ssh_setup.sh
/opt/scripts/models_bg.sh

# 2) ComfyUI. Default memory management on purpose: --highvram / --disable-dynamic-vram
#    turn off weight streaming and cause OOM on 32 GB cards. Extra flags: COMFY_ARGS env var.
cd /opt/ComfyUI
AIOHTTP_NOSENDFILE=1 nohup /opt/venv/bin/python main.py --listen 127.0.0.1 --port 8188 ${COMFY_ARGS:-} \
  > "$LOG/comfyui.log" 2>&1 &
if wait_http http://127.0.0.1:8188/system_stats 900; then
  log "ComfyUI is up on 127.0.0.1:8188"
else
  log "ERROR: ComfyUI did not start, see $LOG/comfyui.log"; tail -n 40 "$LOG/comfyui.log"
fi

# 3) comfy-api-proxy (Comfy API v2 on 127.0.0.1:8189), upload cap raised like the OpenJutsu README says
nohup /opt/proxy-venv/bin/comfy-api-proxy run --max-upload-mb 500 > "$LOG/proxy.log" 2>&1 &
wait_http http://127.0.0.1:8189/api/v2/health 120 && log "proxy is up on 127.0.0.1:8189" \
  || log "WARNING: proxy health check failed, see $LOG/proxy.log"

# 4) OpenJutsu (next start --hostname 127.0.0.1, port 3000)
cd /opt/openjutsu
nohup npm start > "$LOG/app.log" 2>&1 &
wait_http http://127.0.0.1:3000/ 180 && log "OpenJutsu is up on 127.0.0.1:3000" \
  || log "ERROR: OpenJutsu did not start, see $LOG/app.log"

# 5) Wait for the models, then report
if [[ -f "$LOG/models.started" ]]; then
  while [[ ! -f "$LOG/models.done" ]]; do sleep 5; done
  if [[ "$(cat "$LOG/models.done")" == "0" ]]; then log "models ready"
  else log "WARNING: some models are missing, see $LOG/models.log"; fi
fi
log "OPENJUTSU READY  (versions: $(tr '\n' ' ' < /opt/versions.txt))"

# Keep the pod alive; the services run in the background
exec tail -f /dev/null
