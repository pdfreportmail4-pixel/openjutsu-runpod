#!/usr/bin/env bash
# Starts sshd. Keys come from $PUBLIC_KEY (RunPod) or $SSH_PUBLIC_KEY (set it in the template as a fallback);
# RunPod may also write /root/.ssh/authorized_keys itself. Safe to call more than once.
mkdir -p /root/.ssh /run/sshd && chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys

for keys in "${PUBLIC_KEY:-}" "${SSH_PUBLIC_KEY:-}"; do
  [[ -n "$keys" ]] || continue
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    grep -qxF "$line" /root/.ssh/authorized_keys || echo "$line" >> /root/.ssh/authorized_keys
  done <<< "$keys"
done

if ! pgrep -x sshd >/dev/null 2>&1; then
  ssh-keygen -A >/dev/null 2>&1
  /usr/sbin/sshd && echo "[ssh] sshd started"
fi

n=$(grep -c . /root/.ssh/authorized_keys || true)
if [[ "$n" -eq 0 ]]; then
  echo "[ssh] WARNING: no SSH key found. Add SSH_PUBLIC_KEY (contents of id_ed25519.pub) to the template's environment variables."
else
  echo "[ssh] $n key(s) authorized"
fi
