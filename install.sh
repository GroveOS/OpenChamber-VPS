#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
readonly VERSIONS_FILE="$SCRIPT_DIR/versions.env"
readonly RUNTIME_USER="opencode"
readonly HOME_DIR="/home/opencode"
readonly OPENCODE_ROOT="/opt/opencode"
readonly OPENCHAMBER_ROOT="/opt/openchamber"
readonly OPENCODE_CURRENT="$OPENCODE_ROOT/current"
readonly OPENCHAMBER_CURRENT="$OPENCHAMBER_ROOT/current"
readonly OPENCODE_BIN="$OPENCODE_CURRENT/opencode"
readonly OPENCHAMBER_BIN="$OPENCHAMBER_CURRENT/bin/openchamber"
readonly OPENCODE_ENV="/etc/opencode/server.env"
readonly OPENCHAMBER_ENV="/etc/openchamber/openchamber.env"
readonly DEPLOYMENT_STATE="/etc/openchamber/deployment.env"
readonly SUMMARY_FILE="/root/openchamber-install.txt"
readonly LOG_FILE="/var/log/openchamber-install.log"
readonly OPENCODE_PORT="4096"
readonly OPENCHAMBER_PORT="3001"

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
  CYAN=$'\033[36m'; ORANGE=$'\033[38;5;214m'; RESET=$'\033[0m'
else
  BOLD= DIM= RED= GREEN= CYAN= ORANGE= RESET=
fi

die() {
  printf '%s[FAIL]%s %s\n' "$RED" "$RESET" "$*" >&2
  [[ -e "$LOG_FILE" ]] && printf 'Details: %s\n' "$LOG_FILE" >&2
  exit 1
}

usage() {
  cat <<EOF_HELP
Usage: sudo ./install.sh

Install OpenChamber + OpenCode on a dedicated Ubuntu VPS.
The installer is interactive; there is no unattended mode.

Options:
  -h, --help       Show this help and exit
      --version    Show installer and pinned application versions

What it does:
  - installs the tested versions in versions.env
  - runs OpenCode and OpenChamber as the unprivileged 'opencode' user
  - keeps both services on localhost only
  - generates service passwords
  - offers Cloudflare Tunnel setup or SSH port forwarding at the end

Future upgrades:
  sudo ./upgrade.sh

Run ./install.sh --version to see the currently pinned application versions.

The upgrade script checks this Git repository for a newer tested version pair,
shows the proposed change, and asks before installing it.
EOF_HELP
}

