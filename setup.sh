#!/bin/bash
# =============================================================================
#  vxnode — setup.sh   (config-driven onboarding orchestrator, 1..N tenants)
#
#  WHAT IT DOES
#    For EVERY instance in the config file, runs in order:
#      1) tenant_prerequisites.sh   — Docker, system packages, registry auth
#      2) tenant_setup.sh           — deploy vxnode container + nginx + SSL
#    …on a remote VM over SSH, or on THIS machine when ssh_host is blank.
#    Codebase/IDE installers (tenant_codebase/) and tenant agents
#    (tenant_agents/) are intentionally NOT run here — vxnode must be up first.
#
#  CONFIG  (YAML preferred; JSON used automatically if YAML can't be parsed)
#    Edit tenant.yaml (or tenant.json). Schema:
#      defaults:  { email, ssh_port, docker_username, docker_pat, app_port }
#      instances: [ { name, ssh_host, ssh_user, ssh_key|ssh_password,
#                     ssh_port, domain, email } , ... ]
#    Leave ssh_host blank on an instance to install on THIS machine (local).
#
#  CONFIG FILE SELECTION (how setup.sh decides which file to read)
#    1) explicit arg:  ./setup.sh tenant.yaml   (or tenant.json)
#    2) else tenant.yaml   3) else tenant.yml   4) else tenant.json
#    YAML is parsed when python3 has PyYAML; if it doesn't, setup.sh falls
#    back to the tenant.json sibling automatically. tenant.yaml is canonical.
#
#  USAGE
#    ./setup.sh                       # all instances (auto-picks tenant.yaml)
#    ./setup.sh tenant.json           # force the JSON file
#    ./setup.sh --only NAME[,NAME2]   # just these instance(s)
#    ./setup.sh --stage prereq        # Docker/packages only (safe; no vxnode redeploy)
#    ./setup.sh --stage setup         # (re)deploy vxnode only
#    ./setup.sh --list                # print resolved instances, then exit
#
#  Requires next to this script: tenant_prerequisites.sh, tenant_setup.sh, and
#  python3 (config parsing). For SSH: ssh, tar (+ sshpass only for passwords).
# =============================================================================

# ##########################################################################
# #  LEGACY INLINE FALLBACK                                                 #
# #  Used ONLY when no tenant.yaml/tenant.json and no config-file argument  #
# #  is found. Prefer the config file. Env vars override these.             #
# ##########################################################################
SSH_HOST="${SSH_HOST:-}"            # EMPTY = local install
SSH_USER="${SSH_USER:-ubuntu}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
SSH_KEY="${SSH_KEY:-}"
SSH_PORT="${SSH_PORT:-22}"
DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-joelwembo@outlook.com}"
DOCKER_USERNAME="${DOCKER_USERNAME:-vxcloud}"
DOCKER_PAT="${DOCKER_PAT:-}"
APP_PORT="${APP_PORT:-}"

# ##########################################################################
# #  END FILL-IN — nothing to edit below this line                         #
# ##########################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREREQ_SH="tenant_prerequisites.sh"
SETUP_SH="tenant_setup.sh"

C_B='\033[0;34m'; C_G='\033[0;32m'; C_Y='\033[1;33m'; C_R='\033[0;31m'; C_N='\033[0m'
info(){ echo -e "${C_B}[setup]${C_N} $*"; }
ok(){   echo -e "${C_G}[setup] OK${C_N} $*"; }
warn(){ echo -e "${C_Y}[setup] !${C_N} $*"; }
die(){  echo -e "${C_R}[setup] x${C_N} $*" >&2; exit 1; }

# -- Validate the bundle is intact --
[ -f "$SCRIPT_DIR/$PREREQ_SH" ] || die "$PREREQ_SH not found next to setup.sh ($SCRIPT_DIR)"
[ -f "$SCRIPT_DIR/$SETUP_SH" ]  || die "$SETUP_SH not found next to setup.sh ($SCRIPT_DIR)"

