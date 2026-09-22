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

# --- export Railway variables to user shells ---------------------------------------
# sshd and Tailscale SSH strip the daemon environment, so shells never see Railway
# variables (OPENROUTER_API_KEY etc.). Write them to a private file that .bashrc sources.
ENV_FILE="$HOME_DIR/.config/kraken/env.sh"
mkdir -p "$(dirname "$ENV_FILE")"
{
  echo "# generated at boot by entrypoint.sh — do not edit; set variables in Railway"
  env -0 | while IFS= read -r -d "" kv; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      RAILWAY_*|TS_AUTHKEY|TS_DEBUG_*|KRAKEN_AUTHORIZED_KEYS|HOME|PATH|PWD|SHLVL|_|OLDPWD|HOSTNAME|TERM|LANG|DEBIAN_FRONTEND) continue ;;
    esac
    printf 'export %s=%q\n' "$k" "$v"
  done
} > "$ENV_FILE"
chown "$USER_NAME:$USER_NAME" "$ENV_FILE"; chmod 600 "$ENV_FILE"
echo "[kraken] $(grep -c '^export' "$ENV_FILE") variables exported to $ENV_FILE"

# --- OpenSSH on 127.0.0.1:2222, reachable only via the tailnet --------------------
# Tailscale SSH (port 22) stays on; this is the path Herdr uses. Authorized keys come
# from KRAKEN_AUTHORIZED_KEYS (Railway variable, newline-separated public keys).
if [ -n "${KRAKEN_AUTHORIZED_KEYS:-}" ]; then
  SSHD_DIR="$HOME_DIR/.ssh-host"
  mkdir -p "$SSHD_DIR" "$HOME_DIR/.ssh" /run/sshd
  [ -f "$SSHD_DIR/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N "" -f "$SSHD_DIR/ssh_host_ed25519_key"
  printf '%s\n' "$KRAKEN_AUTHORIZED_KEYS" > "$HOME_DIR/.ssh/authorized_keys"
  cat > "$SSHD_DIR/sshd_config" <<SSHDCFG
Port 2222
ListenAddress 127.0.0.1
HostKey $SSHD_DIR/ssh_host_ed25519_key
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers $USER_NAME
ClientAliveInterval 30
ClientAliveCountMax 3
UsePAM no
Subsystem sftp /usr/lib/openssh/sftp-server
SSHDCFG
  chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh" "$SSHD_DIR"
  chmod 700 "$HOME_DIR/.ssh"; chmod 600 "$HOME_DIR/.ssh/authorized_keys" "$SSHD_DIR/ssh_host_ed25519_key"
  /usr/sbin/sshd -f "$SSHD_DIR/sshd_config" && echo "[kraken] sshd listening on 127.0.0.1:2222"
  tailscale serve --bg --tcp 2222 tcp://127.0.0.1:2222 >/dev/null 2>&1 \
    && echo "[kraken] tailnet :2222 -> sshd" \
    || echo "[kraken] tailscale serve failed (is tailscale up?)"
else
  echo "[kraken] KRAKEN_AUTHORIZED_KEYS not set; sshd not started (Tailscale SSH on :22 still works)"
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