load_versions() {
  [[ -r "$VERSIONS_FILE" ]] || die "Missing $VERSIONS_FILE"
  DEPLOYMENT_VERSION="$(awk -F= '$1=="DEPLOYMENT_VERSION" {print $2; exit}' "$VERSIONS_FILE")"
  OPENCODE_VERSION="$(awk -F= '$1=="OPENCODE_VERSION" {print $2; exit}' "$VERSIONS_FILE")"
  OPENCHAMBER_VERSION="$(awk -F= '$1=="OPENCHAMBER_VERSION" {print $2; exit}' "$VERSIONS_FILE")"
  NODE_MAJOR="$(awk -F= '$1=="NODE_MAJOR" {print $2; exit}' "$VERSIONS_FILE")"
  [[ "$DEPLOYMENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] \
    || die 'Invalid DEPLOYMENT_VERSION in versions.env'
  [[ "$OPENCODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] \
    || die 'Invalid OPENCODE_VERSION in versions.env'
  [[ "$OPENCHAMBER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] \
    || die 'Invalid OPENCHAMBER_VERSION in versions.env'
  [[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || die 'Invalid NODE_MAJOR in versions.env'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --version)
    load_versions
    printf 'Deployment %s\nInstaller %s\nOpenCode %s\nOpenChamber %s\nNode.js %s.x\n' \
      "$DEPLOYMENT_VERSION" "$SCRIPT_VERSION" "$OPENCODE_VERSION" \
      "$OPENCHAMBER_VERSION" "$NODE_MAJOR"
    exit 0
    ;;
  '') ;;
  *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

load_versions

[[ $EUID -eq 0 ]] || die 'Run this installer as root: sudo ./install.sh'
[[ -t 0 && -t 1 ]] || die 'This installer is interactive and must be run in a terminal.'
[[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu ]] || die "Supported operating system: Ubuntu. Found: ${ID:-unknown}."
case "${VERSION_ID:-}" in
  24.04|26.04) ;;
  *) die "Supported Ubuntu releases: 24.04 and 26.04. Found: ${VERSION_ID:-unknown}." ;;
esac
case "$(dpkg --print-architecture)" in
  amd64|arm64) ;;
  *) die 'Supported architectures: amd64 and arm64.' ;;
esac
[[ -d /run/systemd/system ]] || die 'A running systemd installation is required.'

exec 9>/run/openchamber-install.lock
flock -n 9 || die 'Another OpenChamber install/upgrade is running.'

touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

ask() {
  local answer
  printf '%s [Y/n]: ' "$1" >/dev/tty
  read -r answer </dev/tty || return 1
  [[ -z "$answer" || "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

run_step() {
  local label=$1 pid status dots=''
  shift
  "$@" >>"$LOG_FILE" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    dots="${dots}."
    [[ ${#dots} -le 3 ]] || dots='.'
    printf '\r  %-36s %s%-3s%s' "$label" "$CYAN" "$dots" "$RESET"
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

atomic_write() {
  local destination=$1 mode=$2 temporary
  [[ ! -L "$destination" ]] || die "Refusing symlink: $destination"
  temporary=$(mktemp "${destination}.XXXXXX")
  cat >"$temporary"
  chown root:root "$temporary"
  chmod "$mode" "$temporary"
  mv -f -- "$temporary" "$destination"
}

atomic_symlink() {
  local target=$1 link=$2 temporary
  temporary="${link}.new.$$"
  rm -f -- "$temporary"
  ln -s -- "$target" "$temporary"
  mv -Tf -- "$temporary" "$link"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl git jq openssh-client openssl tar xz-utils \
    build-essential python3 rsync iproute2 gnupg
}

create_user() {
  if ! id "$RUNTIME_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$RUNTIME_USER"
    passwd -l "$RUNTIME_USER" >/dev/null
  fi

  [[ $(id -u "$RUNTIME_USER") != 0 ]] || die 'Runtime account must not be root.'
  [[ $(getent passwd "$RUNTIME_USER" | cut -d: -f6) == "$HOME_DIR" ]] \
    || die "The '$RUNTIME_USER' account has an unexpected home directory."
  [[ " $(id -nG "$RUNTIME_USER") " != *" sudo "* \
     && " $(id -nG "$RUNTIME_USER") " != *" docker "* ]] \
    || die "The '$RUNTIME_USER' account must not belong to sudo or docker."

  install -d -o "$RUNTIME_USER" -g "$RUNTIME_USER" -m 700 \
    "$HOME_DIR" "$HOME_DIR/repos" "$HOME_DIR/.ssh" "$HOME_DIR/.config" \
    "$HOME_DIR/.local" "$HOME_DIR/.cache"
  chmod 700 "$HOME_DIR"

  install -d -o root -g root -m 755 \
    "$OPENCODE_ROOT" "$OPENCODE_ROOT/releases" \
    "$OPENCHAMBER_ROOT" "$OPENCHAMBER_ROOT/releases"
}

install_node() {
  local current_major=0 setup_script
  if command -v node >/dev/null 2>&1; then
    current_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || printf '0')
  fi
  if (( current_major > NODE_MAJOR )); then
    die "Node.js $NODE_MAJOR.x is required. Found newer major: $(node --version)"
  fi
  if (( current_major < NODE_MAJOR )); then
    setup_script=$(mktemp /tmp/nodesource-setup.XXXXXX)
    curl --fail --silent --show-error --location \
      --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 2 \
      "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o "$setup_script"
    chmod 700 "$setup_script"
    bash "$setup_script"
    rm -f -- "$setup_script"
    apt-get install -y --no-install-recommends nodejs
  fi
  current_major=$(node -p 'process.versions.node.split(".")[0]')
  (( current_major == NODE_MAJOR )) \
    || die "Node.js $NODE_MAJOR.x is required. Found: $(node --version)"
}

opencode_target() {
  case "$(dpkg --print-architecture)" in
    amd64)
      if grep -qwi avx2 /proc/cpuinfo 2>/dev/null; then printf 'linux-x64'; else printf 'linux-x64-baseline'; fi
      ;;
    arm64) printf 'linux-arm64' ;;
  esac
}

install_opencode_release() {
  local release_dir="$OPENCODE_ROOT/releases/$OPENCODE_VERSION"
  local target archive url api digest expected actual tmpdir version

  if [[ -x "$release_dir/opencode" ]]; then
    version="$($release_dir/opencode --version 2>/dev/null | head -n1 | tr -d '[:space:]')"
    [[ "$version" == "$OPENCODE_VERSION" ]] && { atomic_symlink "$release_dir" "$OPENCODE_CURRENT"; return; }
    die "Existing OpenCode release directory is invalid: $release_dir"
  fi

  target="$(opencode_target)"
  archive="opencode-${target}.tar.gz"
  url="https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${archive}"
  api="https://api.github.com/repos/anomalyco/opencode/releases/tags/v${OPENCODE_VERSION}"
  tmpdir=$(mktemp -d /tmp/opencode-install.XXXXXX)

  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 2 \
    "$url" -o "$tmpdir/$archive"

  digest=$(curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 2 \
    -H 'Accept: application/vnd.github+json' "$api" \
    | jq -r --arg name "$archive" '.assets[] | select(.name == $name) | .digest // empty')
  [[ "$digest" =~ ^sha256:([0-9a-fA-F]{64})$ ]] \
    || die "GitHub did not provide a SHA-256 digest for $archive"
  expected="${BASH_REMATCH[1],,}"
  actual=$(sha256sum "$tmpdir/$archive" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || die 'OpenCode release checksum verification failed.'

  mapfile -t entries < <(tar -tzf "$tmpdir/$archive")
  [[ ${#entries[@]} -eq 1 && ${entries[0]} == opencode ]] \
    || die 'Unexpected contents in the OpenCode release archive.'
  tar -xzf "$tmpdir/$archive" -C "$tmpdir"

  install -d -o root -g root -m 755 "$release_dir"
  install -o root -g root -m 755 "$tmpdir/opencode" "$release_dir/opencode"
  version="$($release_dir/opencode --version 2>/dev/null | head -n1 | tr -d '[:space:]')"
  [[ "$version" == "$OPENCODE_VERSION" ]] \
    || die "OpenCode version verification failed. Found: ${version:-unknown}"
  rm -rf -- "$tmpdir"
  atomic_symlink "$release_dir" "$OPENCODE_CURRENT"
}

install_openchamber_release() {
  local release_dir="$OPENCHAMBER_ROOT/releases/$OPENCHAMBER_VERSION"
  local staging package_json version

  package_json="$release_dir/lib/node_modules/@openchamber/web/package.json"
  if [[ -r "$package_json" ]]; then
    version=$(node -p "require('$package_json').version" 2>/dev/null || true)
    [[ "$version" == "$OPENCHAMBER_VERSION" ]] \
      && { atomic_symlink "$release_dir" "$OPENCHAMBER_CURRENT"; return; }
    die "Existing OpenChamber release directory is invalid: $release_dir"
  fi

  staging=$(mktemp -d "$HOME_DIR/.cache/openchamber-install.XXXXXX")
  chown "$RUNTIME_USER:$RUNTIME_USER" "$staging"
  runuser -u "$RUNTIME_USER" -- env HOME="$HOME_DIR" \
    npm install --global --prefix "$staging" --omit=dev --no-audit --no-fund \
      "@openchamber/web@${OPENCHAMBER_VERSION}"

  package_json="$staging/lib/node_modules/@openchamber/web/package.json"
  [[ -r "$package_json" ]] || die 'OpenChamber package was not installed.'
  version=$(node -p "require('$package_json').version" 2>/dev/null || true)
  [[ "$version" == "$OPENCHAMBER_VERSION" ]] \
    || die "OpenChamber version verification failed. Found: ${version:-unknown}"
  [[ -x "$staging/bin/openchamber" ]] || die 'OpenChamber executable is missing.'

  chown -R root:root "$staging"
  chmod -R u=rwX,go=rX "$staging"
  mv -- "$staging" "$release_dir"
  atomic_symlink "$release_dir" "$OPENCHAMBER_CURRENT"
}

read_env_value() {
  local file=$1 key=$2
  [[ -r "$file" ]] || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

write_credentials() {
  local opencode_password chamber_password
  opencode_password="$(read_env_value "$OPENCODE_ENV" OPENCODE_SERVER_PASSWORD || true)"
  chamber_password="$(read_env_value "$OPENCHAMBER_ENV" OPENCHAMBER_UI_PASSWORD || true)"
  [[ -n "$opencode_password" ]] || opencode_password="$(openssl rand -hex 32)"
  [[ -n "$chamber_password" ]] || chamber_password="$(openssl rand -hex 32)"

  install -d -o root -g root -m 700 /etc/opencode /etc/openchamber
  printf 'OPENCODE_SERVER_USERNAME=opencode\nOPENCODE_SERVER_PASSWORD=%s\n' \
    "$opencode_password" | atomic_write "$OPENCODE_ENV" 600
  printf '%s\n' \
    'OPENCODE_HOST=http://127.0.0.1:4096' \
    'OPENCODE_PORT=4096' \
    'OPENCODE_SKIP_START=true' \
    "OPENCODE_BINARY=$OPENCODE_BIN" \
    'OPENCODE_SERVER_USERNAME=opencode' \
    "OPENCODE_SERVER_PASSWORD=$opencode_password" \
    "OPENCHAMBER_UI_PASSWORD=$chamber_password" \
    'OPENCHAMBER_HOST=127.0.0.1' \
    | atomic_write "$OPENCHAMBER_ENV" 600

  cat <<EOF_SUMMARY | atomic_write "$SUMMARY_FILE" 600
OpenChamber installation
========================
Deployment version: $DEPLOYMENT_VERSION
OpenCode version: $OPENCODE_VERSION
OpenChamber version: $OPENCHAMBER_VERSION
OpenCode URL: http://127.0.0.1:$OPENCODE_PORT
OpenChamber URL: http://127.0.0.1:$OPENCHAMBER_PORT
Runtime user: opencode
OpenCode service username: opencode
OpenCode service password: $opencode_password
OpenChamber UI password: $chamber_password

Keep this file root-readable. It contains service credentials.
EOF_SUMMARY
}

write_deployment_state() {
  printf '%s\n' \
    "DEPLOYMENT_VERSION=$DEPLOYMENT_VERSION" \
    "OPENCODE_VERSION=$OPENCODE_VERSION" \
    "OPENCHAMBER_VERSION=$OPENCHAMBER_VERSION" \
    "NODE_MAJOR=$NODE_MAJOR" \
    | atomic_write "$DEPLOYMENT_STATE" 600
}

write_units() {
  cat <<'EOF_UNIT' | atomic_write /etc/systemd/system/opencode.service 644
[Unit]
Description=OpenCode Agent Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=opencode
Group=opencode
WorkingDirectory=/home/opencode
Environment=HOME=/home/opencode
Environment=PATH=/opt/opencode/current:/home/opencode/.local/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=/etc/opencode/server.env
ExecStart=/opt/opencode/current/opencode serve --hostname 127.0.0.1 --port 4096
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/home/opencode
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
CapabilityBoundingSet=
TasksMax=4096
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF_UNIT

  cat <<'EOF_UNIT' | atomic_write /etc/systemd/system/openchamber.service 644
[Unit]
Description=OpenChamber Web Interface
After=network-online.target opencode.service
Wants=network-online.target
Requires=opencode.service

[Service]
Type=simple
User=opencode
Group=opencode
WorkingDirectory=/home/opencode
Environment=HOME=/home/opencode
Environment=PATH=/opt/opencode/current:/opt/openchamber/current/bin:/home/opencode/.local/bin:/usr/local/bin:/usr/bin:/bin
EnvironmentFile=/etc/openchamber/openchamber.env
ExecStart=/opt/openchamber/current/bin/openchamber serve --host 127.0.0.1 --port 3001 --foreground
Restart=always
RestartSec=5
TimeoutStopSec=30
UMask=0077
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/home/opencode
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
CapabilityBoundingSet=
TasksMax=2048
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF_UNIT

  systemctl daemon-reload
}

start_services() {
  local attempt password chamber_password response
  systemctl enable opencode.service openchamber.service >/dev/null
  systemctl restart opencode.service
  for attempt in $(seq 1 30); do
    systemctl is-active --quiet opencode.service \
      && ss -ltnH "sport = :$OPENCODE_PORT" | awk '{print $4}' \
        | grep -Eq "^127\\.0\\.0\\.1:$OPENCODE_PORT$" && break
    [[ $attempt -lt 30 ]] || die 'OpenCode did not start on 127.0.0.1:4096.'
    sleep 1
  done
  password="$(read_env_value "$OPENCODE_ENV" OPENCODE_SERVER_PASSWORD)"
  for attempt in $(seq 1 30); do
    if response=$(curl --fail --silent --show-error --max-time 3 \
      --user "opencode:$password" \
      "http://127.0.0.1:$OPENCODE_PORT/global/health") \
      && jq -e --arg version "$OPENCODE_VERSION" \
        '.healthy == true and .version == $version' \
        <<<"$response" >/dev/null; then
      break
    fi
    [[ $attempt -lt 30 ]] || die 'OpenCode did not become healthy.'
    sleep 1
  done

  systemctl restart openchamber.service
  for attempt in $(seq 1 30); do
    systemctl is-active --quiet openchamber.service \
      && ss -ltnH "sport = :$OPENCHAMBER_PORT" | awk '{print $4}' \
        | grep -Eq "^127\\.0\\.0\\.1:$OPENCHAMBER_PORT$" && break
    [[ $attempt -lt 30 ]] || die 'OpenChamber did not start on 127.0.0.1:3001.'
    sleep 1
  done
  for attempt in $(seq 1 30); do
    if response=$(curl --fail --silent --show-error --max-time 3 \
      "http://127.0.0.1:$OPENCHAMBER_PORT/health") \
      && jq -e --arg version "$OPENCHAMBER_VERSION" \
        '.status == "ok" and .openchamberVersion == $version
          and .openCodeRunning == true' <<<"$response" >/dev/null; then
      break
    fi
    [[ $attempt -lt 30 ]] || die 'OpenChamber did not become healthy.'
    sleep 1
  done

  chamber_password="$(read_env_value "$OPENCHAMBER_ENV" OPENCHAMBER_UI_PASSWORD)"
  for attempt in $(seq 1 30); do
    if response=$(jq -nc --arg password "$chamber_password" '{password: $password}' \
      | curl --fail --silent --show-error --max-time 3 \
        -H 'Content-Type: application/json' --data-binary @- \
        "http://127.0.0.1:$OPENCHAMBER_PORT/auth/session") \
      && jq -e '.authenticated == true' <<<"$response" >/dev/null; then
      break
    fi
    [[ $attempt -lt 30 ]] || die 'OpenChamber login verification failed.'
    sleep 1
  done
}

configure_access() {
  local helper="$SCRIPT_DIR/setup-cloudflare.sh"
  printf '\n%sBrowser access%s\n' "$BOLD" "$RESET"
  if ask 'Set up a Cloudflare Tunnel now?'; then
    [[ -f "$helper" && ! -L "$helper" ]] || die "Missing or unsafe helper: $helper"
    [[ -x "$helper" ]] || chmod 755 "$helper"
    bash "$helper"
    printf '\nOpenChamber remains bound to localhost; Cloudflare reaches it through the tunnel.\n'
  else
    printf '\nUse SSH forwarding from your own computer:\n\n'
    printf '  %sssh -N -L 3001:127.0.0.1:3001 root@SERVER_IP%s\n' "$BOLD" "$RESET"
    printf '\nThen open %shttp://localhost:3001%s.\n' "$BOLD" "$RESET"
  fi
}

if [[ -r "$DEPLOYMENT_STATE" ]]; then
  die 'OpenChamber already appears to be installed. Use: sudo ./upgrade.sh'
fi

printf '\n%s%sOpenChamber VPS installer%s\n' "$BOLD" "$CYAN" "$RESET"
printf '%s=========================%s\n' "$CYAN" "$RESET"
printf 'Dedicated Ubuntu VPS only. Services stay on localhost.\n\n'
printf '  %-20s %s\n' 'Deployment' "$DEPLOYMENT_VERSION"
printf '  %-20s %s\n' 'OpenCode' "$OPENCODE_VERSION"
printf '  %-20s %s\n' 'OpenChamber' "$OPENCHAMBER_VERSION"
printf '  %-20s %s\n' 'Node.js' "$NODE_MAJOR.x"
printf '\n'
ask 'Continue with installation?' || { printf 'Cancelled.\n'; exit 0; }

[[ $(df -Pk /home | awk 'NR == 2 {print $4}') -ge 1048576 ]] \
  || die 'At least 1 GiB of free disk space is required.'

printf '\n%sInstalling%s\n' "$BOLD" "$RESET"
run_step '[1/9] System dependencies' install_packages
run_step '[2/9] Runtime account' create_user
run_step '[3/9] Node.js' install_node
run_step '[4/9] OpenCode release' install_opencode_release
run_step '[5/9] OpenChamber release' install_openchamber_release
run_step '[6/9] Credentials' write_credentials
run_step '[7/9] System services' write_units
run_step '[8/9] Start and verify' start_services
run_step '[9/9] Deployment record' write_deployment_state

printf '\n%sYour credentials%s\n' "$BOLD" "$RESET"
cat "$SUMMARY_FILE"
printf '%sOpenChamber already has the OpenCode service credentials configured.%s\n' "$DIM" "$RESET"

configure_access

printf '\n%s%sOpenChamber is ready%s\n' "$BOLD" "$GREEN" "$RESET"
printf '%s====================%s\n' "$GREEN" "$RESET"
printf '  %-20s %s\n' 'Deployment' "$DEPLOYMENT_VERSION"
printf '  %-20s %s\n' 'OpenCode' "$OPENCODE_VERSION"
printf '  %-20s %s\n' 'OpenChamber' "$OPENCHAMBER_VERSION"
printf '  %-20s %s\n' 'Credentials' "$SUMMARY_FILE"
printf '\nFor future tested upgrades, run: %ssudo ./upgrade.sh%s\n' "$BOLD" "$RESET"
printf 'Treat any in-app update notice as informational on this managed VPS.\n'
printf '%sInstaller log: %s%s\n' "$DIM" "$LOG_FILE" "$RESET"
