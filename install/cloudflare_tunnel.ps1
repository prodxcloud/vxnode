# =============================================================================
#  cloudflare_tunnel.ps1 — expose vxnode over HTTPS via a free Cloudflare
#                          Tunnel (Windows)
#
#  Windows equivalent of cloudflare_tunnel.sh. Installs cloudflared (winget,
#  with a direct-download fallback), authenticates to your Cloudflare account,
#  creates a named tunnel, points a hostname's DNS at it, and runs the tunnel —
#  in the foreground, or installed as a Windows service. Cloudflare terminates
#  TLS with a managed cert; no inbound ports need opening on the host.
#
#  Requires: a Cloudflare account with the target zone (e.g. vxcloud.io) added.
#
#  USAGE (PowerShell):
#    powershell -ExecutionPolicy Bypass -File .\cloudflare_tunnel.ps1
#    .\cloudflare_tunnel.ps1 -DnsHostname node1.example.com -Port 8744
#    .\cloudflare_tunnel.ps1 -AsService          # install as a Windows service (run elevated)
# =============================================================================
[CmdletBinding()]
param(
    [string] $TunnelName  = 'vxnode',
    [string] $DnsHostname = 'node1.vxcloud.io',   # public hostname for the node
    [int]    $Port        = 8744,                 # local vxnode API port
    [switch] $AsService                           # install/run as a Windows service
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$LocalUrl = "http://localhost:$Port"

function Write-Info { param($m) Write-Host "[cf-tunnel] $m"    -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[cf-tunnel] OK $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "[cf-tunnel] ! $m"  -ForegroundColor Yellow }

function Resolve-Cloudflared {
    $cmd = Get-Command cloudflared -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        "$env:ProgramFiles\cloudflared\cloudflared.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\cloudflared.exe"
    )) { if (Test-Path $p) { return $p } }
    return $null
}

# ── 1 · Install cloudflared ────────────────────────────────────────────────
$cf = Resolve-Cloudflared
if (-not $cf) {
    Write-Info "Installing cloudflared…"
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Cloudflare.cloudflared --silent --accept-source-agreements --accept-package-agreements
    } else {
        # winget unavailable — download the static exe into a stable per-machine path.
        $arch = if ([Environment]::Is64BitOperatingSystem) { 'amd64' } else { '386' }
        $dest = Join-Path $env:ProgramData 'cloudflared'
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $exe = Join-Path $dest 'cloudflared.exe'
        Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-$arch.exe" -OutFile $exe
        $env:Path = "$dest;$env:Path"
    }
    # Refresh PATH so the freshly-installed binary resolves in this session.
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    $cf = Resolve-Cloudflared
    if (-not $cf) { Write-Error "cloudflared install failed — install it manually and re-run."; exit 1 }
    Write-Ok "cloudflared installed: $(& $cf --version 2>$null | Select-Object -First 1)"
} else {
    Write-Ok "cloudflared already installed: $(& $cf --version 2>$null | Select-Object -First 1)"
}

# ── 2 · Authenticate (opens a browser; writes cert.pem) ────────────────────
$certPath = Join-Path $env:USERPROFILE '.cloudflared\cert.pem'
if (-not (Test-Path $certPath)) {
    Write-Info "Logging in to Cloudflare (a browser window will open)…"
    & $cf tunnel login
} else {
    Write-Ok "Already authenticated ($certPath present)."
}

# ── 3 · Create the named tunnel (idempotent) ───────────────────────────────
$existing = (& $cf tunnel list 2>$null) -match "\s$([regex]::Escape($TunnelName))\s"
if ($existing) {
    Write-Ok "Tunnel '$TunnelName' already exists."
} else {
    Write-Info "Creating tunnel '$TunnelName'…"
    & $cf tunnel create $TunnelName
}

# ── 4 · Route the hostname's DNS to the tunnel ─────────────────────────────
Write-Info "Routing DNS  $DnsHostname  ->  tunnel '$TunnelName'…"
try { & $cf tunnel route dns $TunnelName $DnsHostname }
catch { Write-Warn "DNS route may already exist (or the zone for $DnsHostname isn't in this account)." }

# ── 5 · Run the tunnel ─────────────────────────────────────────────────────
if ($AsService) {
    # Persist a config the Windows service reads, then install + start it.
    $cfgDir = Join-Path $env:USERPROFILE '.cloudflared'
    $line   = (& $cf tunnel list 2>$null | Select-String -Pattern "\s$([regex]::Escape($TunnelName))\s" | Select-Object -First 1)
    $tunnelId = if ($line) { ($line.ToString().Trim() -split '\s+')[0] } else { $null }
    if (-not $tunnelId) { Write-Error "Could not resolve tunnel ID for '$TunnelName'."; exit 1 }
    @"
tunnel: $tunnelId
credentials-file: $cfgDir\$tunnelId.json
ingress:
  - hostname: $DnsHostname
    service: $LocalUrl
  - service: http_status:404
"@ | Set-Content -Path (Join-Path $cfgDir 'config.yml') -Encoding UTF8

    Write-Info "Installing cloudflared as a Windows service (requires Administrator)…"
    & $cf service install
    Start-Service cloudflared -ErrorAction SilentlyContinue
    Write-Ok "Service running. Cloudflare now serves https://$DnsHostname"
    Write-Host "  status:  Get-Service cloudflared"
    Write-Host "  logs:    Get-Content `"$env:ProgramData\cloudflared\cloudflared.log`" -Tail 50 -Wait"
} else {
    Write-Ok "Starting tunnel in the foreground. Cloudflare will serve https://$DnsHostname"
    Write-Info "(Ctrl-C to stop; re-run with -AsService to keep it up across reboots.)"
    & $cf tunnel run --url $LocalUrl $TunnelName
}
