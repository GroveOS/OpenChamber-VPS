# OpenChamber VPS

Install OpenChamber and OpenCode as a managed pair on a dedicated Ubuntu VPS.
Both applications run as an unprivileged user, listen on localhost only, and
start automatically through `systemd`.

> This repository assumes the VPS is dedicated to OpenChamber and OpenCode.
> Do not use it as a generic installer for a shared production server.

## Quick Start

Clone the repository into a stable, root-owned location and run the guided
installer:

```bash
sudo git clone https://github.com/GroveOS/OpenChamber-VPS.git \
  /opt/openchamber-vps
sudo /opt/openchamber-vps/install.sh
```

The installer is interactive. It installs the pinned application versions,
creates credentials and services, verifies both applications, and then offers
Cloudflare Tunnel or SSH forwarding for browser access.

For help or version details:

```bash
/opt/openchamber-vps/install.sh --help
/opt/openchamber-vps/install.sh --version
```

## Deployment Model

This repository, rather than either application's updater, controls the
deployment. The tested application pair is recorded in `versions.env`:

| Component | Initial version |
| --- | --- |
| Deployment | `0.1.0` |
| OpenCode | `1.18.31` |
| OpenChamber | `1.24.2` |
| Node.js | `22.x` |

OpenChamber `1.24.2` directly depends on the OpenCode SDK at `1.18.31`. Future
releases update these pins only after the pair has been reviewed and tested.

Installed applications use immutable, root-owned release directories:

```text
/opt/opencode/releases/<version>/
/opt/opencode/current -> releases/<version>

/opt/openchamber/releases/<version>/
/opt/openchamber/current -> releases/<version>
```

The `opencode` Unix account can execute the applications but cannot replace
their binaries. Treat in-app update notices as informational on this managed
VPS.

## Runtime Security

The installer creates a locked, unprivileged `opencode` account with no
membership in `sudo` or `docker`. Runtime state belongs to that account;
application releases and service configuration remain root-owned.

The services listen only on the VPS loopback interface:

| Service | Address |
| --- | --- |
| OpenCode | `http://127.0.0.1:4096` |
| OpenChamber | `http://127.0.0.1:3001` |

OpenCode runs as a separate authenticated service. OpenChamber connects to it
over localhost and does not manage its process or binary lifecycle.

The `systemd` units apply additional hardening, including filesystem
protection, an empty capability set, restricted privilege escalation, and
process and file-descriptor limits. OpenCode still has agent and shell access
to data intentionally placed under `/home/opencode`; it is not a VM sandbox.

## Credentials

The installer generates separate OpenCode service and OpenChamber UI
passwords. OpenChamber receives the OpenCode credentials automatically.

Root-readable credential files are stored at:

```text
/root/openchamber-install.txt
/etc/opencode/server.env
/etc/openchamber/openchamber.env
```

Retrieve the installation summary later with:

```bash
sudo cat /root/openchamber-install.txt
```

## Browser Access

OpenChamber remains bound to localhost. Choose one of the following access
methods at the end of installation.

### Cloudflare Tunnel

In Cloudflare, open **Networking > Tunnels**, create or select a remotely
managed tunnel, choose the `cloudflared` connector, and copy only its connector
token. The helper installs `cloudflared`, stores the token as a root-only
systemd credential, and verifies that the connector becomes ready.

After it connects, add a Published application route with this service URL:

```text
http://127.0.0.1:3001
```

Put a Cloudflare Access self-hosted application in front of the public
hostname. Cloudflare Access and the OpenChamber UI password provide separate,
complementary authentication layers.

The helper can be rerun independently:

```bash
sudo /opt/openchamber-vps/setup-cloudflare.sh
```

The token is stored at `/etc/cloudflared/tunnel.token`. Rerunning the helper
keeps the token for an active connector or offers to replace one that is not
connected. `cloudflared` is managed by Ubuntu packages and is intentionally not
pinned in `versions.env`.

### SSH Forwarding

Run this on your own computer and keep the connection open:

```bash
ssh -N -L 3001:127.0.0.1:3001 root@SERVER_IP
```

Then open `http://localhost:3001`. Neither access method requires opening an
inbound OpenChamber port on the VPS.

## API Access

OpenCode provides the API behind OpenChamber. The installer runs it on
`127.0.0.1:4096` with HTTP Basic authentication enabled. The username is
`opencode`; the password is in `/root/openchamber-install.txt` on the VPS.

This API is powerful. It can start agent sessions, use configured models, and
work with files under the `opencode` account. Treat its password and URL like
administrator credentials.

### Choose an API URL

With Cloudflare Tunnel, add another Published application route on the same
tunnel. For example:

```text
agent.example.com -> http://127.0.0.1:4096
```

Cloudflare provides public HTTPS while the OpenCode service itself remains on
localhost. Use this base URL on your computer:

```bash
API_URL=https://agent.example.com
```

For private access over SSH instead, forward port `4096`:

```bash
ssh -N -L 4096:127.0.0.1:4096 root@SERVER_IP
```

Keep that connection open and use:

```bash
API_URL=http://localhost:4096
```

Enter the OpenCode password without putting it directly in a script:

```bash
read -rsp "OpenCode password: " OPENCODE_PASSWORD; printf '\n'
```

### Basic Examples

Check the server and its version:

```bash
curl -fsS -u "opencode:$OPENCODE_PASSWORD" \
  "$API_URL/global/health" | jq
```

OpenCode sessions belong to a working directory. Set this to an existing
repository on the VPS, then list its sessions:

```bash
REPO=/home/opencode/repos/my-project

curl -fsS -u "opencode:$OPENCODE_PASSWORD" \
  -H "X-OpenCode-Directory: $REPO" \
  "$API_URL/session" | jq
```

