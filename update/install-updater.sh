#!/usr/bin/env bash
# =============================================================================
#  install-updater.sh — enable vxnode fleet auto-update on this host
#
#  Installs vxnode-update.sh + the systemd timer so the node pulls and recreates
#  itself whenever the channel manifest's digest changes (health-gated, with
#  rollback). Run ONCE per node, after the node container is up (README step 4).
#
#    sudo ./install-updater.sh
#    # canary node: sudo CHANNEL_URL=https://vxcloud.io/download/vxnode/canary.json ./install-updater.sh
# =============================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)"; exit 1; }

DEPLOY_DIR="${DEPLOY_DIR:-/opt/vxcloud}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

install -d "$DEPLOY_DIR/update" "$DEPLOY_DIR/generated"
install -m 0755 "$HERE/vxnode-update.sh" "$DEPLOY_DIR/update/vxnode-update.sh"
install -m 0644 "$HERE/vxnode-update.service" /etc/systemd/system/vxnode-update.service
install -m 0644 "$HERE/vxnode-update.timer"   /etc/systemd/system/vxnode-update.timer

# Per-node channel override (e.g. canary) via a drop-in, if CHANNEL_URL is set.
if [ -n "${CHANNEL_URL:-}" ]; then
    install -d /etc/systemd/system/vxnode-update.service.d
    cat > /etc/systemd/system/vxnode-update.service.d/channel.conf <<EOF
[Service]
Environment=CHANNEL_URL=${CHANNEL_URL}
EOF
fi

systemctl daemon-reload
systemctl enable --now vxnode-update.timer
echo "✓ vxnode-update.timer enabled — next run in ~2min, then every 5min"
echo "  logs:   tail -f $DEPLOY_DIR/update/vxnode-update.log"
echo "  manual: sudo systemctl start vxnode-update.service"
echo "  status: systemctl list-timers vxnode-update.timer"
