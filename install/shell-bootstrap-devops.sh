#!/usr/bin/env bash
# =====================================================================
#  shell-bootstrap-devops.sh
#
#  Sync selected local directories with their remote GitHub repos under
#  the "vxcloud" org. Default semantics are FORCE-based (one side wins)
#  but every destructive action is preceded by a backup + divergence
#  report so you can always recover.
#
#  Targets
#    shell-bootstrap-devops   scripts/  +  shared/{ansible,development,
#                             forgejoactions,gitea,githubactions,gitlab,
#                             jenkins,kubernetes,terraform}
#                             -> https://github.com/vxcloud/shell-bootstrap-devops.git
#
#    shell-bootstrap-lite     generated/packages/
#                             -> https://github.com/vxcloud/shell-bootstrap-lite.git
#
#    studio                   shared/studio/<repo>
#                             -> https://github.com/vxcloud/<repo>.git
#
#  Usage
#    bash ./shell-bootstrap-devops.sh --target <name> [--repo <r|all>] <pull|push> [flags]
#
#  Flags
#    --yes         skip the 3-second pre-action warning countdown
#    --dry-run     report what would happen, do not change anything
#    -h, --help    show usage
#
#  Default semantics (destructive; backups always taken)
#    pull  -> fetch + git reset --hard origin/<branch> + git clean -fd
#    push  -> commit all local changes + git push --force
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_backend_starter push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_expo_starter push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_aiassistant push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_blog push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_business push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_calendar push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_crm push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_dashboard push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_diet push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_ecommerce push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_erp push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_finance push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_formbuilder push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_marketing push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_nutritionapp push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_onboarding push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_organization push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_portfolio push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_restaurant push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_saas push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_saas1 push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_saas2 push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_frontend_starter_sports push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_html_starter push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_html_starter_billing push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_html_starter_booking push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_html_starter_email push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_html_starter_landing push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_html_starter_registration push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_nextjs_starter push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_react2d_starter push --yes
# bash ./shell-bootstrap-devops.sh --target studio --repo va_studio_react3d_starter push --yes

# bash ./shell-bootstrap-devops.sh --target shell-bootstrap-lite
#  Recovery
#    Backups live under $ROOT/.sbd-staging/backups/
#      *.tar.gz   snapshot of the local working tree before pull
#      *.bundle   snapshot of the remote branch before push --force
#                 restore with: git clone <bundle> <dir>
#                         or:   git fetch <bundle> <branch>
# =====================================================================

# bash ./shell-bootstrap-devops.sh --target shell-bootstrap-devops pull --yes ; \
# bash ./shell-bootstrap-devops.sh --target shell-bootstrap-lite   pull --yes ; \
# bash ./shell-bootstrap-devops.sh --target studio --repo all      pull --yes


set -euo pipefail

# ---- Hardcoded credentials / identity -------------------------------
GH_USER="joelwembo"
GH_TOKEN=""
GH_ORG="vxcloud"
GIT_EMAIL="${GH_USER}@users.noreply.github.com"
GIT_NAME="${GH_USER}"

# ---- Paths ----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
STAGING_DIR="$ROOT_DIR/.sbd-staging"
BACKUP_DIR="$STAGING_DIR/backups"
mkdir -p "$STAGING_DIR" "$BACKUP_DIR"

