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
readonly OPENCODE_ENV="/etc/opencode/server.env"
readonly OPENCHAMBER_ENV="/etc/openchamber/openchamber.env"
readonly DEPLOYMENT_STATE="/etc/openchamber/deployment.env"
readonly SUMMARY_FILE="/root/openchamber-install.txt"
readonly LOG_FILE="/var/log/openchamber-upgrade.log"
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
  cat <<'EOF_HELP'
Usage: sudo ./upgrade.sh

Check the installer Git repository for a newer tested OpenChamber/OpenCode pair
and upgrade this VPS interactively.

Options:
  -h, --help       Show this help and exit
      --version    Show upgrade-script version

Upgrade policy:
  - the Git repository is the authority for tested version pairs
  - upstream OpenChamber/OpenCode "latest" releases are not installed blindly
  - the repository is fetched first and any fast-forward is shown for approval
  - new releases are staged before downtime
  - service symlinks are switched atomically
  - if post-upgrade health checks fail, the previous binaries are restored
EOF_HELP
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
  '') ;;
  *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { usage >&2; exit 2; }

[[ $EUID -eq 0 ]] || die 'Run this script as root: sudo ./upgrade.sh'
[[ -t 0 && -t 1 ]] || die 'This upgrader is interactive and must be run in a terminal.'

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


