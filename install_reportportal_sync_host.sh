#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Install dependencies, run ReportPortal with Docker Compose, and schedule sync_reportportal.sh.

Usage:
  sudo ./install_reportportal_sync_host.sh [options]

Options:
  --repo-dir <path>       Repo directory containing sync_reportportal.sh
                          Default: directory of this script
  --user <name>           Linux user that should run the sync timer
                          Default: SUDO_USER (or current user)
  --interval <calendar>   systemd OnCalendar expression
                          Default: *:0/30 (every 30 minutes)
  --rp-url <url>          ReportPortal URL used by sync script
                          Default: http://127.0.0.1:8080
  --gh-token <token>      GitHub token for unattended gh access
                          If omitted, existing gh auth for --user is used
  --vpn-cidr <cidr>       Optional CIDR to allow inbound TCP/8080 via ufw
                          Example: 10.8.0.0/24
  --no-start              Do not run docker compose up during install
  --help                  Show this help

Examples:
  sudo ./install_reportportal_sync_host.sh --user alex --interval '*:0/15'
  sudo ./install_reportportal_sync_host.sh --vpn-cidr 10.8.0.0/24
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root with sudo."
    echo "Example: sudo ./install_reportportal_sync_host.sh --user ${USER}"
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_USER="${SUDO_USER:-${USER}}"
SYNC_INTERVAL="*:0/30"
RP_URL="http://127.0.0.1:8080"
GH_TOKEN_VALUE="${GH_TOKEN:-}"
VPN_CIDR=""
START_SERVICES="yes"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-dir)
            REPO_DIR="$2"
            shift 2
            ;;
        --user)
            SYNC_USER="$2"
            shift 2
            ;;
        --interval)
            SYNC_INTERVAL="$2"
            shift 2
            ;;
        --rp-url)
            RP_URL="$2"
            shift 2
            ;;
        --gh-token)
            GH_TOKEN_VALUE="$2"
            shift 2
            ;;
        --vpn-cidr)
            VPN_CIDR="$2"
            shift 2
            ;;
        --no-start)
            START_SERVICES="no"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

REPO_DIR="$(realpath "$REPO_DIR")"
if [[ ! -d "$REPO_DIR" ]]; then
    echo "ERROR: repo directory not found: $REPO_DIR"
    exit 1
fi

if [[ ! -f "$REPO_DIR/sync_reportportal.sh" ]]; then
    echo "ERROR: sync_reportportal.sh not found in $REPO_DIR"
    exit 1
fi

if [[ ! -f "$REPO_DIR/docker-compose.yml" ]]; then
    echo "ERROR: docker-compose.yml not found in $REPO_DIR"
    exit 1
fi

if ! id "$SYNC_USER" >/dev/null 2>&1; then
    echo "ERROR: user '$SYNC_USER' does not exist"
    exit 1
fi

install_with_apt() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        bash \
        ca-certificates \
        curl \
        docker-compose-plugin \
        docker.io \
        git \
        gh \
        jq \
        openssh-client \
        python3 \
        unzip
}

install_with_dnf() {
    dnf install -y \
        bash \
        ca-certificates \
        curl \
        docker \
        docker-compose-plugin \
        git \
        gh \
        jq \
        openssh-clients \
        python3 \
        unzip
}

echo "==> Installing dependencies"
if command -v apt-get >/dev/null 2>&1; then
    install_with_apt
elif command -v dnf >/dev/null 2>&1; then
    install_with_dnf
else
    echo "ERROR: Unsupported package manager. Use apt-get or dnf, or install dependencies manually."
    exit 1
fi

echo "==> Enabling Docker"
systemctl enable --now docker
usermod -aG docker "$SYNC_USER" || true

echo "==> Ensuring scripts are executable"
chmod +x "$REPO_DIR"/*.sh

ENV_FILE="/etc/reportportal-sync.env"
echo "==> Writing $ENV_FILE"
cat > "$ENV_FILE" <<EOF
RP_URL=${RP_URL}
EOF

if [[ -n "$GH_TOKEN_VALUE" ]]; then
    {
        echo "GH_TOKEN=${GH_TOKEN_VALUE}"
        echo "GITHUB_TOKEN=${GH_TOKEN_VALUE}"
    } >> "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

SERVICE_FILE="/etc/systemd/system/reportportal-sync.service"
TIMER_FILE="/etc/systemd/system/reportportal-sync.timer"

echo "==> Writing systemd service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sync GitHub artifacts into ReportPortal
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=${SYNC_USER}
WorkingDirectory=${REPO_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/bash ${REPO_DIR}/sync_reportportal.sh
EOF

echo "==> Writing systemd timer"
cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run ReportPortal sync on a schedule

[Timer]
OnCalendar=${SYNC_INTERVAL}
Persistent=true
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
EOF

echo "==> Reloading and enabling timer"
systemctl daemon-reload
systemctl enable --now reportportal-sync.timer

if [[ "$START_SERVICES" == "yes" ]]; then
    echo "==> Pulling and starting ReportPortal"
    docker compose -f "$REPO_DIR/docker-compose.yml" pull
    docker compose -f "$REPO_DIR/docker-compose.yml" up -d --no-build
else
    echo "==> Skipped docker compose startup (--no-start)"
fi

if [[ -n "$VPN_CIDR" ]]; then
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        echo "==> Opening TCP/8080 from VPN CIDR $VPN_CIDR"
        ufw allow from "$VPN_CIDR" to any port 8080 proto tcp
    else
        echo "==> ufw is not active; skipping firewall rule"
    fi
fi

echo ""
echo "Install complete."
echo ""
echo "ReportPortal UI: ${RP_URL}/ui/"
echo "Timer status: systemctl status reportportal-sync.timer"
echo "Recent sync logs: journalctl -u reportportal-sync.service -n 100 --no-pager"
echo ""
echo "If GH_TOKEN was not provided, authenticate gh as ${SYNC_USER}:"
echo "  sudo -u ${SYNC_USER} gh auth login --web --scopes 'repo,actions:read'"
echo ""
echo "If ${SYNC_USER} was newly added to docker group, re-login before running docker commands as that user."
