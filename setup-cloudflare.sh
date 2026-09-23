#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

readonly SCRIPT_VERSION="0.1.0"
readonly TOKEN_FILE="/etc/cloudflared/tunnel.token"
readonly UNIT_FILE="/etc/systemd/system/cloudflared.service"
readonly LOG_FILE="/var/log/cloudflared-setup.log"
readonly ORIGIN_URL="http://127.0.0.1:3001"
readonly READY_URL="http://127.0.0.1:20241/ready"

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  ORANGE=$'\033[38;5;214m'; RESET=$'\033[0m'
else
  BOLD= DIM= RED= GREEN= ORANGE= RESET=
fi

die() {
  printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*" >&2
  [[ -e "$LOG_FILE" ]] && printf 'Details: %s\n' "$LOG_FILE" >&2
  exit 1
}

usage() {
  cat <<'EOF_HELP'
Usage: sudo ./setup-cloudflare.sh

Interactively install cloudflared and connect this OpenChamber VPS to a
remotely-managed Cloudflare Tunnel.

Options:
  -h, --help       Show this help and exit
      --version    Show helper version
EOF_HELP
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
  '') ;;
  *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

[[ $EUID -eq 0 ]] || die 'Run this helper as root.'
[[ -t 0 && -t 1 ]] || die 'This helper is interactive and must be run in a terminal.'
[[ -d /run/systemd/system ]] || die 'A running systemd installation is required.'

exec 8>/run/cloudflared-setup.lock
flock -n 8 || die 'Another Cloudflare setup is running.'
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

