# =============================================================================
#  install-updater.ps1 — enable vxnode fleet auto-update on a Windows host
#
#  Windows equivalent of update/install-updater.sh. Copies vxnode-update.ps1
#  into the deploy directory and registers a Scheduled Task that fires
#  every 5 minutes (matching the in-binary listener's poll cadence).
#
#  Run ONCE per host AFTER the node container is up (see README §8). Must
#  be elevated (Administrator) because the task runs under SYSTEM and
#  touches %ProgramData%.
#
#  USAGE (PowerShell as Administrator):
#
#    # First time on a fresh box — ExecutionPolicy may block .ps1 files:
#    powershell -ExecutionPolicy Bypass -File .\install-updater.ps1
#
#    # Canary channel (one host only — test new digests before fleet rollout):
#    powershell -ExecutionPolicy Bypass -File .\install-updater.ps1 `
#               -ChannelUrl https://vxcloud.io/download/vxnode/canary.json
#
#    # Uninstall (stop polling and remove the task):
#    powershell -ExecutionPolicy Bypass -File .\install-updater.ps1 -Uninstall
# =============================================================================

[CmdletBinding()]
param(
    [string] $DeployDir  = (Join-Path $env:ProgramData 'vxcloud'),
    [string] $ChannelUrl = 'https://vxcloud.io/download/vxnode/stable.json',
    [string] $TaskName   = 'vxnode-update',
    [int]    $EveryMins  = 5,
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

# ── Must be elevated ──────────────────────────────────────────────────────
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Must be run as Administrator. Right-click PowerShell -> Run as administrator."
    exit 1
}

# ── Uninstall branch ──────────────────────────────────────────────────────
if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "✓ Removed scheduled task '$TaskName'"
    } else {
        Write-Host "task '$TaskName' was not registered — nothing to remove"
    }
    return
}

# ── Stage vxnode-update.ps1 into the deploy directory ─────────────────────
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcPs1 = Join-Path $here 'vxnode-update.ps1'
if (-not (Test-Path $srcPs1)) {
    Write-Error "vxnode-update.ps1 not found next to this installer (expected $srcPs1)"
    exit 1
}

New-Item -ItemType Directory -Force -Path $DeployDir, (Join-Path $DeployDir 'update'), (Join-Path $DeployDir 'generated') | Out-Null
$dstPs1 = Join-Path $DeployDir 'update\vxnode-update.ps1'
Copy-Item -Force -Path $srcPs1 -Destination $dstPs1
Write-Host "✓ Installed updater: $dstPs1"

# ── Register the scheduled task ───────────────────────────────────────────
# Action: invoke powershell.exe with -ExecutionPolicy Bypass so the task
# runs even when AllSigned/Restricted is the default policy. -NoProfile keeps
# startup fast and predictable (no $PROFILE side effects).
$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dstPs1`"" `
    -WorkingDirectory $DeployDir

# Two triggers, matching the systemd unit on Linux:
#  1) at boot, after a 2-min grace so Docker Desktop has time to come up
#  2) every $EveryMins indefinitely (clamped to 1..1440)
if ($EveryMins -lt 1)    { $EveryMins = 1 }
if ($EveryMins -gt 1440) { $EveryMins = 1440 }

$tBoot  = New-ScheduledTaskTrigger -AtStartup
$tBoot.Delay = "PT2M"
$tRecur = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
            -RepetitionInterval (New-TimeSpan -Minutes $EveryMins) `
            -RepetitionDuration ([TimeSpan]::MaxValue)

# Run as SYSTEM so the task doesn't depend on an interactive user being
# logged in. SYSTEM has access to Docker Desktop's pipe by default.
$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

# Settings: allow start on battery, don't kill mid-pull, retry on network
# transients. ExecutionTimeLimit caps a stuck pull from running forever.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# Carry the channel URL as a task-scoped env var so the user can flip stable
# <-> canary without editing the .ps1.
$task = New-ScheduledTask -Action $action -Trigger @($tBoot, $tRecur) -Principal $principal -Settings $settings `
    -Description "vxnode self-update (poll $ChannelUrl every $EveryMins min, health-gated swap with rollback)"

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Register-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null

# Setting Environment on a registered task requires the COM-based interface;
# the cmdlet doesn't expose it. We poke it through schtasks via /TR not being
# enough, so set CHANNEL_URL by editing the registered task's XML envvars.
# Simpler path: drop a small wrapper that exports the var, but that adds a
# file. Instead, set CHANNEL_URL system-wide if it isn't already set — the
# updater reads $env:CHANNEL_URL on every run.
if (-not [Environment]::GetEnvironmentVariable('CHANNEL_URL', 'Machine')) {
    [Environment]::SetEnvironmentVariable('CHANNEL_URL', $ChannelUrl, 'Machine')
    Write-Host "✓ CHANNEL_URL=$ChannelUrl set (machine env var)"
}

Write-Host ""
Write-Host "✓ vxnode-update scheduled task registered — next run in ~2min, then every $EveryMins min"
Write-Host "  logs:    Get-Content '$($DeployDir)\update\vxnode-update.log' -Tail 50 -Wait"
Write-Host "  manual:  Start-ScheduledTask -TaskName $TaskName"
Write-Host "  status:  Get-ScheduledTaskInfo -TaskName $TaskName"
Write-Host "  remove:  .\install-updater.ps1 -Uninstall"
