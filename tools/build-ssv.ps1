[CmdletBinding()]
param(
    [string]$QuartusRoot = "C:\intelFPGA_lite\17.1",
    [switch]$MapOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$quartusBin = Join-Path $QuartusRoot "quartus\bin64"
$project = "Arcade-SSV"
$qsfPath = Join-Path $repoRoot "$project.qsf"

function Assert-BuildPolicy {
    $qsf = Get-Content -LiteralPath $qsfPath -Raw
    $required = @(
        'set_global_assignment -name FITTER_EFFORT "FAST FIT"',
        'set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL NORMAL',
        'set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC OFF',
        'set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF',
        'set_global_assignment -name SMART_RECOMPILE ON',
        'set_global_assignment -name SAVE_DISK_SPACE OFF',
        'set_global_assignment -name COMPRESSION_MODE OFF'
    )
    foreach ($assignment in $required) {
        if (-not $qsf.Contains($assignment)) {
            throw "Required Quartus policy assignment is missing: $assignment"
        }
    }

    $processorMatch = [regex]::Match(
        $qsf,
        '(?m)^set_global_assignment -name NUM_PARALLEL_PROCESSORS\s+(\d+)\s*$'
    )
    if (-not $processorMatch.Success -or
        [int]$processorMatch.Groups[1].Value -gt 6) {
        throw 'NUM_PARALLEL_PROCESSORS must be explicitly set to 1..6.'
    }
}

Push-Location $repoRoot
try {
    Assert-BuildPolicy

    $activeQuartus = Get-Process -Name 'quartus*' -ErrorAction SilentlyContinue
    if ($activeQuartus) {
        $activeList = ($activeQuartus | ForEach-Object {
            "$($_.ProcessName)[$($_.Id)]"
        }) -join ', '
        throw "Another Quartus process is active: $activeList"
    }

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
        $readiness = Join-Path $PSScriptRoot "report-quartus.ps1"
        & $readiness -ProjectRoot $repoRoot -Revision $project -RequireReady
        if ($LASTEXITCODE -ne 0) {
            throw 'Quartus completed, but readiness/timing checks rejected the RBF.'
        }

        $reportJson = & $readiness -ProjectRoot $repoRoot -Revision $project -AsJson
        $report = $reportJson | ConvertFrom-Json
        function Get-UsedResource([string]$Value) {
            $match = [regex]::Match($Value, '^\s*([\d,]+)')
            if (-not $match.Success) {
                throw "Could not parse Quartus resource value: $Value"
            }
            return [int]$match.Groups[1].Value.Replace(',', '')
        }
        $usedAlms = Get-UsedResource $report.LogicALMs
        $usedRamBlocks = Get-UsedResource $report.RAMBlocks
        $usedDsps = Get-UsedResource $report.DSPBlocks
        if ($usedAlms -gt 38500) {
            throw "ALM ceiling exceeded: $usedAlms > 38500."
        }
        if ($usedRamBlocks -gt 544) {
            throw "RAM-block ceiling exceeded: $usedRamBlocks > 544."
        }
        if ($usedDsps -gt 59) {
            throw "DSP ceiling exceeded: $usedDsps > 59."
        }

        $source = Join-Path $repoRoot "output_files\Arcade-SSV.rbf"
        $releaseDir = Join-Path $repoRoot "releases"
        New-Item -ItemType Directory -Force $releaseDir | Out-Null
        $destination = Join-Path $releaseDir "SSV.rbf"
        $staging = "$destination.upload"
        Copy-Item -LiteralPath $source -Destination $staging -Force
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $stagingHash = (Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash
        if ($sourceHash -ne $stagingHash) {
            throw 'Staged RBF hash does not match the Quartus output.'
        }
        Move-Item -LiteralPath $staging -Destination $destination -Force
        Write-Host "Built releases\SSV.rbf (SHA256 $sourceHash)"
    }
}
finally {
    Pop-Location
}
