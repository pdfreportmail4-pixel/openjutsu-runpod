#!/usr/bin/env bash
# Starts the model download in the background and returns at once. Safe to call more than once:
# skips if a previous run finished OK or is still running; retries (missing files only) otherwise.
# Progress goes to /opt/logs/models.log and the RunPod Logs tab; the exit code lands in models.done.
LOG=/opt/logs
mkdir -p "$LOG"
[[ "${SKIP_MODELS:-0}" == "1" ]] && exit 0
if [[ -f "$LOG/models.done" && "$(cat "$LOG/models.done")" == "0" ]]; then exit 0; fi
# still running? (a finished-but-unreaped process shows up as a zombie, state Z)
if [[ -f "$LOG/models.pid" ]] && ps -o stat= -p "$(cat "$LOG/models.pid")" 2>/dev/null | grep -qv Z; then exit 0; fi

rm -f "$LOG/models.done"
touch "$LOG/models.started"
# Mirror progress to the container log (PID 1's stdout) when it is writable
OUT=/proc/1/fd/1
[[ -w "$OUT" ]] || OUT=/dev/null
export OUT
nohup bash -c '
  /opt/scripts/download_models.sh 2>&1 | tee /opt/logs/models.log > "$OUT"
  echo "${PIPESTATUS[0]}" > /opt/logs/models.done
' >/dev/null 2>&1 &
echo $! > "$LOG/models.pid"
