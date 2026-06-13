# =============================================================================
#  vxnode-update.ps1 — Windows host-side fleet updater
#
#  Windows equivalent of update/vxnode-update.sh. Compares the channel
#  manifest's desired image digest to the digest the node is currently
#  running; on mismatch pulls the new digest, recreates the container,
#  health-gates /api/v2/health, and ROLLS BACK to the previous digest if
#  the new image doesn't come up.
#
#  Runs Linux containers via Docker Desktop (WSL2 backend) — the vxnode
#  image is Linux-only, so Docker Desktop with the WSL2 engine is required.
#  Docker Engine Linux mode is not supported.
#
#  Triggered by Windows Task Scheduler (every 5 min). See
#  install-updater.ps1 for one-shot registration.
#
#  Override via env (Set with $env:NAME='value' or in the Task Scheduler
#  task definition):
#    DEPLOY_DIR     default: $env:ProgramData\vxcloud
#    IMAGE          default: vxcloud/vxnode
#    TAG            default: latest
#    CONTAINER_NAME default: vxcloud-vxnode
#    APP_PORT       default: 8744
#    CHANNEL_URL    default: https://vxcloud.io/download/vxnode/stable.json
# =============================================================================

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest prints a progress bar by default; off for logs

# ── Config (env overrides apply) ──────────────────────────────────────────
$DeployDir     = if ($env:DEPLOY_DIR)     { $env:DEPLOY_DIR }     else { Join-Path $env:ProgramData 'vxcloud' }
$ComposeFile   = if ($env:COMPOSE_FILE)   { $env:COMPOSE_FILE }   else { Join-Path $DeployDir 'docker-compose.yml' }
$Image         = if ($env:IMAGE)          { $env:IMAGE }          else { 'vxcloud/vxnode' }
$Tag           = if ($env:TAG)            { $env:TAG }            else { 'latest' }
$ContainerName = if ($env:CONTAINER_NAME) { $env:CONTAINER_NAME } else { 'vxcloud-vxnode' }
$AppPort       = if ($env:APP_PORT)       { $env:APP_PORT }       else { '8744' }
$HealthUrl     = "http://127.0.0.1:$AppPort/api/v2/health"
$ChannelUrl    = if ($env:CHANNEL_URL)    { $env:CHANNEL_URL }    else { 'https://vxcloud.io/download/vxnode/stable.json' }
$TriggerFile   = if ($env:TRIGGER)        { $env:TRIGGER }        else { Join-Path $DeployDir 'generated\.vxnode-update' }
$LogFile       = if ($env:LOG)            { $env:LOG }            else { Join-Path $DeployDir 'update\vxnode-update.log' }
$LockName      = 'Global\vxnode-update'   # Named-mutex single-flight (cross-process on Windows)

# ── Log helper (UTC ISO timestamps, tees to file + console) ────────────────
New-Item -ItemType Directory -Force -Path (Split-Path $LogFile -Parent) | Out-Null
function Write-Log {
    param([string]$Msg)
    $line = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"), $Msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

# ── .env persistence guard ─────────────────────────────────────────────────
# If the compose declares a host .env bind mount but that file is missing,
# Docker would create an empty DIRECTORY at the path and break /app/.env
# (synced creds gone). Seed it from the running container (preserves creds) or
# the desired image BEFORE recreating. No-op when there's no .env mount or the
# file already exists. Mirrors ensure_env_file() in update/vxnode-update.sh.
function Ensure-EnvFile {
    param([string]$Desired)
    if (-not (Test-Path $ComposeFile)) { return }
    $envSrc = $null
    foreach ($line in (Get-Content $ComposeFile)) {
        if ($line -match '^\s*-\s*(.+?):/app/\.env\s*$') { $envSrc = $Matches[1].Trim(); break }
    }
    if (-not $envSrc) { return }
    # Resolve a relative (./x or x) mount source against the deploy dir; keep absolute paths.
    if ($envSrc -match '^\.[\\/]') { $envSrc = Join-Path $DeployDir ($envSrc -replace '^\.[\\/]','') }
    elseif (-not [System.IO.Path]::IsPathRooted($envSrc)) { $envSrc = Join-Path $DeployDir $envSrc }
    if (Test-Path $envSrc) { return }
    Write-Log "host .env ($envSrc) declared in compose but missing — seeding to avoid a broken bind mount"
    # 1) Preserve creds already synced into the running container.
    & docker cp "${ContainerName}:/app/.env" $envSrc 2>$null | Out-Null
    if ((Test-Path $envSrc) -and ((Get-Item $envSrc).Length -gt 0)) {
        Write-Log "  seeded .env from running container (creds preserved)"
    } else {
        if (Test-Path $envSrc) { Remove-Item $envSrc -Force -ErrorAction SilentlyContinue }
        # 2) Fresh: seed from the desired image's baked template.
        $tmpc = "vxnode-envseed-$PID"
        & docker create --name $tmpc "$Image@$Desired" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            & docker cp "${tmpc}:/app/.env" $envSrc 2>$null | Out-Null
            & docker rm -f $tmpc 2>$null | Out-Null
            if (Test-Path $envSrc) { Write-Log "  seeded .env from image template" }
        }
    }
}

