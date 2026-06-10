# =============================================================================
#  prerequisites.ps1 — one-time host prep for a vxnode deployment (Windows)
#
#  Windows equivalent of prerequisites.sh. On Windows the vxnode image is run
#  as a Linux container via Docker Desktop's WSL2 backend (the image is
#  Linux-only — the host is Windows, the container is Linux). This script
#  verifies / installs the HOST-side tooling needed to deploy and operate a
#  node:
#       • WSL2            (Docker Desktop's Linux engine)
#       • Docker Desktop  (docker + docker compose)
#       • git, jq, curl
#       • node (>=20), python 3.12, terraform   (optional host CLIs)
#
#  Redis / Go / Celery run INSIDE the Linux container on Windows, so they are
#  not installed on the host (unlike the Linux prerequisites.sh).
#
#  Installs use winget (App Installer). A few items — WSL2 and Docker Desktop —
#  may require a reboot / manual first-launch before `docker` works.
#
#  USAGE (PowerShell as Administrator):
#    powershell -ExecutionPolicy Bypass -File .\prerequisites.ps1
#    .\prerequisites.ps1 -SkipOptional      # only WSL2 + Docker + git + jq + curl
# =============================================================================
[CmdletBinding()]
param(
    [switch] $SkipOptional   # skip node/python/terraform (the optional host CLIs)
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$LogFile = Join-Path $env:TEMP 'prerequisites_install.log'
"Installation log started at $((Get-Date).ToUniversalTime().ToString('u'))" | Set-Content -Path $LogFile -Encoding UTF8

function Write-Info { param($m) Write-Host $m            -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "OK $m"       -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "! $m"        -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "x $m"        -ForegroundColor Red }

# ── Must be elevated (winget package installs + WSL feature need it) ───────
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "Must run as Administrator. Right-click PowerShell -> Run as administrator."
    exit 1
}

# ── winget is the package backbone here ────────────────────────────────────
$haveWinget = [bool](Get-Command winget -ErrorAction SilentlyContinue)
if (-not $haveWinget) {
    Write-Warn "winget (App Installer) not found. Install it from the Microsoft Store, then re-run."
    Write-Warn "Falling back to manual checks only — nothing will be auto-installed."
}

# Install a winget package if the probe command is missing. Returns $true if
# the tool is present (already or after install).
function Ensure-Tool {
    param(
        [string]   $Probe,        # command name to test (e.g. 'git')
        [string]   $WingetId,     # winget package id
        [string]   $Friendly      # display name
    )
    if (Get-Command $Probe -ErrorAction SilentlyContinue) {
        Write-Ok "$Friendly is already installed."
        return $true
    }
    if (-not $haveWinget) {
        Write-Warn "$Friendly not found and winget is unavailable — install it manually."
        return $false
    }
    Write-Info "Installing $Friendly (winget: $WingetId)… (log: $LogFile)"
    try {
        winget install --id $WingetId --silent --accept-source-agreements --accept-package-agreements `
            *>> $LogFile
    } catch {
        Write-Warn "$Friendly install reported an error: $($_.Exception.Message)"
    }
    # Refresh PATH so a freshly-installed CLI resolves in this session.
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    if (Get-Command $Probe -ErrorAction SilentlyContinue) {
        Write-Ok "$Friendly installed."
        return $true
    }
    Write-Warn "$Friendly installed but not yet on PATH — a new shell or reboot may be required."
    return $false
}

# ── 1 · WSL2 (Docker Desktop's Linux engine) ───────────────────────────────
Write-Info "Checking WSL2…"
$wslOk = $false
try {
    & wsl --status *>> $LogFile
    if ($LASTEXITCODE -eq 0) { $wslOk = $true }
} catch { }
if ($wslOk) {
    Write-Ok "WSL is enabled."
} else {
    Write-Info "Enabling WSL2 (this may require a reboot)…"
    try { & wsl --install --no-distribution *>> $LogFile; Write-Ok "WSL2 enabled — REBOOT before launching Docker Desktop." }
    catch { Write-Warn "Could not auto-enable WSL2. Run 'wsl --install' in an elevated shell, then reboot." }
}

# ── 2 · Docker Desktop (docker + docker compose) ───────────────────────────
Write-Info "Checking Docker…"
$dockerOk = Ensure-Tool -Probe 'docker' -WingetId 'Docker.DockerDesktop' -Friendly 'Docker Desktop'
if ($dockerOk) {
    # `docker version` only succeeds once the engine is actually running.
    & docker version *>> $LogFile
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Docker engine is running."
        & docker compose version *>> $LogFile
        if ($LASTEXITCODE -eq 0) { Write-Ok "docker compose is available." }
        else { Write-Warn "docker compose plugin not detected — update Docker Desktop." }
    } else {
        Write-Warn "Docker is installed but the engine isn't running yet."
        Write-Warn "Launch Docker Desktop once, enable the WSL2 backend, then re-run this script."
    }
}

# ── 3 · Core CLIs (git, jq, curl) ──────────────────────────────────────────
Ensure-Tool -Probe 'git'  -WingetId 'Git.Git'           -Friendly 'Git'  | Out-Null
Ensure-Tool -Probe 'jq'   -WingetId 'jqlang.jq'         -Friendly 'jq'   | Out-Null
# curl ships with Windows 10/11 (curl.exe); only install if somehow missing.
if (Get-Command curl.exe -ErrorAction SilentlyContinue) { Write-Ok "curl is already installed." }
else { Ensure-Tool -Probe 'curl' -WingetId 'cURL.cURL' -Friendly 'curl' | Out-Null }

# ── 4 · Optional host CLIs (node, python, terraform) ───────────────────────
if (-not $SkipOptional) {
    Ensure-Tool -Probe 'node'      -WingetId 'OpenJS.NodeJS.LTS'       -Friendly 'Node.js LTS' | Out-Null
    Ensure-Tool -Probe 'python'    -WingetId 'Python.Python.3.12'      -Friendly 'Python 3.12' | Out-Null
    Ensure-Tool -Probe 'terraform' -WingetId 'Hashicorp.Terraform'     -Friendly 'Terraform'   | Out-Null
} else {
    Write-Info "-SkipOptional set — skipping node / python / terraform."
}

# ── 5 · Verify ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Info "Verifying prerequisites…"
$required = @('docker','git','jq')
$optional = @('node','python','terraform')
$allOk = $true

foreach ($c in $required) {
    if (Get-Command $c -ErrorAction SilentlyContinue) { Write-Ok "  $c" }
    else { Write-Err "  $c — MISSING (required)"; $allOk = $false }
}
if (-not $SkipOptional) {
    foreach ($c in $optional) {
        if (Get-Command $c -ErrorAction SilentlyContinue) { Write-Ok "  $c" }
        else { Write-Warn "  $c — not found (optional)" }
    }
}

Write-Host ""
if ($allOk) {
    Write-Ok "Host prerequisites verified."
    Write-Info "Next: launch Docker Desktop (WSL2 backend), then deploy the node — see README §'Deploy a node — Windows'."
} else {
    Write-Err "Some required prerequisites are missing. Review $LogFile and re-run after a reboot if WSL2/Docker were just installed."
    exit 1
}
