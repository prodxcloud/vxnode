#!/usr/bin/env bash
# =============================================================================
#  vxnode-update.sh — host-side fleet updater (the "hands")
#
#  Runs on a systemd timer (every ~15 min). Compares the channel manifest's
#  desired image digest to the digest the node is currently running; if they
#  differ it pulls the new digest, recreates the container, health-gates it,
#  and ROLLS BACK to the previous digest if the new one doesn't come up.
#
#  Pull auth: none — vxcloud/vxnode is a public image. (If you make it private,
#  `docker login` on the host once; this script does not handle credentials.)
#
#  Override via env (defaults shown):
#    DEPLOY_DIR=/opt/vxcloud
#    IMAGE=vxcloud/vxnode
#    CONTAINER_NAME=vxcloud-vxnode
#    APP_PORT=8744
#    CHANNEL_URL=https://vxcloud.io/download/vxnode/stable.json
# =============================================================================
set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/vxcloud}"
COMPOSE_FILE="${COMPOSE_FILE:-$DEPLOY_DIR/docker-compose.yml}"
IMAGE="${IMAGE:-vxcloud/vxnode}"
TAG="${TAG:-latest}"
CONTAINER_NAME="${CONTAINER_NAME:-vxcloud-vxnode}"
APP_PORT="${APP_PORT:-8744}"
HEALTH_URL="http://127.0.0.1:${APP_PORT}/api/v2/health"
CHANNEL_URL="${CHANNEL_URL:-https://vxcloud.io/download/vxnode/stable.json}"
TRIGGER="${TRIGGER:-$DEPLOY_DIR/generated/.vxnode-update}"
LOG="${LOG:-$DEPLOY_DIR/update/vxnode-update.log}"
LOCK="${LOCK:-/tmp/vxnode-update.lock}"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date -u +%FT%TZ)] $*" | tee -a "$LOG"; }

# Single-flight: never run two updates at once.
exec 9>"$LOCK"
flock -n 9 || { log "another update run holds the lock — exiting"; exit 0; }

# ── desired digest: prefer the manifest; fall back to the trigger file ──
desired=""
if manifest=$(curl -fsSL --max-time 15 "$CHANNEL_URL" 2>/dev/null); then
    desired=$(printf '%s' "$manifest" | jq -r '.digest // empty' 2>/dev/null || true)
fi
if [ -z "$desired" ] && [ -f "$TRIGGER" ]; then
    desired=$(head -n1 "$TRIGGER" 2>/dev/null || true)
fi
case "$desired" in
    sha256:*) : ;;
    *) log "no valid desired digest (manifest=$CHANNEL_URL) — nothing to do"; exit 0 ;;
esac

# ── currently-running digest ──
running=""
if img_id=$(docker inspect -f '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null); then
    running=$(docker inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$img_id" 2>/dev/null | sed 's/.*@//' || true)
fi

if [ "$desired" = "$running" ]; then
    log "up to date ($desired)"
    rm -f "$TRIGGER" 2>/dev/null || true
    exit 0
fi

log "update: running='${running:-none}' → desired='$desired'"

# ── pull the desired digest, tag it as the tracked tag, recreate ──
if ! docker pull "${IMAGE}@${desired}" >>"$LOG" 2>&1; then
    log "ERROR: pull ${IMAGE}@${desired} failed — keeping current image"
    exit 1
fi
docker tag "${IMAGE}@${desired}" "${IMAGE}:${TAG}"

cd "$DEPLOY_DIR"
docker compose -f "$COMPOSE_FILE" up -d >>"$LOG" 2>&1

# ── health-gate ──
healthy=false
for _ in $(seq 1 30); do   # ~60s
    if curl -fsf --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then healthy=true; break; fi
    sleep 2
done

if [ "$healthy" = true ]; then
    log "OK: now running $desired (healthy)"
    rm -f "$TRIGGER" 2>/dev/null || true
    docker image prune -f >>"$LOG" 2>&1 || true
    exit 0
fi

# ── rollback ──
log "ERROR: new image unhealthy after 60s — rolling back"
if [ -n "$running" ]; then
    docker tag "${IMAGE}@${running}" "${IMAGE}:${TAG}" 2>>"$LOG" || true
    docker compose -f "$COMPOSE_FILE" up -d >>"$LOG" 2>&1 || true
    log "rolled back to $running"
else
    log "no previous digest recorded — cannot auto-roll-back; investigate on the node"
fi
exit 1