# ---- Pretty output --------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_CYN=$'\033[36m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_YEL=""; C_GRN=""; C_CYN=""; C_DIM=""; C_OFF=""
fi
log()  { printf '%s[sbd]%s     %s\n' "$C_CYN" "$C_OFF" "$*"; }
warn() { printf '%s[sbd WARN]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
ok()   { printf '%s[sbd OK]%s   %s\n' "$C_GRN" "$C_OFF" "$*"; }
err()  { printf '%s[sbd ERR]%s  %s\n' "$C_RED" "$C_OFF" "$*" 1>&2; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

usage() {
    cat <<EOF
Usage:
  bash $(basename "$0") --target <shell-bootstrap-devops|shell-bootstrap-lite|studio> \\
                        [--repo <name|all>] <pull|push> [--yes] [--dry-run]

Flags:
  --yes        skip 3s warning countdown
  --dry-run    preview the operation (no writes, no network pushes)

Examples:
  bash $(basename "$0") --target shell-bootstrap-devops pull
  bash $(basename "$0") --target shell-bootstrap-devops push
  bash $(basename "$0") --target shell-bootstrap-lite   push
  bash $(basename "$0") --target studio --repo all pull
  bash $(basename "$0") --target studio --repo va_studio_backend_starter push --dry-run
EOF
}

# ---- Argument parsing ----------------------------------------------
TARGET=""; REPO=""; ACTION=""; ASSUME_YES=0; DRY_RUN=0
while (( $# )); do
    case "$1" in
        --target)  TARGET="${2:-}"; shift 2 ;;
        --repo)    REPO="${2:-}";   shift 2 ;;
        --yes|-y)  ASSUME_YES=1;    shift   ;;
        --dry-run) DRY_RUN=1;       shift   ;;
        pull|push) ACTION="$1";     shift   ;;
        -h|--help) usage; exit 0 ;;
        *) err "Unknown argument: $1"; usage; exit 2 ;;
    esac
done

[[ -z "$TARGET" ]] && { err "--target is required";           usage; exit 2; }
[[ -z "$ACTION" ]] && { err "action (pull|push) is required"; usage; exit 2; }

# Sub-paths of shared/ that belong to the shell-bootstrap-devops repo
DEVOPS_SHARED_DIRS=(ansible development forgejoactions gitea githubactions gitlab jenkins kubernetes terraform)

# ---- URL helpers ----------------------------------------------------
remote_url()  { printf 'https://%s:%s@github.com/%s/%s.git' "$GH_USER" "$GH_TOKEN" "$GH_ORG" "$1"; }
display_url() { printf 'https://github.com/%s/%s.git' "$GH_ORG" "$1"; }

# Detect remote default branch; fall back to "main".
default_branch() {
    local url="$1" br
    br="$(git ls-remote --symref "$url" HEAD 2>/dev/null \
          | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}' || true)"
    [[ -z "$br" ]] && br="main"
    printf '%s' "$br"
}

# ---- Safety helpers -------------------------------------------------

# Timestamp used for backup file names.
ts_now() { date -u +%Y%m%dT%H%M%SZ; }

# Tarball the local working tree (incl. .git so reflog is preserved).
# Args: <path> <label>
backup_worktree() {
    local path="$1" label="$2"
    [[ -d "$path" ]] || return 0
    local ts; ts=$(ts_now)
    local dest="$BACKUP_DIR/${label}-local-${ts}.tar.gz"
    local parent base
    parent="$(dirname "$path")"; base="$(basename "$path")"
    if ( cd "$parent" && tar -czf "$dest" "$base" ) 2>/dev/null; then
        log "    local backup: $dest"
    else
        warn "    local backup failed for $path (continuing)"
    fi
}

# Bundle the remote branch so force-push victims can be recovered.
# Args: <stage_dir> <branch> <label>
backup_remote_branch() {
    local stage="$1" branch="$2" label="$3"
    local ts; ts=$(ts_now)
    local dest="$BACKUP_DIR/${label}-remote-${branch}-${ts}.bundle"
    if ( cd "$stage" && git fetch origin "$branch" 2>/dev/null \
          && git bundle create "$dest" "refs/remotes/origin/$branch" 2>/dev/null ); then
        log "    remote backup: $dest"
    else
        warn "    remote backup skipped (remote empty / branch missing / offline)"
    fi
}

