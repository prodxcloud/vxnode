#!/usr/bin/env bash
# =============================================================================
#  vxnode — _remote_stage_runner.sh   (internal; invoked over SSH by setup.sh)
# =============================================================================
#  WHY THIS EXISTS
#    setup.sh runs each stage script (tenant_prerequisites.sh / tenant_setup.sh)
#    on the VM via `ssh ... bash <stage>`. Those stages enable a systemd timer
#    and (re)create containers; on a fresh VM the auto-update unit can fire mid
#    run and a backgrounded/reparented process inherits the SSH channel's
#    stdout/stderr pipes. ssh then NEVER returns even though the stage finished
#    successfully — the whole install "hangs" at 100% done.
#
#  THE FIX
#    Run the stage with its stdout/stderr pointed at a LOCAL FILE on the VM, and
#    stream that file back live with `tail --pid`. Any process the stage spawns
#    inherits the FILE descriptor, never the SSH channel — so when the stage's
#    pid exits, tail exits, this script exits, and ssh returns cleanly. Output
#    is still streamed live to the operator, and the real exit code propagates.
#
#  USAGE (called by setup.sh, not by humans):
#    sudo <ENV...> bash _remote_stage_runner.sh <stage-script> [args...]
#  Environment from setup.sh (DOCKER_USERNAME, DOCKER_PAT, DOMAIN, EMAIL,
#  APP_PORT, ...) is inherited by the stage script automatically.
# =============================================================================
set -u

TARGET="${1:-}"
[ -n "$TARGET" ] || { echo "[stage-runner] no stage script given" >&2; exit 64; }
shift || true
[ -f "$TARGET" ] || { echo "[stage-runner] stage script not found: $TARGET" >&2; exit 66; }

LOG="$(mktemp "${TMPDIR:-/tmp}/vxnode-stage.XXXXXX")" || { echo "[stage-runner] mktemp failed" >&2; exit 70; }
RC_FILE="$LOG.rc"

# Run the stage in the background with BOTH std streams redirected to $LOG so a
# daemon it leaves behind can never pin the SSH channel open. Also start it in a
# NEW session via `setsid -w`: anything the stage backgrounds (the auto-update
# unit, container helpers, …) then lands in its own session — not the SSH login
# session — so it can't keep `sshd` alive and hang the run after it finished.
# `-w` makes setsid wait and propagate the real exit code (and keeps tail -f live).
if command -v setsid >/dev/null 2>&1; then
    ( setsid -w bash "$TARGET" "$@" >"$LOG" 2>&1 </dev/null; echo "$?" >"$RC_FILE" ) &
else
    ( bash "$TARGET" "$@" >"$LOG" 2>&1 </dev/null; echo "$?" >"$RC_FILE" ) &
fi
STAGE_PID=$!

# Stream live; tail exits as soon as the stage pid dies (GNU coreutils --pid).
tail -n +1 --pid="$STAGE_PID" -f "$LOG" 2>/dev/null

wait "$STAGE_PID" 2>/dev/null || true
RC="$(cat "$RC_FILE" 2>/dev/null || echo 1)"
rm -f "$LOG" "$RC_FILE" 2>/dev/null || true
exit "$RC"
