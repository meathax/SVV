[CmdletBinding()]
param(
    [string]$QuartusRoot = "C:\intelFPGA_lite\17.1",
    [switch]$MapOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$quartusBin = Join-Path $QuartusRoot "quartus\bin64"
$project = "Arcade-SSV"

Push-Location $repoRoot
try {
    $map = Join-Path $quartusBin "quartus_map.exe"
    $flow = Join-Path $quartusBin "quartus_sh.exe"
    if (-not (Test-Path -LiteralPath $flow)) {
        throw "Quartus was not found below $QuartusRoot."
    }

    if ($MapOnly) {
        & $map --read_settings_files=on --write_settings_files=off $project -c $project
    }
    else {
        & $flow --flow compile $project
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Quartus failed. Inspect output_files\Arcade-SSV.*.rpt."
    }

    if (-not $MapOnly) {
        $source = Join-Path $repoRoot "output_files\Arcade-SSV.rbf"
        $releaseDir = Join-Path $repoRoot "releases"
        New-Item -ItemType Directory -Force $releaseDir | Out-Null
        Copy-Item -LiteralPath $source -Destination (Join-Path $releaseDir "SSV.rbf") -Force
        Write-Host "Built releases\SSV.rbf"
    }
}
finally {
    Pop-Location
}