# Show ahead/behind + the commits on the losing side.
# Args: <repo_dir> <branch>
show_divergence() {
    local repo_dir="$1" branch="$2"
    [[ -d "$repo_dir/.git" ]] || { log "    (no local git history yet)"; return 0; }
    pushd "$repo_dir" >/dev/null
    git fetch origin "$branch" 2>/dev/null || { popd >/dev/null; log "    (remote unreachable — divergence unknown)"; return 0; }
    local ahead behind
    ahead=$(git rev-list --count "origin/$branch..HEAD"  2>/dev/null || echo 0)
    behind=$(git rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)
    log "    divergence vs origin/$branch: local is $ahead ahead, $behind behind"
    if [[ "$behind" != "0" ]]; then
        log "    commits on REMOTE your push --force would erase (max 10):"
        git log --oneline -n 10 "HEAD..origin/$branch" 2>/dev/null | sed 's/^/        /' || true
    fi
    if [[ "$ahead" != "0" ]]; then
        log "    commits on LOCAL your pull --hard would erase (max 10):"
        git log --oneline -n 10 "origin/$branch..HEAD" 2>/dev/null | sed 's/^/        /' || true
    fi
    # Uncommitted working-tree changes
    local dirty
    dirty=$(git status --porcelain | wc -l | tr -d ' ')
    if [[ "$dirty" != "0" ]]; then
        log "    uncommitted local changes: $dirty file(s)"
        git status --porcelain | head -n 10 | sed 's/^/        /' || true
    fi
    popd >/dev/null
}

# Big scary warning shown before any destructive sync.
confirm_force() {
    local action="$1" scope="$2"
    warn "==================================================================="
    if (( DRY_RUN )); then
        warn "DRY-RUN ${action} on: ${scope} (no changes will be made)"
    else
        warn "FORCE ${action} on: ${scope}"
        warn "  pull -> remote OVERWRITES your local changes"
        warn "  push -> local  OVERWRITES the remote history"
        warn "  Backups saved to: $BACKUP_DIR"
    fi
    warn "==================================================================="
    if (( ASSUME_YES == 0 )) && (( DRY_RUN == 0 )); then
        warn "Proceeding in 3 seconds... Ctrl-C to abort."
        sleep 3
    fi
}

# --------------------------------------------------------------------
# sync_single_repo <local_path> <repo_name> <action>
#   Treats <local_path> as the working tree of repo <repo_name>.
#   Used for studio repos and for shell-bootstrap-lite.
# --------------------------------------------------------------------
sync_single_repo() {
    local local_path="$1" repo="$2" action="$3"
    local url;  url=$(remote_url "$repo")
    local show; show=$(display_url "$repo")

    mkdir -p "$local_path"
    log "repo=${repo}"
    log "  path  : ${local_path}"
    log "  remote: ${show}"

    pushd "$local_path" >/dev/null

    if [[ ! -d .git ]]; then
        log "  initializing git in $(pwd)"
        if (( DRY_RUN == 0 )); then
            git init -q
            git remote add origin "$url"
        fi
    else
        (( DRY_RUN == 0 )) && git remote set-url origin "$url"
    fi

    local branch; branch="$(default_branch "$url")"

    # Show the user what is about to be clobbered.
    show_divergence "$local_path" "$branch"

    if (( DRY_RUN )); then
        log "  [dry-run] would ${action} ${repo}@${branch}"
        popd >/dev/null
        return 0
    fi

    if [[ "$action" == "pull" ]]; then
        if ! git fetch --prune origin "$branch" 2>/dev/null; then
            warn "  remote branch '$branch' not found or remote empty; skipping pull"
            popd >/dev/null; return 0
        fi

        popd >/dev/null
        backup_worktree "$local_path" "$repo"
        pushd "$local_path" >/dev/null
        git checkout -B "$branch" "origin/$branch"
        git reset --hard "origin/$branch"
        git clean -fd
        ok "  pulled (force) ${repo}@${branch}"
    else
        git checkout -B "$branch" 2>/dev/null || git checkout -b "$branch"
        git add -A
        if ! git diff --cached --quiet; then
            git -c user.email="$GIT_EMAIL" -c user.name="$GIT_NAME" \
                commit -q -m "sbd: sync $(ts_now)"
        else
            log "  no local changes to commit"
        fi

        backup_remote_branch "$local_path" "$branch" "$repo"
        if ! git push --force --set-upstream origin "$branch"; then
            err "  push failed for ${repo} (remote repo may not exist yet in org '${GH_ORG}')"
            popd >/dev/null; return 1
        fi
        ok "  pushed (force) ${repo}@${branch}"
    fi

    popd >/dev/null
}