# -- Arguments --
CONFIG_FILE=""
ONLY=""
LIST_ONLY=0
STAGE="all"     # all | prereq | setup  — which step(s) to run per instance
while [ $# -gt 0 ]; do
    case "$1" in
        --only)        ONLY="${2:-}"; shift 2 ;;
        --only=*)      ONLY="${1#*=}"; shift ;;
        --stage)       STAGE="${2:-}"; shift 2 ;;
        --stage=*)     STAGE="${1#*=}"; shift ;;
        --prereq-only) STAGE="prereq"; shift ;;   # Docker/packages only — does NOT touch a running vxnode
        --setup-only)  STAGE="setup";  shift ;;   # (re)deploy vxnode only — skips prerequisites
        --list|-l)     LIST_ONLY=1; shift ;;
        -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
        -*)            die "unknown option: $1 (try --help)" ;;
        *)             CONFIG_FILE="$1"; shift ;;
    esac
done
case "$STAGE" in all|prereq|setup) ;; *) die "invalid --stage '$STAGE' (use: all | prereq | setup)" ;; esac

# -- Resolve config file (explicit arg → tenant.yaml → tenant.yml → tenant.json) --
if [ -z "$CONFIG_FILE" ]; then
    if   [ -f "$SCRIPT_DIR/tenant.yaml" ]; then CONFIG_FILE="$SCRIPT_DIR/tenant.yaml"
    elif [ -f "$SCRIPT_DIR/tenant.yml" ];  then CONFIG_FILE="$SCRIPT_DIR/tenant.yml"
    elif [ -f "$SCRIPT_DIR/tenant.json" ]; then CONFIG_FILE="$SCRIPT_DIR/tenant.json"
    fi
fi

# -- Config parser: emit one TAB-separated row per instance (fixed column order).
#    Exit codes: 2=parse error, 3=YAML parser unavailable, 4=no matching instances.
parse_config(){ # $1=file  $2=only-filter
    python3 - "$1" "${2:-}" <<'PY'
import sys, json
path = sys.argv[1]
only = sys.argv[2] if len(sys.argv) > 2 else ""
def load(p):
    if p.endswith(('.yaml', '.yml')):
        try:
            import yaml
        except ImportError:
            sys.exit(3)                       # YAML impossible -> caller retries .json
        with open(p) as f:
            return yaml.safe_load(f) or {}
    with open(p) as f:
        return json.load(f)
try:
    data = load(path)
except SystemExit:
    raise
except Exception as e:
    sys.stderr.write("config parse error: %s\n" % e); sys.exit(2)
defaults = data.get('defaults') or {}
cols = ['name','ssh_host','ssh_user','ssh_password','ssh_key','ssh_port',
        'domain','email','docker_username','docker_pat','app_port']
onlyset = set(x.strip() for x in only.split(',') if x.strip()) if only else None
n = 0
for inst in (data.get('instances') or []):
    m = dict(defaults); m.update(inst or {})
    name = str(m.get('name','')).strip()
    if onlyset is not None and name not in onlyset:
        continue
    print('\x1f'.join('' if m.get(c) is None else str(m.get(c, '')) for c in cols))
    n += 1
if n == 0:
    sys.exit(4)
PY
}

# -- load_rows: parse_config + YAML→JSON fallback. Rows to stdout, notes to stderr.
load_rows(){ # $1=file  $2=only
    local cf="$1" only="$2" out rc=0
    set +e; out="$(parse_config "$cf" "$only")"; rc=$?; set -e
    if [ "$rc" -eq 3 ]; then
        local jf="${cf%.*}.json"
        [ -f "$jf" ] || jf="$SCRIPT_DIR/tenant.json"
        [ -f "$jf" ] || die "YAML parser (python3 PyYAML) unavailable and no JSON fallback found. pip install pyyaml, or provide tenant.json."
        warn "PyYAML unavailable — using JSON fallback: $jf" 1>&2
        set +e; out="$(parse_config "$jf" "$only")"; rc=$?; set -e
    fi
    [ "$rc" -eq 4 ] && die "no matching instances in $cf${only:+ (filter: $only)}"
    [ "$rc" -ne 0 ] && die "failed to parse config: $cf (rc=$rc)"
    printf '%s\n' "$out"
}

