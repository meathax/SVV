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
    # Fast Fit is pinned because Standard Fit CRASHES quartus_fit on this
    # install (Error 293007, peak virtual memory 4649 MB, with 35 GB of host
    # RAM free) - see the note in Arcade-SSV.qsf. It is a toolchain ceiling,
    # not a preference. The pll_hdmi domain is consequently seed-sensitive
    # (+0.392 / +0.119 / -0.141 ns across three compiles); sweep SEED rather
    # than raising fitter effort.
    $required = @(
        'set_global_assignment -name FITTER_EFFORT "FAST FIT"',
        'set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL NORMAL',
        'set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC OFF',
        'set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF',
        'set_global_assignment -name SMART_RECOMPILE ON',
        'set_global_assignment -name SAVE_DISK_SPACE OFF',
        # Compressed bitstreams are a hard MiSTer/DE10-nano requirement, not
        # a preference: the HPS configuration path only accepts compressed
        # Cyclone V bitstreams. COMPRESSION_MODE OFF was added incidentally
        # in commit 5eb1f5b (an unrelated fitter-tuning pass, no rationale
        # given) and briefly enforced here as if it were required; an
        # uncompressed RBF assembles and passes every report, then silently
        # fails to configure the FPGA on real hardware (GPI[31]==1, dead
        # core, no signal). Fixed 2026-08-05.
        'set_global_assignment -name COMPRESSION_MODE ON'
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

    # Concurrency guard, counted by PROJECT rather than by process.
    #
    # One build spawns several quartus executables (quartus_sh plus quartus_map
    # or quartus_fit), so counting processes counts builds several times over.
    # The old check refused whenever any quartus process existed anywhere on the
    # machine, which meant an unrelated project compiling blocked this one -- on
    # 29 Jul 2026 that cost four separate SSV builds their slot.
    #
    # Two concurrent builds are fine on this hardware: a single-processor fit
    # uses about 2-3.5 GB and one core of 24. What is NOT fine is two builds on
    # the SAME project, which corrupts the shared compilation database, so that
    # case is always refused regardless of the limit.
    $maxConcurrentBuilds = 2

    $running = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'quartus%'" -ErrorAction SilentlyContinue)
    $projects = @($running | ForEach-Object {
        # Project name is the -c argument, else the first NON-FLAG argument
        # after the executable.
        #
        # It is NOT "the last bare token". quartus_map is invoked as
        #   quartus_map.exe "Arcade-SegaModel1" --read_settings_files=on --write_settings_files=off
        # with the project FIRST, so a trailing-token match returns "off" --
        # observed 31 Jul 2026, where a real second build reported as project
        # "off". The count happened to be right that time, but two different
        # projects both ending in "=off" collapse to ONE entry and let a THIRD
        # build start. That is precisely the case this cap exists to prevent, so
        # the parser must name the project correctly, not merely often.
        if ($_.CommandLine -match '-c\s+"?([A-Za-z0-9_.\-]+)"?') { $Matches[1] }
        else {
            # Drop the executable, then keep arguments that are neither flags
            # (-x / --x) nor key=value settings. The project is the last such
            # token, which is correct for all three observed invocations:
            #   quartus_sh.exe --flow compile Apache3          -> Apache3
            #   quartus_map.exe "Proj" --read_settings_files=on -> Proj
            #   quartus_fit.exe ...=off "Proj" -c Proj         -> (-c wins)
            # @() is required: with a single match the pipeline yields a STRING,
            # and $toks[-1] then indexes its last CHARACTER -- "Arcade-SegaModel1"
            # parses as the project "1", which collapses distinct projects and
            # under-counts. Observed 31 Jul 2026 while fixing the trailing-token
            # bug above.
            $toks = @(($_.CommandLine -split '\s+') | Select-Object -Skip 1 |
                      ForEach-Object { $_.Trim('"') } |
                      Where-Object { $_ -and $_ -notmatch '^-' -and $_ -notmatch '=' })
            if ($toks.Count) { $toks[-1] }
        }
    } | Where-Object { $_ } | Sort-Object -Unique)

    if ($projects -contains $project) {
        throw "This project ($project) is already being compiled. Two builds sharing one compilation database will corrupt it."
    }
    if ($projects.Count -ge $maxConcurrentBuilds) {
        throw "$($projects.Count) builds already running ($($projects -join ', ')); limit is $maxConcurrentBuilds. Wait for one to finish."
    }
    if ($projects.Count -gt 0) {
        Write-Host "note: building alongside $($projects -join ', ')"
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
        $releaseName = "SSV_{0}.rbf" -f (Get-Date -Format "yyyyMMdd")
        $destination = Join-Path $releaseDir $releaseName
        $staging = "$destination.upload"
        Copy-Item -LiteralPath $source -Destination $staging -Force
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $stagingHash = (Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash
        if ($sourceHash -ne $stagingHash) {
            throw 'Staged RBF hash does not match the Quartus output.'
        }
        Move-Item -LiteralPath $staging -Destination $destination -Force
        Write-Host "Built releases\$releaseName (SHA256 $sourceHash)"
    }
}
finally {
    Pop-Location
}
