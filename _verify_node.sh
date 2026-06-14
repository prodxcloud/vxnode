#!/usr/bin/env bash
# =============================================================================
#  vxnode — _verify_node.sh   (post-stage health assertion; run by setup.sh)
# =============================================================================
#  Proves the node (and, when asked, the IDE) ACTUALLY serve — so "the script
#  finished" becomes "the node is provably up", catching half-installs even if a
#  future bug swallows an error.
#
#  Design rules (must stay true):
#    - Best-effort & defensive: never aborts, never throws (no `set -e`).
#    - Retries briefly so a service that's still warming up isn't a false FAIL.
#    - Exit 0  = all REQUIRED checks passed (or nothing to check).
#      Exit 1  = a required endpoint did not serve as expected.
#    - Prints HEALTH=<code> and IDE=<code|skip> for the operator log.
#
#  Inputs (env):
#    APP_PORT          vxnode API port            (default 8744)
#    CHECK_IDE         1 to also verify the IDE   (default 0)
#    IDE_BACKEND_PORT  openvscode host port       (default 8089)
# =============================================================================
set +e   # intentional: this script must never abort its caller

APP_PORT="${APP_PORT:-8744}"
CHECK_IDE="${CHECK_IDE:-0}"
IDE_BACKEND_PORT="${IDE_BACKEND_PORT:-8089}"

# curl may be missing on a barely-provisioned box — degrade to a skip, not a fail.
if ! command -v curl >/dev/null 2>&1; then
    echo "HEALTH=skip (curl unavailable)"
    echo "IDE=skip"
    exit 0
fi

# curl already prints "000" on a failed connect; capture it and only default to
# 000 if curl emits nothing at all (avoids a doubled "000000").
http_code() {
    local c
    c="$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "$1" 2>/dev/null)"
    [ -n "$c" ] && printf '%s' "$c" || printf '000'
}

rc=0

# ── Node health: required. Retry up to ~18s (service may still be starting). ──
health=000
for _ in 1 2 3 4 5 6; do
    health="$(http_code "http://127.0.0.1:${APP_PORT}/api/v2/health")"
    [ "$health" = 200 ] && break
    sleep 3
done
echo "HEALTH=${health}"
[ "$health" = 200 ] || rc=1

# ── IDE (optional): a 2xx/3xx/4xx means the IDE is up and (correctly) demanding
#    a token. Only 000 / 5xx (no listener / broken) counts as a failure. ──
if [ "$CHECK_IDE" = 1 ]; then
    ide=000
    for _ in 1 2 3 4 5; do
        ide="$(http_code "http://127.0.0.1:${IDE_BACKEND_PORT}/")"
        case "$ide" in 200|301|302|303|307|308|401|403) break ;; esac
        sleep 3
    done
    echo "IDE=${ide}"
    case "$ide" in 200|301|302|303|307|308|401|403) : ;; *) rc=1 ;; esac
else
    echo "IDE=skip"
fi

exit "$rc"