# -- install_one: prerequisites + tenant_setup for ONE instance (local or SSH).
install_one(){
    local name="$1" ssh_host="$2" ssh_user="$3" ssh_password="$4" ssh_key="$5" \
          ssh_port="$6" domain="$7" email="$8" docker_username="$9" \
          docker_pat="${10}" app_port="${11}"
    [ -n "$docker_username" ] || docker_username="vxcloud"
    [ -n "$ssh_port" ] || ssh_port="22"
    # Resolve a relative key path against the bundle directory.
    if [ -n "$ssh_key" ] && [[ "$ssh_key" != /* ]]; then
        ssh_key="$SCRIPT_DIR/${ssh_key#./}"
    fi

    # Build the env passed to the tenant scripts (only values that are set).
    local ENV_ARGS=("DOCKER_USERNAME=$docker_username")
    local REMOTE_ENV="DOCKER_USERNAME='$docker_username'"
    local kv k v
    for kv in "DOCKER_PAT=$docker_pat" "DOMAIN=$domain" "EMAIL=$email" "APP_PORT=$app_port"; do
        k="${kv%%=*}"; v="${kv#*=}"
        [ -n "$v" ] || continue
        ENV_ARGS+=("$k=$v"); REMOTE_ENV="$REMOTE_ENV $k='$v'"
    done

    echo
    info "════ instance: ${name:-<unnamed>}   host=${ssh_host:-LOCAL}   domain=${domain:-<none>} ════"

    if [ -z "$ssh_host" ]; then
        # ---------------------------- LOCAL INSTALL --------------------------
        info "ssh_host empty -> installing on THIS machine (local)  [stage: $STAGE]."
        command -v sudo >/dev/null 2>&1 || die "sudo is required for a local install"
        if [ "$STAGE" = prereq ] || [ "$STAGE" = all ]; then
            info "prerequisites ($PREREQ_SH) ..."
            sudo "${ENV_ARGS[@]}" bash "$SCRIPT_DIR/$PREREQ_SH" || die "prerequisites failed"
            ok "prerequisites complete"
        fi
        if [ "$STAGE" = setup ] || [ "$STAGE" = all ]; then
            info "vxnode setup ($SETUP_SH) ..."
            sudo "${ENV_ARGS[@]}" bash "$SCRIPT_DIR/$SETUP_SH" || die "tenant_setup failed"
            ok "vxnode setup complete (local)"
        fi
        return 0
    fi

    # ------------------------------ REMOTE INSTALL (SSH) ---------------------
    info "ssh_host=$ssh_host -> installing on remote VM as '$ssh_user'."
    command -v ssh >/dev/null 2>&1 || die "ssh not found on this machine"
    command -v tar >/dev/null 2>&1 || die "tar not found on this machine"

    local SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -p "$ssh_port")
    local SSH_BASE REMOTE_SUDO
    if [ -n "$ssh_password" ]; then
        command -v sshpass >/dev/null 2>&1 || die "ssh_password is set but 'sshpass' is not installed (apt-get install -y sshpass, or use ssh_key)."
        SSH_BASE=(sshpass -p "$ssh_password" ssh)
        SSH_OPTS+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
        REMOTE_SUDO="echo '$ssh_password' | sudo -S -p ''"
    elif [ -n "$ssh_key" ]; then
        [ -f "$ssh_key" ] || die "ssh_key not found: $ssh_key"
        chmod 600 "$ssh_key" 2>/dev/null || true
        SSH_BASE=(ssh); SSH_OPTS+=(-i "$ssh_key"); REMOTE_SUDO="sudo"
    else
        SSH_BASE=(ssh); REMOTE_SUDO="sudo"
        warn "No ssh_password or ssh_key set — relying on ssh-agent / default key."
    fi
    local REMOTE="$ssh_user@$ssh_host" REMOTE_DIR="/tmp/vxnode-install"

    info "Testing SSH connection to $REMOTE ..."
    "${SSH_BASE[@]}" "${SSH_OPTS[@]}" "$REMOTE" 'true' >/dev/null 2>&1 \
        || die "SSH connection failed to $REMOTE (host/user/key/port? is port $ssh_port open?)"
    ok "SSH reachable"

    info "Copying install bundle to $REMOTE:$REMOTE_DIR ..."
    "${SSH_BASE[@]}" "${SSH_OPTS[@]}" "$REMOTE" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'" \
        || die "could not prepare $REMOTE_DIR on the VM"
    tar -czf - -C "$SCRIPT_DIR" \
        --exclude='.git' --exclude='*.log' \
        --exclude='./vxcloud_vault/vault-consul' --exclude='vm-wipe-backup-*' . \
        | "${SSH_BASE[@]}" "${SSH_OPTS[@]}" "$REMOTE" "tar -xzf - -C '$REMOTE_DIR'" \
        || die "bundle copy failed"
    ok "bundle copied"

    if [ "$STAGE" = prereq ] || [ "$STAGE" = all ]; then
        info "prerequisites on VM ..."
        "${SSH_BASE[@]}" "${SSH_OPTS[@]}" "$REMOTE" \
            "cd '$REMOTE_DIR' && $REMOTE_SUDO $REMOTE_ENV bash $PREREQ_SH" \
            || die "remote prerequisites failed"
        ok "prerequisites complete on VM"
    fi

    if [ "$STAGE" = setup ] || [ "$STAGE" = all ]; then
        info "vxnode setup on VM ..."
        "${SSH_BASE[@]}" "${SSH_OPTS[@]}" "$REMOTE" \
            "cd '$REMOTE_DIR' && $REMOTE_SUDO $REMOTE_ENV bash $SETUP_SH" \
            || die "remote tenant_setup failed"
        ok "vxnode setup complete on $ssh_host"
    fi
    return 0
}

# -- Driver: loop over rows, isolate each install in a subshell, summarize. -----
declare -a SUMMARY=()
run_rows(){ # $1 = TSV rows (one instance per line)
    local rows="$1" total=0 failed=0 rc
    local name ssh_host ssh_user ssh_password ssh_key ssh_port domain email docker_username docker_pat app_port
    while IFS=$'\037' read -r name ssh_host ssh_user ssh_password ssh_key ssh_port domain email docker_username docker_pat app_port; do
        [ -n "${name}${ssh_host}" ] || continue
        total=$((total+1))
        set +e
        ( install_one "$name" "$ssh_host" "$ssh_user" "$ssh_password" "$ssh_key" \
                      "$ssh_port" "$domain" "$email" "$docker_username" "$docker_pat" "$app_port" )
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
            SUMMARY+=("OK    ${name:-$ssh_host}  (${ssh_host:-local})")
        else
            SUMMARY+=("FAIL  ${name:-$ssh_host}  (${ssh_host:-local})  rc=$rc")
            failed=$((failed+1))
        fi
    done <<< "$rows"

    echo
    info "──────── summary: $total instance(s), $failed failed ────────"
    local line
    for line in "${SUMMARY[@]}"; do
        case "$line" in OK*) ok "$line" ;; *) warn "$line" ;; esac
    done
    [ "$failed" -eq 0 ] || return 1
}

# =============================================================================
if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"
    command -v python3 >/dev/null 2>&1 || die "python3 is required to parse $CONFIG_FILE"
    info "Config: $CONFIG_FILE${ONLY:+   (only: $ONLY)}"
    ROWS="$(load_rows "$CONFIG_FILE" "$ONLY")"

    if [ "$LIST_ONLY" -eq 1 ]; then
        info "Resolved instances:"
        while IFS=$'\037' read -r name ssh_host ssh_user _pw ssh_key ssh_port domain _em _du _dp _ap; do
            [ -n "${name}${ssh_host}" ] || continue
            echo "  • ${name:-<unnamed>}  host=${ssh_host:-LOCAL}  user=$ssh_user  key=${ssh_key:-<none>}  domain=${domain:-<none>}  port=${ssh_port:-22}"
        done <<< "$ROWS"
        exit 0
    fi
    run_rows "$ROWS"
else
    # ---- Legacy single-instance inline fallback (no config file present) ----
    warn "No tenant.yaml/tenant.json or config argument — using inline SSH_HOST variables."
    ROW="$(printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s' \
        "inline" "$SSH_HOST" "$SSH_USER" "$SSH_PASSWORD" "$SSH_KEY" "$SSH_PORT" \
        "$DOMAIN" "$EMAIL" "$DOCKER_USERNAME" "$DOCKER_PAT" "$APP_PORT")"
    run_rows "$ROW"
fi

echo
ok "ALL DONE."
info "Verify a node:"
info "   curl -fsS http://127.0.0.1:8744/api/v2/health    (on the VM — health)"
info "   docker exec vxcloud-vxnode vxcli version          (CLI inside the container)"