Create a session and save its ID:

```bash
SESSION_ID=$(
  curl -fsS -u "opencode:$OPENCODE_PASSWORD" \
    -H "X-OpenCode-Directory: $REPO" \
    -H 'Content-Type: application/json' \
    -d '{"title":"API example"}' \
    "$API_URL/session" | jq -r '.id'
)
printf 'Session: %s\n' "$SESSION_ID"
```

Send a prompt and wait for the agent response:

```bash
curl -fsS -u "opencode:$OPENCODE_PASSWORD" \
  -H "X-OpenCode-Directory: $REPO" \
  -H 'Content-Type: application/json' \
  -d '{"parts":[{"type":"text","text":"Summarize this project."}]}' \
  "$API_URL/session/$SESSION_ID/message" \
  | jq -r '.parts[] | select(.type == "text") | .text'
```

List the full message history:

```bash
curl -fsS -u "opencode:$OPENCODE_PASSWORD" \
  -H "X-OpenCode-Directory: $REPO" \
  "$API_URL/session/$SESSION_ID/message" | jq
```

The prompt uses the server's configured default model. The response may also
contain tool and reasoning parts; the example above prints only text parts.

The server publishes its complete OpenAPI 3.1 document at `/doc`:

```bash
curl -fsS -u "opencode:$OPENCODE_PASSWORD" "$API_URL/doc" | jq
```

See the official OpenCode
[server documentation](https://opencode.ai/docs/server/) for the remaining
endpoints and request types.

### Cloudflare Access

OpenCode Basic auth is enough for the OpenCode server itself. If
`agent.example.com` is also protected by Cloudflare Access, an automated client
must pass both layers. Create an Access service token and add these headers to
each request while keeping the normal `-u` option. For example:

```bash
curl -fsS -u "opencode:$OPENCODE_PASSWORD" \
  -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
  -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
  "$API_URL/global/health" | jq
```

Use Cloudflare's normal two-header service-token mode. Do not put its token in
the `Authorization` header because OpenCode already uses that header for Basic
auth. Browser login policies may return an HTML login page to API clients, so a
Service Auth policy is the simpler choice for automation.

## Upgrades

Run upgrades as root from the installed repository:

```bash
sudo /opt/openchamber-vps/upgrade.sh
```

The upgrader:

1. Fetches the stable `main` branch and shows available repository changes.
2. Asks before fast-forwarding the local clone.
3. Reloads the tested versions from `versions.env`.
4. Shows the installed and proposed deployment pair.
5. Stages and verifies new releases while services remain online.
6. Saves a root-only application-state snapshot.
7. Switches the stable `/opt/.../current` symlinks.
8. Verifies exact application versions, OpenCode health, and OpenChamber login.
9. Restores the previous releases and units if verification fails.

Local tracked changes or diverged Git history stop the upgrade. The script
never resets or discards local work.

The installed deployment record is stored at:

```text
/etc/openchamber/deployment.env
```

This version is separate from the application versions. A release containing
only service, security, or upgrade changes is therefore still applied.

## Backups And Rollback

Before switching releases, `upgrade.sh` snapshots important state under:

```text
/var/backups/openchamber/upgrade-<timestamp>/
```

The newest three snapshots are retained. They include OpenChamber and OpenCode
state plus the prior service definitions and deployment record.

Binary and service rollback is automatic when post-upgrade health checks fail.
Application-state restoration is deliberately manual because a newer release
may perform data migrations that cannot safely be reversed automatically.
These snapshots supplement, but do not replace, normal server backups.

Node.js is system-wide. A future Node major-version change must be tested with
both the old and new application pair because it is outside binary-symlink
rollback. The upgrader displays a separate confirmation before applying one.

## Release Process

`main` is the stable deployment channel. Development belongs on branches;
untested changes must not be pushed directly to `main`.

For a future release such as `0.2.0`:

1. Review the target OpenChamber release and its exact OpenCode SDK version.
2. Update `DEPLOYMENT_VERSION` and the tested pins in `versions.env`.
3. Test a fresh installation, an in-place upgrade, reboot persistence, and a
   forced health-check rollback on a supported Ubuntu VPS.
4. Merge the tested release commit into `main`.
5. Tag that exact commit as `v0.2.0` and publish the GitHub release.

Every release after `v0.1.0` must descend from the previous release. Do not
rewrite published history or move old tags after servers begin following the
upgrade channel.

## Filesystem Layout

```text
/opt/openchamber-vps                 deployment repository
/opt/opencode/releases              OpenCode releases
/opt/opencode/current               active OpenCode release
/opt/openchamber/releases           OpenChamber releases
/opt/openchamber/current            active OpenChamber release
/home/opencode/repos                agent work area
/home/opencode/.config/openchamber  OpenChamber state
/home/opencode/.local/share/opencode OpenCode state
```

## Troubleshooting

Detailed installer output is stored in:

```text
/var/log/openchamber-install.log
/var/log/openchamber-upgrade.log
/var/log/cloudflared-setup.log
```

Useful checks:

```bash
systemctl is-active opencode openchamber
systemctl is-enabled opencode openchamber
journalctl -u opencode -u openchamber -n 100 --no-pager
ss -ltn
```

If Cloudflare is configured:

```bash
systemctl is-active cloudflared
journalctl -u cloudflared -n 100 --no-pager
curl --fail http://127.0.0.1:20241/ready
```

## Supported Systems

The scripts accept Ubuntu 24.04 and 26.04 on `amd64` and `arm64`. OpenCode
selects the baseline x64 build automatically when AVX2 is unavailable.

Each release should document which combinations received fresh-install and
upgrade testing. Acceptance testing on one platform does not imply complete
coverage of the full matrix.