git_repo() {
  git -c safe.directory="$SCRIPT_DIR" -C "$SCRIPT_DIR" "$@"
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

refresh_repo() {
  local repo branch upstream remote remote_branch local_commit remote_commit base count
  repo=$(git_repo rev-parse --show-toplevel 2>/dev/null) \
    || die 'upgrade.sh must be run from a Git clone of the installer repository.'
  [[ "$repo" == "$SCRIPT_DIR" ]] \
    || die 'upgrade.sh must live at the root of its Git repository.'
  git_repo diff --quiet && git_repo diff --cached --quiet \
    || die 'The installer repository has local tracked changes. Commit or discard them before upgrading.'

  branch=$(git_repo symbolic-ref --short HEAD 2>/dev/null) \
    || die 'The installer repository is in detached-HEAD state.'
  [[ "$branch" == main ]] \
    || die "Upgrades must run from the stable 'main' branch. Found: $branch"
  upstream=$(git_repo rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [[ -z "$upstream" ]]; then
    git_repo show-ref --verify --quiet "refs/remotes/origin/$branch" \
      || die "No upstream branch is configured for '$branch'."
    upstream="origin/$branch"
  fi
  remote=${upstream%%/*}
  remote_branch=${upstream#*/}
  [[ "$remote_branch" == main ]] \
    || die "The stable branch must track a remote 'main' branch. Found: $upstream"

  printf '  Checking %s...\n' "$upstream"
  git_repo fetch --quiet "$remote" "$remote_branch"
  local_commit=$(git_repo rev-parse HEAD)
  remote_commit=$(git_repo rev-parse "$upstream")
  [[ "$local_commit" != "$remote_commit" ]] || return 0

  base=$(git_repo merge-base HEAD "$upstream")
  [[ "$base" == "$local_commit" ]] \
    || die "Local repository has commits not contained in $upstream. Update it manually."

  count=$(git_repo rev-list --count "HEAD..$upstream")
  printf '\n%sInstaller repository update available%s (%s commit%s):\n' \
    "$BOLD" "$RESET" "$count" "$([[ $count == 1 ]] && printf '' || printf 's')"
  printf '  Remote: %s\n' "$(git_repo remote get-url "$remote")"
  git_repo log --oneline --no-decorate --max-count=8 "HEAD..$upstream" | sed 's/^/  /'
  printf '\nChanged files:\n'
  git_repo diff --stat "HEAD..$upstream" | sed 's/^/  /'
  printf '\n'
  ask 'Fast-forward this repository and continue?' || { printf 'Cancelled.\n'; exit 0; }
  git_repo merge --ff-only "$upstream"
  exec "$SCRIPT_DIR/upgrade.sh"
}

atomic_symlink() {
  local target=$1 link=$2 temporary
  temporary="${link}.new.$$"
  rm -f -- "$temporary"
  ln -s -- "$target" "$temporary"
  mv -Tf -- "$temporary" "$link"
}

installed_opencode_version() {
  [[ -x "$OPENCODE_CURRENT/opencode" ]] || return 1
  "$OPENCODE_CURRENT/opencode" --version 2>/dev/null | head -n1 | tr -d '[:space:]'
}

installed_openchamber_version() {
  local p="$OPENCHAMBER_CURRENT/lib/node_modules/@openchamber/web/package.json"
  [[ -r "$p" ]] || return 1
  node -p "require('$p').version" 2>/dev/null
}

ensure_node() {
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
    *) die 'Unsupported architecture.' ;;
  esac
}

stage_opencode() {
  local release_dir="$OPENCODE_ROOT/releases/$OPENCODE_VERSION"
  local target archive url api digest expected actual tmpdir version
  if [[ -x "$release_dir/opencode" ]]; then
    version="$($release_dir/opencode --version 2>/dev/null | head -n1 | tr -d '[:space:]')"
    [[ "$version" == "$OPENCODE_VERSION" ]] && return 0
    die "Existing OpenCode release directory is invalid: $release_dir"
  fi

  target="$(opencode_target)"
  archive="opencode-${target}.tar.gz"
  url="https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/${archive}"
  api="https://api.github.com/repos/anomalyco/opencode/releases/tags/v${OPENCODE_VERSION}"
  tmpdir=$(mktemp -d /tmp/opencode-upgrade.XXXXXX)

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
  [[ "$version" == "$OPENCODE_VERSION" ]] || die 'OpenCode staged version verification failed.'
  rm -rf -- "$tmpdir"
}

stage_openchamber() {
  local release_dir="$OPENCHAMBER_ROOT/releases/$OPENCHAMBER_VERSION"
  local staging package_json version
  install -d -o "$RUNTIME_USER" -g "$RUNTIME_USER" -m 700 "$HOME_DIR/.cache"
  package_json="$release_dir/lib/node_modules/@openchamber/web/package.json"
  if [[ -r "$package_json" ]]; then
    version=$(node -p "require('$package_json').version" 2>/dev/null || true)
    [[ "$version" == "$OPENCHAMBER_VERSION" ]] && return 0
    die "Existing OpenChamber release directory is invalid: $release_dir"
  fi

  staging=$(mktemp -d "$HOME_DIR/.cache/openchamber-upgrade.XXXXXX")
  chown "$RUNTIME_USER:$RUNTIME_USER" "$staging"
  runuser -u "$RUNTIME_USER" -- env HOME="$HOME_DIR" \
    npm install --global --prefix "$staging" --omit=dev --no-audit --no-fund \
      "@openchamber/web@${OPENCHAMBER_VERSION}"
  package_json="$staging/lib/node_modules/@openchamber/web/package.json"
  [[ -r "$package_json" ]] || die 'OpenChamber package was not staged.'
  version=$(node -p "require('$package_json').version" 2>/dev/null || true)
  [[ "$version" == "$OPENCHAMBER_VERSION" ]] || die 'OpenChamber staged version verification failed.'
  [[ -x "$staging/bin/openchamber" ]] || die 'OpenChamber staged executable is missing.'
  chown -R root:root "$staging"
  chmod -R u=rwX,go=rX "$staging"
  mv -- "$staging" "$release_dir"
}

read_env_value() {
  local file=$1 key=$2
  [[ -r "$file" ]] || return 1
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

refresh_units() {
  local temporary

  temporary=$(mktemp /etc/systemd/system/opencode.service.XXXXXX)
  cat >"$temporary" <<'EOF_UNIT'
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
  chown root:root "$temporary"
  chmod 644 "$temporary"
  mv -f -- "$temporary" /etc/systemd/system/opencode.service

  temporary=$(mktemp /etc/systemd/system/openchamber.service.XXXXXX)
  cat >"$temporary" <<'EOF_UNIT'
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
  chown root:root "$temporary"
  chmod 644 "$temporary"
  mv -f -- "$temporary" /etc/systemd/system/openchamber.service
  systemctl daemon-reload
}

health_check() {
  local expected_opencode=${1:-$OPENCODE_VERSION}
  local expected_openchamber=${2:-$OPENCHAMBER_VERSION}
  local attempt password chamber_password response
  systemctl restart opencode.service
  for attempt in $(seq 1 30); do
    systemctl is-active --quiet opencode.service \
      && ss -ltnH "sport = :$OPENCODE_PORT" | awk '{print $4}' \
        | grep -Eq "^127\\.0\\.0\\.1:$OPENCODE_PORT$" && break
    [[ $attempt -lt 30 ]] || return 1
    sleep 1
  done
  password="$(read_env_value "$OPENCODE_ENV" OPENCODE_SERVER_PASSWORD)"
  for attempt in $(seq 1 30); do
    if response=$(curl --fail --silent --show-error --max-time 3 \
      --user "opencode:$password" \
      "http://127.0.0.1:$OPENCODE_PORT/global/health") \
      && jq -e --arg version "$expected_opencode" \
        '.healthy == true and .version == $version' \
        <<<"$response" >/dev/null; then
      break
    fi
    [[ $attempt -lt 30 ]] || return 1
    sleep 1
  done

  systemctl restart openchamber.service
  for attempt in $(seq 1 30); do
    systemctl is-active --quiet openchamber.service \
      && ss -ltnH "sport = :$OPENCHAMBER_PORT" | awk '{print $4}' \
        | grep -Eq "^127\\.0\\.0\\.1:$OPENCHAMBER_PORT$" && break
    [[ $attempt -lt 30 ]] || return 1
    sleep 1
  done
  for attempt in $(seq 1 30); do
    if response=$(curl --fail --silent --show-error --max-time 3 \
      "http://127.0.0.1:$OPENCHAMBER_PORT/health") \
      && jq -e --arg version "$expected_openchamber" \
        '.status == "ok" and .openchamberVersion == $version
          and .openCodeRunning == true' <<<"$response" >/dev/null; then
      break
    fi
    [[ $attempt -lt 30 ]] || return 1
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
    [[ $attempt -lt 30 ]] || return 1
    sleep 1
  done
}

write_deployment_state() {
  printf '%s\n' \
    "DEPLOYMENT_VERSION=$DEPLOYMENT_VERSION" \
    "OPENCODE_VERSION=$OPENCODE_VERSION" \
    "OPENCHAMBER_VERSION=$OPENCHAMBER_VERSION" \
    "NODE_MAJOR=$NODE_MAJOR" \
    >"$DEPLOYMENT_STATE"
  chown root:root "$DEPLOYMENT_STATE"
  chmod 600 "$DEPLOYMENT_STATE"
}

refresh_summary() {
  local deployment=${1:-$DEPLOYMENT_VERSION}
  local opencode=${2:-$OPENCODE_VERSION}
  local openchamber=${3:-$OPENCHAMBER_VERSION}
  local opencode_password chamber_password
  opencode_password="$(read_env_value "$OPENCODE_ENV" OPENCODE_SERVER_PASSWORD)"
  chamber_password="$(read_env_value "$OPENCHAMBER_ENV" OPENCHAMBER_UI_PASSWORD)"
  cat >"$SUMMARY_FILE" <<EOF_SUMMARY
OpenChamber installation
========================
Deployment version: $deployment
OpenCode version: $opencode
OpenChamber version: $openchamber
OpenCode URL: http://127.0.0.1:$OPENCODE_PORT
OpenChamber URL: http://127.0.0.1:$OPENCHAMBER_PORT
Runtime user: opencode
OpenCode service username: opencode
OpenCode service password: $opencode_password
OpenChamber UI password: $chamber_password

Keep this file root-readable. It contains service credentials.
EOF_SUMMARY
  chown root:root "$SUMMARY_FILE"
  chmod 600 "$SUMMARY_FILE"
}

backup_state() {
  local backup_dir=/var/backups/openchamber snapshot
  install -d -o root -g root -m 700 "$backup_dir"
  snapshot="$BACKUP_SNAPSHOT"
  install -d -o root -g root -m 700 "$snapshot"
  cp -a /etc/systemd/system/opencode.service "$snapshot/opencode.service"
  cp -a /etc/systemd/system/openchamber.service "$snapshot/openchamber.service"
  cp -a "$DEPLOYMENT_STATE" "$snapshot/deployment.env"

  mapfile -t old_backups < <(find "$backup_dir" -mindepth 1 -maxdepth 1 \
    -type d -name 'upgrade-*' -printf '%T@ %p\n' \
    | sort -nr | awk 'NR > 3 {sub(/^[^ ]+ /, ""); print}')
  if (( ${#old_backups[@]} > 0 )); then
    rm -rf -- "${old_backups[@]}"
  fi
}

backup_application_state() {
  local archive="$BACKUP_SNAPSHOT/state.tar.gz" path
  local -a paths=()
  for path in \
    home/opencode/.config/openchamber \
    home/opencode/.config/opencode \
    home/opencode/.local/share/opencode \
    home/opencode/.local/state/opencode; do
    [[ -e "/$path" ]] && paths+=("$path")
  done
  if (( ${#paths[@]} > 0 )); then
    tar -C / -czf "$archive" "${paths[@]}"
    chown root:root "$archive"
    chmod 600 "$archive"
  fi
}

prune_releases() {
  local root=$1 current=$2 previous=${3:-} dir
  for dir in "$root"/releases/*; do
    [[ -d "$dir" ]] || continue
    [[ "$dir" == "$current" || -n "$previous" && "$dir" == "$previous" ]] && continue
    rm -rf -- "$dir"
  done
}

rollback_upgrade() {
  trap - EXIT INT TERM
  set +e
  printf '\n%sUpgrade did not complete; restoring the previous release.%s\n' \
    "$ORANGE" "$RESET"
  systemctl stop openchamber.service opencode.service >>"$LOG_FILE" 2>&1
  atomic_symlink "$old_opencode_target" "$OPENCODE_CURRENT"
  atomic_symlink "$old_openchamber_target" "$OPENCHAMBER_CURRENT"
  cp -a "$BACKUP_SNAPSHOT/opencode.service" \
    /etc/systemd/system/opencode.service
  cp -a "$BACKUP_SNAPSHOT/openchamber.service" \
    /etc/systemd/system/openchamber.service
  cp -a "$BACKUP_SNAPSHOT/deployment.env" "$DEPLOYMENT_STATE"
  systemctl daemon-reload >>"$LOG_FILE" 2>&1
  refresh_summary "$current_deployment" "$current_opencode" \
    "$current_openchamber"
  if health_check "$current_opencode" "$current_openchamber" \
    >>"$LOG_FILE" 2>&1; then
    printf '%sPrevious versions restored and healthy.%s\n' "$GREEN" "$RESET"
  else
    printf '%sPrevious versions did not recover automatically.%s\n' \
      "$RED" "$RESET" >&2
  fi
  printf 'Inspect: %s\n' "$LOG_FILE" >&2
}

rollback_on_exit() {
  local status=$?
  if [[ ${SWITCH_STARTED:-false} == true ]]; then
    rollback_upgrade
  fi
  exit "$status"
}

[[ -x "$OPENCODE_CURRENT/opencode" && -x "$OPENCHAMBER_CURRENT/bin/openchamber" ]] \
  || die 'This does not look like an installation created by the current installer. Run install.sh on a fresh VPS.'
[[ -r "$OPENCODE_ENV" && -r "$OPENCHAMBER_ENV" ]] || die 'Service credential files are missing.'
[[ -r "$DEPLOYMENT_STATE" ]] || die 'The installed deployment record is missing.'

printf '\n%s%sOpenChamber VPS upgrader%s\n' "$BOLD" "$CYAN" "$RESET"
printf '%s========================%s\n' "$CYAN" "$RESET"
refresh_repo
load_versions

current_opencode="$(installed_opencode_version || true)"
current_openchamber="$(installed_openchamber_version || true)"
current_deployment="$(read_env_value "$DEPLOYMENT_STATE" DEPLOYMENT_VERSION || true)"
current_node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
[[ -n "$current_opencode" && -n "$current_openchamber" ]] || die 'Could not determine currently installed versions.'
[[ -n "$current_deployment" ]] || die 'Could not determine the installed deployment version.'

printf '\n  %-18s %-14s -> %s\n' 'Deployment' "$current_deployment" "$DEPLOYMENT_VERSION"
printf '  %-18s %-14s -> %s\n' 'OpenCode' "$current_opencode" "$OPENCODE_VERSION"
printf '  %-18s %-14s -> %s\n' 'OpenChamber' "$current_openchamber" "$OPENCHAMBER_VERSION"
printf '  %-18s %s.x\n' 'Node.js target' "$NODE_MAJOR"

if [[ "$current_deployment" == "$DEPLOYMENT_VERSION" \
   && "$current_opencode" == "$OPENCODE_VERSION" \
   && "$current_openchamber" == "$OPENCHAMBER_VERSION" ]]; then
  printf "\n%sAlready current with this repository's tested version pair.%s\n" "$GREEN" "$RESET"
  exit 0
fi

printf '\nThe repository pins these versions as a tested pair; upstream latest releases\n'
printf 'are intentionally not installed until the repository adopts them.\n\n'
ask 'Stage and install this upgrade?' || { printf 'Cancelled.\n'; exit 0; }

if [[ "$current_node_major" != "$NODE_MAJOR" ]]; then
  printf '\n%sNode.js major-version change%s: %s.x -> %s.x\n' \
    "$ORANGE" "$RESET" "${current_node_major:-unknown}" "$NODE_MAJOR"
  printf 'This system-wide package change is not covered by automatic rollback.\n\n'
  ask 'Apply the Node.js major-version change and continue?' \
    || { printf 'Cancelled.\n'; exit 0; }
fi

printf '\n%sStaging releases (services remain online)%s\n' "$BOLD" "$RESET"
BACKUP_SNAPSHOT="/var/backups/openchamber/upgrade-$(date -u +%Y%m%dT%H%M%SZ)"
run_step '[1/4] Node.js requirement' ensure_node
run_step '[2/4] OpenCode release' stage_opencode
run_step '[3/4] OpenChamber release' stage_openchamber
run_step '[4/4] Backup application state' backup_state

old_opencode_target="$(readlink -f "$OPENCODE_CURRENT")"
old_openchamber_target="$(readlink -f "$OPENCHAMBER_CURRENT")"
new_opencode_target="$OPENCODE_ROOT/releases/$OPENCODE_VERSION"
new_openchamber_target="$OPENCHAMBER_ROOT/releases/$OPENCHAMBER_VERSION"

printf '\n%sSwitching releases%s\n' "$BOLD" "$RESET"
SWITCH_STARTED=true
trap rollback_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
systemctl stop openchamber.service opencode.service
backup_application_state
refresh_units
atomic_symlink "$new_opencode_target" "$OPENCODE_CURRENT"
atomic_symlink "$new_openchamber_target" "$OPENCHAMBER_CURRENT"

if health_check >>"$LOG_FILE" 2>&1; then
  write_deployment_state
  refresh_summary
  SWITCH_STARTED=false
  trap - EXIT INT TERM
  prune_releases "$OPENCODE_ROOT" "$new_opencode_target" "$old_opencode_target"
  prune_releases "$OPENCHAMBER_ROOT" "$new_openchamber_target" "$old_openchamber_target"
  printf '  Health checks                       %sdone%s\n' "$GREEN" "$RESET"
  printf '\n%s%sUpgrade complete%s\n' "$BOLD" "$GREEN" "$RESET"
  printf '  Deployment: %s\n' "$DEPLOYMENT_VERSION"
  printf '  OpenCode:    %s\n' "$OPENCODE_VERSION"
  printf '  OpenChamber: %s\n' "$OPENCHAMBER_VERSION"
  printf '\nPrevious application releases were retained for one rollback generation.\n'
  printf 'Pre-upgrade snapshot: %s\n' "$BACKUP_SNAPSHOT"
  printf '%sUpgrade log: %s%s\n' "$DIM" "$LOG_FILE" "$RESET"
  exit 0
fi

printf '  Health checks                       %sfailed%s\n' "$RED" "$RESET"
exit 1