run_step() {
  local label=$1 pid status dots=''
  shift
  "$@" >>"$LOG_FILE" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    dots="${dots}."
    [[ ${#dots} -le 3 ]] || dots='.'
    printf '\r  %-36s %s%-3s%s' "$label" "$ORANGE" "$dots" "$RESET"
    sleep 0.35
  done
  wait "$pid" && status=0 || status=$?
  printf '\r\033[K'
  if (( status == 0 )); then
    printf '  %-36s %sdone%s\n' "$label" "$GREEN" "$RESET"
  else
    printf '  %-36s %sfailed%s\n' "$label" "$RED" "$RESET"
    printf '  Details: %s\n' "$LOG_FILE" >&2
  fi
  return "$status"
}

atomic_secret_write() {
  local destination=$1 temporary
  [[ ! -L "$destination" ]] || die "Refusing symlink: $destination"
  temporary=$(mktemp "${destination}.XXXXXX")
  cat >"$temporary"
  chown root:root "$temporary"
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$destination"
}

install_cloudflared() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ca-certificates curl gnupg
  install -d -m 755 /usr/share/keyrings
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 2 \
    https://pkg.cloudflare.com/cloudflare-main.gpg \
    -o /usr/share/keyrings/cloudflare-main.gpg
  chmod 644 /usr/share/keyrings/cloudflare-main.gpg
  printf '%s\n' \
    'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
    > /etc/apt/sources.list.d/cloudflared.list
  chmod 644 /etc/apt/sources.list.d/cloudflared.list
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends cloudflared
}

store_token() {
  local token answer
  install -d -o root -g root -m 700 /etc/cloudflared
  [[ ! -L "$TOKEN_FILE" ]] || die "Refusing symlink: $TOKEN_FILE"
  if [[ -e "$TOKEN_FILE" ]]; then
    [[ -f "$TOKEN_FILE" ]] || die "Token path is not a regular file: $TOKEN_FILE"
    chown root:root "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
  fi
  if [[ -s "$TOKEN_FILE" ]]; then
    if systemctl is-active --quiet cloudflared.service; then
      printf '%sActive tunnel token found; keeping it.%s\n' \
        "$DIM" "$RESET" >/dev/tty
      return
    fi
    printf '%sThe existing token is not connected. Replace it? [Y/n]: %s' \
      "$ORANGE" "$RESET" >/dev/tty
    read -r answer </dev/tty || return 1
    if [[ -n "$answer" && ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      printf '%sKeeping the existing tunnel token.%s\n' \
        "$DIM" "$RESET" >/dev/tty
      return
    fi
  fi
  printf '\n%sPaste the Cloudflare tunnel token%s (input hidden): ' "$ORANGE" "$RESET" >/dev/tty
  read -r -s token </dev/tty
  printf '\n' >/dev/tty
  [[ -n "$token" && ${#token} -ge 20 ]] || die 'Tunnel token is missing or looks too short.'
  [[ "$token" != *[[:space:]]* && "$token" != cloudflared* && "$token" != sudo* ]] \
    || die 'Paste only the token, not the full install command.'
  printf '%s\n' "$token" | atomic_secret_write "$TOKEN_FILE"
  unset token
}

write_service() {
  local temporary
  if ! id cloudflared >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/cloudflared --create-home \
      --shell /usr/sbin/nologin cloudflared
  fi
  [[ $(id -u cloudflared) != 0 ]] || die 'cloudflared account must not be root.'
  install -d -o cloudflared -g cloudflared -m 700 /var/lib/cloudflared

  [[ ! -L "$UNIT_FILE" ]] || die "Refusing symlink: $UNIT_FILE"
  temporary=$(mktemp "${UNIT_FILE}.XXXXXX")
  cat >"$temporary" <<'EOF_UNIT'
[Unit]
Description=Cloudflare Tunnel Connector for OpenChamber
After=network-online.target openchamber.service
Wants=network-online.target

[Service]
Type=simple
User=cloudflared
Group=cloudflared
LoadCredential=tunnel-token:/etc/cloudflared/tunnel.token
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:20241 run --token-file %d/tunnel-token
Restart=always
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
TasksMax=512
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF_UNIT
  chown root:root "$temporary"
  chmod 644 "$temporary"
  mv -f -- "$temporary" "$UNIT_FILE"
  systemctl daemon-reload
}

start_tunnel() {
  local attempt
  systemctl enable cloudflared.service >/dev/null
  systemctl restart cloudflared.service
  for attempt in $(seq 1 30); do
    if systemctl is-active --quiet cloudflared.service \
      && curl --fail --silent --max-time 2 "$READY_URL" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  die 'Tunnel did not become ready. Check: journalctl -u cloudflared --no-pager -n 100'
}

printf '\n%s%sCloudflare Tunnel setup%s\n' "$BOLD" "$ORANGE" "$RESET"
printf '%s=======================%s\n' "$ORANGE" "$RESET"
printf 'Before continuing:\n'
printf '  1. In Cloudflare, open Networking > Tunnels.\n'
printf '  2. Create/select a remotely-managed tunnel using cloudflared.\n'
printf '  3. Copy only its connector token.\n\n'
printf 'After this script connects, add a Published application route to:\n'
printf '  %s%s%s\n\n' "$ORANGE" "$ORIGIN_URL" "$RESET"

run_step '[1/4] Install cloudflared' install_cloudflared
printf '  %-36s\n' '[2/4] Store tunnel token'
store_token || die 'Tunnel token was not stored.'
printf '  %-36s %sdone%s\n' '[2/4] Store tunnel token' "$GREEN" "$RESET"
run_step '[3/4] System service' write_service
run_step '[4/4] Connect tunnel' start_tunnel

printf '\n%s%sCloudflare Tunnel connected%s\n' "$BOLD" "$GREEN" "$RESET"
printf 'Finish in Cloudflare:\n'
printf '  1. Add the desired hostname as a Published application route.\n'
printf '  2. Set its service URL to %s%s%s.\n' "$ORANGE" "$ORIGIN_URL" "$RESET"
printf '  3. Put a Cloudflare Access self-hosted application in front of that hostname.\n'
printf '\n%sNo inbound OpenChamber port needs to be opened on the VPS.%s\n' "$DIM" "$RESET"
printf '%scloudflared is apt-managed; update it with normal Ubuntu package updates.%s\n' "$DIM" "$RESET"
