# Deploy releases\SSV.rbf to a MiSTer and optionally load the core.
#
# Requires SSH key auth to the MiSTer (no password handling here by design).
# The previous core is always preserved before it is replaced, and the upload
# is staged and hash-verified before it is swapped in, so a truncated transfer
# can never leave a half-written RBF in place.
[CmdletBinding()]
param(
    [string]$MisterHost = "192.168.0.69",
    [string]$Rbf        = "releases\SSV.rbf",
    [string]$CoreName   = "SSV",
    [string]$Mra        = "/media/fat/_Arcade/Dyna Gear.mra",
    [switch]$Boot
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    if (-not (Test-Path -LiteralPath $Rbf)) { throw "RBF not found: $Rbf" }

    $localMd5 = (Get-FileHash -LiteralPath $Rbf -Algorithm MD5).Hash.ToLower()
    $size     = (Get-Item -LiteralPath $Rbf).Length
    Write-Host "local  $Rbf  $size bytes  md5 $localMd5"

    $dest    = "/media/fat/_Arcade/cores/$CoreName.rbf"
    $staging = "$dest.new"
    $ssh     = @("-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new")

    # Preserve whatever is currently installed, tagged with its own mtime.
    $backupCmd = @"
if [ -f '$dest' ]; then
  stamp=`$(date -r '$dest' +%Y%m%d_%H%M%S)
  cp -a '$dest' '/media/fat/_Arcade/cores/${CoreName}_backup_'`$stamp'.rbf'
  echo "backed up to ${CoreName}_backup_`$stamp.rbf (md5 `$(md5sum '$dest' | cut -d' ' -f1))"
else
  echo 'no existing core to back up'
fi
"@
    & ssh @ssh "root@$MisterHost" $backupCmd
    if ($LASTEXITCODE -ne 0) { throw "backup step failed" }

    & scp @ssh $Rbf "root@${MisterHost}:$staging"
    if ($LASTEXITCODE -ne 0) { throw "scp failed" }

    $remoteMd5 = (& ssh @ssh "root@$MisterHost" "md5sum '$staging' | cut -d' ' -f1").Trim()
    if ($remoteMd5 -ne $localMd5) {
        & ssh @ssh "root@$MisterHost" "rm -f '$staging'"
        throw "hash mismatch after transfer: local $localMd5, remote $remoteMd5"
    }
    Write-Host "verified remote md5 $remoteMd5"

    & ssh @ssh "root@$MisterHost" "mv '$staging' '$dest' && sync && ls -la '$dest'"
    if ($LASTEXITCODE -ne 0) { throw "swap failed" }

    if ($Boot) {
        Write-Host "loading $Mra"
        & ssh @ssh "root@$MisterHost" "echo 'load_core $Mra' > /dev/MiSTer_cmd"
        Start-Sleep -Seconds 12
        $core = (& ssh @ssh "root@$MisterHost" "cat /tmp/CORENAME 2>/dev/null").Trim()
        Write-Host "CORENAME after load: $core"
    }
    else {
        Write-Host "not booting (pass -Boot to load the core)"
    }
}
finally {
    Pop-Location
}