# --------------------------------------------------------------------
# sync_aggregate_repo <repo_name> <action> <path1> <path2> ...
#   Syncs a group of local sub-paths into a single remote repo via a
#   staging clone under $STAGING_DIR.
# --------------------------------------------------------------------
sync_aggregate_repo() {
    local repo="$1"; shift
    local action="$1"; shift
    local paths=("$@")

    local url;  url=$(remote_url "$repo")
    local show; show=$(display_url "$repo")
    local stage="$STAGING_DIR/$repo"

    log "aggregate repo=${repo}"
    log "  remote: ${show}"
    log "  stage : ${stage}"
    log "  paths : ${paths[*]}"

    # Prepare staging clone
    if [[ ! -d "$stage/.git" ]]; then
        if (( DRY_RUN )); then
            log "  [dry-run] would clone ${show} to ${stage}"
        else
            rm -rf "$stage"
            mkdir -p "$(dirname "$stage")"
            if ! git clone "$url" "$stage" 2>/dev/null; then
                warn "  remote appears empty; initializing staging locally"
                mkdir -p "$stage"
                pushd "$stage" >/dev/null
                git init -q
                git remote add origin "$url"
                popd >/dev/null
            fi
        fi
    fi

    local branch; branch="$(default_branch "$url")"

    # Sync staging to remote state first
    if [[ -d "$stage/.git" ]]; then
        pushd "$stage" >/dev/null
        git remote set-url origin "$url"
        if git fetch --prune origin "$branch" 2>/dev/null; then
            git checkout -B "$branch" "origin/$branch" 2>/dev/null || git checkout -B "$branch"
            git reset --hard "origin/$branch" 2>/dev/null || true
            git clean -fd
        else
            warn "  remote branch '$branch' not present yet"
            git checkout -B "$branch" 2>/dev/null || git checkout -b "$branch"
        fi
        popd >/dev/null
    fi

    # Preview divergence per path (file-level). `diff -rq` exits 1 when it
    # finds differences, which would trip `set -euo pipefail` and silently
    # abort the run before commit/push — so the pipeline is wrapped in
    # `|| true` and the preview itself is further guarded with `|| true`
    # to make it strictly informational.
    log "  --- preview -------------------------------------------------"
    for p in "${paths[@]}"; do
        local left="$ROOT_DIR/$p"  right="$stage/$p"
        if [[ -d "$left" && -d "$right" ]]; then
            local diffcount
            diffcount=$({ diff -rq --exclude='.git' "$left" "$right" 2>/dev/null || true; } | wc -l | tr -d ' ' || echo '?')
            log "    $p  : ${diffcount:-?} differing entries vs remote"
        elif [[ -d "$left" ]]; then
            log "    $p  : exists locally, absent on remote"
        elif [[ -d "$right" ]]; then
            log "    $p  : absent locally, exists on remote"
        else
            log "    $p  : absent on both sides"
        fi
    done || true
    log "  -------------------------------------------------------------"

    if (( DRY_RUN )); then
        log "  [dry-run] would ${action} aggregate ${repo}@${branch}"
        return 0
    fi

    if [[ "$action" == "pull" ]]; then
        # Backup local copies of the affected paths before we overwrite
        for p in "${paths[@]}"; do
            [[ -d "$ROOT_DIR/$p" ]] && backup_worktree "$ROOT_DIR/$p" "${repo}-$(echo "$p" | tr '/' '_')"
        done

        for p in "${paths[@]}"; do
            local src="$stage/$p/"
            local dst="$ROOT_DIR/$p/"
            if [[ -d "$stage/$p" ]]; then
                mkdir -p "$dst"
                log "    rsync --force (remote -> local) $p"
                rsync -a --delete --exclude='.git' "$src" "$dst"
            else
                warn "    remote has no '$p'; leaving local copy untouched"
            fi
        done
        ok "  pulled aggregate ${repo}@${branch}"
    else
        # Backup the current remote tip before we overwrite it
        if [[ -d "$stage/.git" ]]; then
            backup_remote_branch "$stage" "$branch" "$repo"
        fi

        for p in "${paths[@]}"; do
            local src="$ROOT_DIR/$p/"
            local dst="$stage/$p/"
            if [[ -d "$ROOT_DIR/$p" ]]; then
                mkdir -p "$dst"
                log "    rsync (local -> stage) $p"
                rsync -a --delete --exclude='.git' "$src" "$dst"
            else
                warn "    local has no '$p'; skipping"
            fi
        done

        pushd "$stage" >/dev/null
        git add -A
        if ! git diff --cached --quiet; then
            git -c user.email="$GIT_EMAIL" -c user.name="$GIT_NAME" \
                commit -q -m "sbd: sync $(ts_now)"
        else
            log "  no changes to commit"
        fi

        if ! git push --force --set-upstream origin "$branch"; then
            err "  push failed for ${repo} (remote repo may not exist yet in org '${GH_ORG}')"
            popd >/dev/null; return 1
        fi
        ok "  pushed aggregate (force) ${repo}@${branch}"
        popd >/dev/null
    fi
}

