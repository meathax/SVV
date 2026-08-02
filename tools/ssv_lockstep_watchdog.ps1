param(
    [Parameter(Mandatory=$true)][int]$LauncherPid,
    [Parameter(Mandatory=$true)][int]$RtlPid,
    [Parameter(Mandatory=$true)][long]$RtlStartTicks,
    [Parameter(Mandatory=$true)][string]$RtlExecutable,
    [Parameter(Mandatory=$true)][int]$MamePid,
    [Parameter(Mandatory=$true)][long]$MameStartTicks,
    [Parameter(Mandatory=$true)][string]$Session
)

$ErrorActionPreference = 'SilentlyContinue'

function Stop-OwnedProcess([int]$ProcessId, [long]$StartTicks) {
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    $same = $false
    try { $same = $process.StartTime.ToUniversalTime().Ticks -eq $StartTicks } catch {}
    if (-not $same) { return $false }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    return $true
}

function Stop-OwnedRtlTree([int]$WrapperPid, [long]$WrapperStartTicks,
                          [string]$Executable) {
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$WrapperPid" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Executable) }
    foreach ($child in $children) {
        Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
    }
    return Stop-OwnedProcess -ProcessId $WrapperPid -StartTicks $WrapperStartTicks
}

$cleanup = Join-Path $Session 'cleanup.json'
while ((Get-Process -Id $LauncherPid -ErrorAction SilentlyContinue) -and
       -not (Test-Path -LiteralPath $cleanup)) {
    Start-Sleep -Milliseconds 500
}

if (Test-Path -LiteralPath $cleanup) { exit 0 }

New-Item -ItemType Directory -Force -Path $Session | Out-Null
Set-Content -LiteralPath (Join-Path $Session 'STOP.txt') -Value 'launcher exited unexpectedly'
$rtlStopped = Stop-OwnedRtlTree -WrapperPid $RtlPid `
    -WrapperStartTicks $RtlStartTicks -Executable $RtlExecutable
$mameStopped = Stop-OwnedProcess -ProcessId $MamePid -StartTicks $MameStartTicks
@{
    schema = 'ssv-lockstep-cleanup-v1'
    reason = 'watchdog detected launcher exit'
    rtl_forced = $rtlStopped
    mame_forced = $mameStopped
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath $cleanup