# ── Single-flight: a Global mutex so two timer fires don't collide ─────────
# Windows has no flock(2); a named mutex serves the same purpose. Released
# automatically when the process exits even on crash.
$mutex = New-Object System.Threading.Mutex($false, $LockName)
if (-not $mutex.WaitOne(0)) {
    Write-Log "another update run holds the lock — exiting"
    exit 0
}

try {
    # ── Resolve desired digest from the channel manifest ──────────────────
    $desired = $null
    try {
        $manifest = Invoke-RestMethod -Uri $ChannelUrl -TimeoutSec 15
        if ($manifest.digest) { $desired = [string]$manifest.digest }
    } catch {
        Write-Log "channel fetch failed: $($_.Exception.Message)"
    }
    # Fallback to the trigger file the in-container listener writes when it
    # spots a new digest before the host has polled. The container/host poll
    # at the same 5-min cadence so this is mostly redundant, but it lets the
    # dashboard "Update now" button (which writes the trigger directly) win
    # races against the scheduled timer.
    if (-not $desired -and (Test-Path $TriggerFile)) {
        $desired = (Get-Content $TriggerFile -TotalCount 1).Trim()
    }
    if (-not $desired -or -not $desired.StartsWith('sha256:')) {
        Write-Log "no valid desired digest (manifest=$ChannelUrl) — nothing to do"
        exit 0
    }

    # ── Running digest: inspect the container's image's RepoDigests[0] ────
    $running = ''
    $imgId = (& docker inspect -f '{{.Image}}' $ContainerName 2>$null)
    if ($LASTEXITCODE -eq 0 -and $imgId) {
        # `index .RepoDigests 0` fails the whole template when the slice is
        # empty, hence the `if .RepoDigests` guard.
        $repoDigest = (& docker inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' $imgId 2>$null)
        if ($repoDigest -and $repoDigest -match '@(sha256:[0-9a-f]+)') {
            $running = $Matches[1]
        }
    }

    if ($desired -eq $running) {
        Write-Log "up to date ($desired)"
        if (Test-Path $TriggerFile) { Remove-Item $TriggerFile -Force -ErrorAction SilentlyContinue }
        exit 0
    }

    Write-Log "update: running='$($running ?? 'none')' -> desired='$desired'"

    # ── Pull desired digest, retag locally, recreate via compose ──────────
    & docker pull "$Image@$desired" 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: pull $Image@$desired failed — keeping current image"
        exit 1
    }
    & docker tag "$Image@$desired" "${Image}:${Tag}" 2>&1 | Out-Null

    Ensure-EnvFile -Desired $desired   # never let a missing host .env turn the bind mount into a dir

    Push-Location $DeployDir
    try {
        & docker compose -f $ComposeFile up -d 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null
    } finally {
        Pop-Location
    }

    # ── Health-gate the new container (~60s budget) ───────────────────────
    $healthy = $false
    foreach ($_ in 1..30) {
        try {
            $resp = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -eq 200) { $healthy = $true; break }
        } catch { }
        Start-Sleep -Seconds 2
    }

    if ($healthy) {
        Write-Log "OK: now running $desired (healthy)"
        if (Test-Path $TriggerFile) { Remove-Item $TriggerFile -Force -ErrorAction SilentlyContinue }
        & docker image prune -f 2>&1 | Out-Null
        exit 0
    }

    # ── Rollback: re-tag the previous digest and re-up the compose ────────
    Write-Log "ERROR: new image unhealthy after 60s — rolling back"
    if ($running) {
        & docker tag "$Image@$running" "${Image}:${Tag}" 2>&1 | Out-Null
        Push-Location $DeployDir
        try {
            & docker compose -f $ComposeFile up -d 2>&1 | Tee-Object -FilePath $LogFile -Append | Out-Null
        } finally {
            Pop-Location
        }
        Write-Log "rolled back to $running"
    } else {
        Write-Log "no previous digest recorded — cannot auto-roll-back; investigate on the node"
    }
    exit 1
} finally {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
}
