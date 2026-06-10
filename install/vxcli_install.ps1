# =============================================================================
#  vxcli_install.ps1 — install the vxcloud CLI (vxcli) on Windows
#
#  Windows equivalent of vxcli_install.sh. Runs the official PowerShell
#  installer, which downloads the prebuilt vxcli binary (amd64/arm64) and puts
#  it on your PATH. Three aliases are installed: vxcli, vx, vxcloud.
#
#  Docs:  https://vxcloud.io/pages/web/self-hosted/   ·   https://vxcloud.io/download/cli
#
#  USAGE (PowerShell):
#    powershell -ExecutionPolicy Bypass -File .\vxcli_install.ps1
#    # or the upstream one-liner:
#    irm https://vxcloud.io/download/cli/install.ps1 | iex
#
#  Verify:  vxcli version
# =============================================================================
[CmdletBinding()]
param(
    [string] $InstallerUrl = $(if ($env:VXCLI_INSTALLER_URL) { $env:VXCLI_INSTALLER_URL } else { 'https://vxcloud.io/download/cli/install.ps1' })
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # suppress the IWR progress bar

function Write-Info { param($m) Write-Host "[vxcli] $m"            -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[vxcli] OK $m"         -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[vxcli] ! $m"          -ForegroundColor Yellow }

# ── Already installed? ─────────────────────────────────────────────────────
$existing = Get-Command vxcli -ErrorAction SilentlyContinue
if ($existing) {
    $ver = (& vxcli version 2>$null | Select-Object -First 1)
    Write-Ok "vxcli already installed: $ver"
    Write-Info "Re-running the installer to pick up any newer build…"
}

# ── Run the upstream PowerShell installer ──────────────────────────────────
Write-Info "Installing vxcli from $InstallerUrl …"
try {
    $script = Invoke-RestMethod -Uri $InstallerUrl -TimeoutSec 60
    Invoke-Expression $script
} catch {
    Write-Error "vxcli install failed: $($_.Exception.Message)"
    exit 1
}

# ── Refresh PATH for THIS session ──────────────────────────────────────────
# The installer updates the persisted (User/Machine) PATH, but the current
# process keeps its old copy. Rebuild $env:Path so `vxcli` resolves right away.
$env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [System.Environment]::GetEnvironmentVariable('Path', 'User')

# Common per-user install locations the upstream installer may use, in case
# they were not yet appended to the persisted PATH.
$candidateDirs = @(
    (Join-Path $env:LOCALAPPDATA 'vxcloud\bin'),
    (Join-Path $env:USERPROFILE  '.local\bin'),
    (Join-Path $env:USERPROFILE  '.vxcloud\bin')
)
foreach ($d in $candidateDirs) {
    if ((Test-Path $d) -and ($env:Path -notlike "*$d*")) { $env:Path = "$d;$env:Path" }
}

# ── Verify ─────────────────────────────────────────────────────────────────
$cmd = Get-Command vxcli -ErrorAction SilentlyContinue
if ($cmd) {
    $ver = (& vxcli version 2>$null | Select-Object -First 1)
    if (-not $ver) { $ver = 'vxcli (version output empty)' }
    Write-Ok "Installed: $ver"
    Write-Host "  Path:    $($cmd.Source)"
    Write-Host "  Aliases: vxcli · vx · vxcloud"
    Write-Host "  Next:    vxcli login   then   vxcli node list"
} else {
    Write-Warn "vxcli was installed but is not on PATH in this session."
    Write-Warn "Open a NEW PowerShell window and run:  vxcli version"
    exit 1
}
