#!/bin/bash
# kraken entrypoint. Runs as root once per container start:
#   1. make sure the volume-backed home dir is owned by the user
#   2. start tailscaled (userspace networking) + Tailscale SSH
#   3. park forever so Railway keeps the container alive
set -euo pipefail

USER_NAME="${KRAKEN_USER:-nfp}"
HOME_DIR="/home/${USER_NAME}"

# --- 1. ownership: Railway mounts the volume as root ---------------------------
if [ "$(stat -c %U "$HOME_DIR")" != "$USER_NAME" ]; then
  echo "[kraken] fixing ownership of $HOME_DIR"
  chown "$USER_NAME:$USER_NAME" "$HOME_DIR"
fi

# --- 2. tailscale --------------------------------------------------------------
# State on the volume so kraken keeps the same tailnet identity across redeploys.
TS_STATE_DIR="$HOME_DIR/.tailscale"
mkdir -p "$TS_STATE_DIR"

# --statedir (not --state): tailscaled also needs a writable dir for SSH host keys,
# otherwise Tailscale SSH silently reports itself disabled.
tailscaled \
  --tun=userspace-networking \
  --statedir="$TS_STATE_DIR" \
  --socket=/var/run/tailscale/tailscaled.sock \
  > /var/log/tailscaled.log 2>&1 &

# wait for the daemon socket
for _ in $(seq 1 30); do
  [ -S /var/run/tailscale/tailscaled.sock ] && break
  sleep 0.5
done

if [ -n "${TS_AUTHKEY:-}" ]; then
  tailscale up \
    --ssh \
    --hostname="${TS_HOSTNAME:-kraken}" \
    --authkey="$TS_AUTHKEY" \
    --accept-dns=false \
    || echo "[kraken] tailscale up failed (check TS_AUTHKEY); continuing without it"
else
  echo "[kraken] TS_AUTHKEY not set; tailscale idle. Railway SSH still works."
fi

# --- herdr server ----------------------------------------------------------------
# Herdr installs its server binary into the user's home (on the volume); it dies with
# every redeploy and only `herdr machine add` restarts it, so do it here on boot.
if [ -x "$HOME_DIR/.local/bin/herdr" ]; then
  rm -f "$HOME_DIR/.config/herdr/"*.sock
  su - "$USER_NAME" -c 'setsid nohup "$HOME/.local/bin/herdr" server >"$HOME/.config/herdr/server-stdout.log" 2>&1 </dev/null &'
  echo "[kraken] herdr server started as $USER_NAME"
fi

echo "[kraken] ready. user=$USER_NAME home=$HOME_DIR"

# --- 3. park -------------------------------------------------------------------
# Forward SIGTERM so Railway redeploys shut down cleanly.
trap 'echo "[kraken] shutting down"; tailscale down 2>/dev/null || true; exit 0' TERM INT
sleep infinity &
wait $!
