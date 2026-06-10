# =============================================================================
#  tailnet_funnel.ps1 — expose vxnode publicly over HTTPS via Tailscale Funnel
#                       (Windows)
#
#  Windows equivalent of tailnet_funnel.sh. Installs Tailscale (winget, with an
#  MSI-download fallback), joins your tailnet, and turns on Funnel so the local
#  vxnode API is reachable on the public internet over HTTPS (Tailscale
#  auto-issues the TLS cert). No DNS record or Cloudflare account needed —
#  Tailscale gives you a `*.ts.net` hostname to register the node with.
#
#  Prereq: in the Tailscale admin console, enable HTTPS certificates and the
#  Funnel node attribute for this machine (https://tailscale.com/kb/1223/funnel).
#
#  USAGE (PowerShell as Administrator):
#    powershell -ExecutionPolicy Bypass -File .\tailnet_funnel.ps1
#    .\tailnet_funnel.ps1 -Port 8744
#    $env:TS_AUTHKEY='tskey-auth-…'; .\tailnet_funnel.ps1   # unattended join
# =============================================================================
[CmdletBinding()]
param(
    [int]    $Port    = 8744,                                  # local vxnode API port
    [string] $AuthKey = $env:TS_AUTHKEY                        # optional: unattended join
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Write-Info { param($m) Write-Host "[tailnet] $m"    -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[tailnet] OK $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[tailnet] ! $m"  -ForegroundColor Yellow }

function Resolve-Tailscale {
    $cmd = Get-Command tailscale -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = "$env:ProgramFiles\Tailscale\tailscale.exe"
    if (Test-Path $p) { return $p }
    return $null
}

# ── 1 · Install Tailscale ──────────────────────────────────────────────────
$ts = Resolve-Tailscale
if (-not $ts) {
    Write-Info "Installing Tailscale…"
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id tailscale.tailscale --silent --accept-source-agreements --accept-package-agreements
    } else {
        # winget unavailable — download and run the official MSI silently.
        $msi = Join-Path $env:TEMP 'tailscale-setup.exe'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe' -OutFile $msi
        Start-Process -FilePath $msi -ArgumentList '/quiet' -Wait
    }
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    $ts = Resolve-Tailscale
    if (-not $ts) { Write-Error "Tailscale install failed — install it manually and re-run."; exit 1 }
    Write-Ok "Tailscale installed: $(& $ts version 2>$null | Select-Object -First 1)"
} else {
    Write-Ok "Tailscale already installed: $(& $ts version 2>$null | Select-Object -First 1)"
}

# ── 2 · Bring the node onto your tailnet ───────────────────────────────────
$loggedIn = $false
try { & $ts status *>$null; if ($LASTEXITCODE -eq 0) { $loggedIn = $true } } catch { }
if ($loggedIn) {
    Write-Ok "Already logged in to a tailnet."
} else {
    Write-Info "Joining your tailnet…"
    if ($AuthKey) {
        & $ts up --authkey $AuthKey
    } else {
        Write-Info "(a browser window will open — authenticate to join)"
        & $ts up
    }
}

# ── 3 · Expose the vxnode API publicly with Funnel (HTTPS auto-issued) ─────
Write-Info "Enabling Tailscale Funnel on port $Port…"
& $ts funnel --bg $Port

# ── 4 · Report the public hostname to register with vxcloud ────────────────
$fqdn = $null
try {
    $st = & $ts status --json 2>$null | ConvertFrom-Json
    if ($st.Self.DNSName) { $fqdn = $st.Self.DNSName.TrimEnd('.') }
} catch { }
Write-Host ""
if ($fqdn) {
    Write-Ok "vxnode is now public at:  https://$fqdn"
} else {
    Write-Ok "Funnel is on. Tailscale printed your public hostname above."
}
Write-Info "  e.g.  https://node1.<your-tailnet>.ts.net"
Write-Info "Use that hostname when registering the node with vxcloud (app.vxcloud.io)."
Write-Info "Check / turn off:   tailscale funnel status   ·   tailscale funnel --$Port off"
