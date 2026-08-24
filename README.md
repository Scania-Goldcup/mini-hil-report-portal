# Reporting Test Host Setup

This project can run in two parts:

- ReportPortal web server (Docker Compose)
- Periodic artifact sync/import job (systemd timer running sync_reportportal.sh)

You do not need containers for the sync script itself, but you need a reachable ReportPortal API/UI endpoint.

## Quick Start On A New Linux Machine

Run from this repository:

```bash
sudo ./install_reportportal_sync_host.sh --user alex --interval '*:0/30'
```

What the installer does:

- Installs dependencies (docker, docker compose plugin, gh, python3, curl, unzip, ssh client)
- Enables Docker service
- Starts ReportPortal with docker compose pull + up -d --no-build
- Creates systemd unit files for scheduled sync
- Enables timer reportportal-sync.timer

## Optional Arguments

```bash
sudo ./install_reportportal_sync_host.sh \
  --user alex \
  --interval '*:0/15' \
  --rp-url http://127.0.0.1:8080 \
  --vpn-cidr 10.8.0.0/24
```

- --interval uses systemd OnCalendar syntax
- --vpn-cidr adds a ufw allow rule for TCP port 8080 from your VPN subnet (only if ufw is active)
- --gh-token can be supplied for unattended GitHub CLI auth

## Reach The Web Server From Another Machine

1. Confirm the server IP reachable over VPN.
2. Ensure firewall allows inbound TCP 8080 from your VPN CIDR.
3. Open in browser from your other machine:

```text
http://<vpn-server-ip>:8080/ui/
```

Compose maps 8080:8080, so it listens on all host interfaces unless your host firewall blocks it.

## Check Status

```bash
docker compose ps
systemctl status reportportal-sync.timer
journalctl -u reportportal-sync.service -n 100 --no-pager
```

## Authentication For Scheduled Sync

The sync job calls GitHub through gh.

Choose one:

1. Provide a token during install:

```bash
sudo ./install_reportportal_sync_host.sh --user alex --gh-token <token>
```

2. Authenticate gh for the sync user:

```bash
sudo -u alex gh auth login --web --scopes 'repo,actions:read'
```

## Manual Run

```bash
./sync_reportportal.sh
```

## Notes

- sync_reportportal.sh has a lock at /tmp/reportportal-sync.lock to avoid overlapping runs.
- If Docker was just installed, your user may need to log out/in once to get docker group membership.