# --------------------------------------------------------------------
# Auto-detect studio repos from shared/studio/
# --------------------------------------------------------------------
list_studio_repos() {
    local studio_root="$ROOT_DIR/shared/studio"
    if [[ -d "$studio_root" ]]; then
        find "$studio_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -u
    fi
}

# ---- Dispatch -------------------------------------------------------
case "$TARGET" in
    shell-bootstrap-devops|devops)
        confirm_force "$ACTION" "shell-bootstrap-devops (scripts + selected shared/*)"
        paths=("scripts")
        for s in "${DEVOPS_SHARED_DIRS[@]}"; do paths+=("shared/$s"); done
        sync_aggregate_repo "shell-bootstrap-devops" "$ACTION" "${paths[@]}"
        ;;

    shell-bootstrap-lite|lite)
        confirm_force "$ACTION" "shell-bootstrap-lite (generated/packages)"
        sync_single_repo "$ROOT_DIR/generated/packages" "shell-bootstrap-lite" "$ACTION"
        ;;

    studio)
        [[ -z "$REPO" ]] && { err "--repo is required for --target studio (use 'all' or a repo name)"; exit 2; }
        if [[ "$REPO" == "all" ]]; then
            mapfile -t ALL_REPOS < <(list_studio_repos)
            if (( ${#ALL_REPOS[@]} == 0 )); then
                err "No studio repos found under $ROOT_DIR/shared/studio"
                exit 1
            fi
            confirm_force "$ACTION" "ALL ${#ALL_REPOS[@]} studio repos under shared/studio/"
            fail_count=0
            for r in "${ALL_REPOS[@]}"; do
                if ! sync_single_repo "$ROOT_DIR/shared/studio/$r" "$r" "$ACTION"; then
                    warn "  $r failed — continuing with the rest"
                    fail_count=$((fail_count + 1))
                fi
            done
            if (( fail_count > 0 )); then
                warn "Completed with $fail_count failure(s) out of ${#ALL_REPOS[@]}"
            fi
        else
            confirm_force "$ACTION" "studio/$REPO"
            sync_single_repo "$ROOT_DIR/shared/studio/$REPO" "$REPO" "$ACTION"
        fi
        ;;

    *)
        err "Unknown --target: $TARGET"
        usage
        exit 2
        ;;
esac

ok "Done."
