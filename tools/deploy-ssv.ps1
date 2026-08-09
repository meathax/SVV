[CmdletBinding()]
param(
    [string]$MisterHost = "root@192.168.0.69",
    [string]$RbfPath,
    [string]$MraPath,
    [switch]$SkipReadyCheck
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $RbfPath) { $RbfPath = Join-Path $repoRoot "releases\Arcade-SSV.rbf" }
if (-not $MraPath) { $MraPath = Join-Path $repoRoot "releases\Dyna Gear.mra" }

if (-not $SkipReadyCheck) {
    & (Join-Path $PSScriptRoot "report-quartus.ps1") -Revision "Arcade-SSV" -RequireReady
    if ($LASTEXITCODE -ne 0) {
        throw "Quartus readiness check failed; refusing to deploy. Pass -SkipReadyCheck to override."
    }
}

$rbf = (Resolve-Path -LiteralPath $RbfPath).Path
$mra = (Resolve-Path -LiteralPath $MraPath).Path
$rbfHash = (Get-FileHash -LiteralPath $rbf -Algorithm SHA256).Hash.ToLowerInvariant()
$mraHash = (Get-FileHash -LiteralPath $mra -Algorithm SHA256).Hash.ToLowerInvariant()
$sshOptions = @("-o", "ConnectTimeout=10")

$remoteCore = "/media/fat/_Arcade/cores/Arcade-SSV.rbf"
$remoteMra = "/media/fat/_Arcade/Dyna Gear.mra"

& ssh @sshOptions $MisterHost "mkdir -p /media/fat/_Arcade/cores"
if ($LASTEXITCODE -ne 0) { throw "MiSTer connection failed." }

& scp @sshOptions $rbf "${MisterHost}:${remoteCore}.upload"
if ($LASTEXITCODE -ne 0) { throw "RBF upload failed." }
& scp @sshOptions $mra "${MisterHost}:${remoteMra}.upload"
if ($LASTEXITCODE -ne 0) { throw "MRA upload failed." }

$remoteRbfHash = ((& ssh @sshOptions $MisterHost "sha256sum '${remoteCore}.upload'") -split "\s+")[0]
$remoteMraHash = ((& ssh @sshOptions $MisterHost "sha256sum '${remoteMra}.upload'") -split "\s+")[0]
if ($remoteRbfHash -ne $rbfHash) { throw "RBF hash mismatch after upload." }
if ($remoteMraHash -ne $mraHash) { throw "MRA hash mismatch after upload." }

& ssh @sshOptions $MisterHost "mv -f '${remoteCore}.upload' '$remoteCore' && mv -f '${remoteMra}.upload' '$remoteMra' && sync"
if ($LASTEXITCODE -ne 0) { throw "Could not activate uploaded files." }
Write-Host "Deployed Arcade-SSV.rbf and Dyna Gear.mra to $MisterHost"
Write-Host "RBF SHA-256: $rbfHash"
Write-Host "MRA SHA-256: $mraHash"
