[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$Revision = "Arcade-SSV",
    [switch]$AsJson,
    [switch]$RequireReady
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$outputDir = Join-Path $ProjectRoot "output_files"

function Read-OptionalFile([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return Get-Content -LiteralPath $Path -Raw
    }
    return $null
}

function Match-Value([string]$Text, [string]$Pattern) {
    if (-not $Text) {
        return $null
    }
    $match = [regex]::Match($Text, $Pattern)
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return $null
}

$mapSummaryPath = Join-Path $outputDir "$Revision.map.summary"
$fitSummaryPath = Join-Path $outputDir "$Revision.fit.summary"
$staSummaryPath = Join-Path $outputDir "$Revision.sta.summary"
$staReportPath = Join-Path $outputDir "$Revision.sta.rpt"
$mapReportPath = Join-Path $outputDir "$Revision.map.rpt"
$fitReportPath = Join-Path $outputDir "$Revision.fit.rpt"
$rbfPath = Join-Path $outputDir "$Revision.rbf"
$qsfPath = Join-Path $ProjectRoot "$Revision.qsf"

$mapSummary = Read-OptionalFile $mapSummaryPath
$fitSummary = Read-OptionalFile $fitSummaryPath
$staSummary = Read-OptionalFile $staSummaryPath
$staReport = Read-OptionalFile $staReportPath
$mapReport = Read-OptionalFile $mapReportPath
$fitReport = Read-OptionalFile $fitReportPath
$qsf = Read-OptionalFile $qsfPath

$mapStatus = Match-Value $mapSummary '(?m)^Analysis & Synthesis Status\s*:\s*(.+)$'
$fitStatus = Match-Value $fitSummary '(?m)^Fitter Status\s*:\s*(.+)$'
$mapSuccessful = $mapStatus -like 'Successful*'
$fitSuccessful = $fitStatus -like 'Successful*'
$fitFinished = [bool]$fitStatus

# A successful status can still belong to an older netlist.  Require the
# chronological build chain to follow the newest synthesis input so an old
# fit/RBF can never qualify after RTL or project settings change.
$buildExtensions = @(
    '.qpf', '.qsf', '.qip', '.qsys', '.sdc', '.tcl',
    '.sv', '.svh', '.v', '.vh', '.vhd', '.vhdl',
    '.mif', '.hex', '.mem'
)
$buildInputs = @(
    Get-ChildItem -LiteralPath $ProjectRoot -File -ErrorAction SilentlyContinue
    foreach ($tree in @('rtl', 'sys')) {
        $treePath = Join-Path $ProjectRoot $tree
        if (Test-Path -LiteralPath $treePath -PathType Container) {
            Get-ChildItem -LiteralPath $treePath -Recurse -File -ErrorAction SilentlyContinue
        }
    }
) | Where-Object { $buildExtensions -contains $_.Extension.ToLowerInvariant() }
$newestBuildInput = $buildInputs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
$mapSummaryFile = Get-Item -LiteralPath $mapSummaryPath -ErrorAction SilentlyContinue
$fitSummaryFile = Get-Item -LiteralPath $fitSummaryPath -ErrorAction SilentlyContinue
$staSummaryFile = Get-Item -LiteralPath $staSummaryPath -ErrorAction SilentlyContinue
$fitCoversInputs = $fitSuccessful -and [bool]$fitSummaryFile -and
    (-not $newestBuildInput -or $fitSummaryFile.LastWriteTimeUtc -ge $newestBuildInput.LastWriteTimeUtc)
# A fitter-only seed change legitimately lets Quartus smart-recompile skip
# Analysis & Synthesis. In that case the older successful map is still the
# netlist consumed by a new fitter run. Accept it only when that successful fit
# is newer than every build input; an RTL/QSF edit after the fit still makes the
# complete result stale.
$mapIsCurrent = $mapSuccessful -and [bool]$mapSummaryFile -and
    ((-not $newestBuildInput -or $mapSummaryFile.LastWriteTimeUtc -ge $newestBuildInput.LastWriteTimeUtc) -or
     $fitCoversInputs)
$fitIsCurrent = $fitSuccessful -and $mapIsCurrent -and [bool]$fitSummaryFile -and
    $fitSummaryFile.LastWriteTimeUtc -ge $mapSummaryFile.LastWriteTimeUtc -and
    $fitCoversInputs
$staIsCurrent = $fitIsCurrent -and [bool]$staSummaryFile -and
    $staSummaryFile.LastWriteTimeUtc -ge $fitSummaryFile.LastWriteTimeUtc

$timingRows = @()
if ($staIsCurrent -and $staSummary) {
    $timingMatches = [regex]::Matches(
        $staSummary,
        "(?ms)^Type\s+:\s+(.+?)\r?\nSlack\s+:\s+(-?\d+(?:\.\d+)?)\r?\nTNS\s+:\s+(-?\d+(?:\.\d+)?)"
    )
    foreach ($match in $timingMatches) {
        $timingRows += [pscustomobject]@{
            Type = $match.Groups[1].Value.Trim()
            Slack = [double]::Parse(
                $match.Groups[2].Value,
                [Globalization.CultureInfo]::InvariantCulture
            )
            TNS = [double]::Parse(
                $match.Groups[3].Value,
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
    }
}

$worstTiming = $timingRows | Sort-Object Slack | Select-Object -First 1
$timingMet = $staIsCurrent -and $timingRows.Count -gt 0 -and
    $worstTiming.Slack -ge 0 -and
    -not ($timingRows | Where-Object { $_.TNS -lt 0 })
$unconstrainedClocks = Match-Value $staReport '; Unconstrained Clocks\s*;\s*(\d+)\s*;'
$constraintsMet = $staIsCurrent -and $unconstrainedClocks -eq '0'

$rbf = Get-Item -LiteralPath $rbfPath -ErrorAction SilentlyContinue
$rbfIsCurrent = $fitIsCurrent -and [bool]$rbf -and [bool]$fitSummaryFile -and
    $rbf.LastWriteTimeUtc -ge $fitSummaryFile.LastWriteTimeUtc

$routeAverage = Match-Value $fitReport 'Router estimated average interconnect usage is (\d+%)'
$routePeak = Match-Value $fitReport 'Router estimated peak interconnect usage is (\d+%)'
$routeRegionMatch = if ($fitReport) {
    [regex]::Match(
        $fitReport,
        'region that extends from location (\S+) to location (\S+)'
    )
}
$routeRegion = if ($routeRegionMatch.Success) {
    "$($routeRegionMatch.Groups[1].Value) to $($routeRegionMatch.Groups[2].Value)"
}
$congestionFailure = $fitReport -match 'routing phase terminated due to routing congestion'
# The cached renderer's 240x180 line-page metadata must stay in MLABs.  The
# previous inferred array carried an MLAB ramstyle request but Quartus placed
# it in five M10Ks; with only fourteen M10Ks free that is a release blocker.
# Read the fitter's typed RAM table rather than trusting RTL attributes.
$linePageStartsPlacement = Match-Value $fitReport '(?m)^;.*line_page_starts.*;\s*(MLAB|M10K block)\s*;'
$linePageStartsPlacementMet = $fitIsCurrent -and $linePageStartsPlacement -eq 'MLAB'

$ready = $mapIsCurrent -and $fitIsCurrent -and $staIsCurrent -and
    $timingMet -and $constraintsMet -and $rbfIsCurrent -and
    $linePageStartsPlacementMet
$result = [ordered]@{
    ProjectRoot = $ProjectRoot
    Revision = $Revision
    Seed = Match-Value $qsf '(?m)^set_global_assignment -name SEED\s+(\d+)\s*$'
    MapStatus = $mapStatus
    MapCurrent = $mapIsCurrent
    MapEstimatedALMs = Match-Value $mapReport '; Estimate of Logic utilization \(ALMs needed\)\s*;\s*(\d+)'
    MapCombinationalALUTs = Match-Value $mapReport '; Combinational ALUT usage for logic\s*;\s*(\d+)'
    MapDedicatedRegisters = Match-Value $mapReport '; Dedicated logic registers\s*;\s*(\d+)'
    FitStatus = $fitStatus
    FitCurrent = $fitIsCurrent
    LogicALMs = Match-Value $fitSummary '(?m)^Logic utilization \(in ALMs\)\s*:\s*(.+)$'
    Registers = Match-Value $fitSummary '(?m)^Total registers\s*:\s*(.+)$'
    BlockMemoryBits = Match-Value $fitSummary '(?m)^Total block memory bits\s*:\s*(.+)$'
    RAMBlocks = Match-Value $fitSummary '(?m)^Total RAM Blocks\s*:\s*(.+)$'
    DSPBlocks = Match-Value $fitSummary '(?m)^Total DSP Blocks\s*:\s*(.+)$'
    PLLs = Match-Value $fitSummary '(?m)^Total PLLs\s*:\s*(.+)$'
    RouteAverage = $routeAverage
    RoutePeak = $routePeak
    RoutePeakRegion = $routeRegion
    CongestionFailure = $congestionFailure
    LinePageStartsPlacement = $linePageStartsPlacement
    LinePageStartsPlacementMet = $linePageStartsPlacementMet
    WorstTimingType = if ($worstTiming) { $worstTiming.Type } else { $null }
    WorstSlackNs = if ($worstTiming) { $worstTiming.Slack } else { $null }
    WorstPathTNSNs = if ($worstTiming) { $worstTiming.TNS } else { $null }
    TimingMet = $timingMet
    TimingCurrent = $staIsCurrent
    UnconstrainedClocks = $unconstrainedClocks
    ConstraintsMet = $constraintsMet
    LatestBuildInput = if ($newestBuildInput) { $newestBuildInput.FullName } else { $null }
    RbfPath = if ($rbf) { $rbf.FullName } else { $null }
    RbfCurrent = $rbfIsCurrent
    ReadyToDeploy = $ready
}

if ($AsJson) {
    [pscustomobject]$result | ConvertTo-Json
}
else {
    Write-Host "Quartus result: seed $($result.Seed)"
    Write-Host "  Map:        $(if ($result.MapStatus) { $result.MapStatus } else { 'pending or not run' }); current=$mapIsCurrent"
    if ($result.MapEstimatedALMs) {
        Write-Host "  Map area:   $($result.MapEstimatedALMs) estimated ALMs; $($result.MapCombinationalALUTs) combinational ALUTs"
    }
    Write-Host "  Fit:        $(if ($result.FitStatus) { $result.FitStatus } else { 'pending or not run' }); current=$fitIsCurrent"
    if ($result.LogicALMs) {
        Write-Host "  Resources:  $($result.LogicALMs) ALMs; $($result.RAMBlocks) RAM blocks"
    }
    if ($routeAverage -or $routePeak) {
        Write-Host "  Routing:    average $routeAverage; peak $routePeak; $routeRegion"
    }
    Write-Host "  Placement:  line_page_starts=$linePageStartsPlacement; met=$linePageStartsPlacementMet"
    if ($staIsCurrent) {
        Write-Host "  Timing:     worst $($result.WorstSlackNs) ns; TNS $($result.WorstPathTNSNs) ns; met=$timingMet; current=True"
        Write-Host "  Constraints: unconstrained clocks $unconstrainedClocks; met=$constraintsMet"
    }
    else {
        Write-Host "  Timing:     pending or stale; current=False"
    }
    Write-Host "  RBF:        $(if ($rbf) { $rbf.FullName } else { 'missing' }); current=$rbfIsCurrent"
    Write-Host "  Deployable: $ready"
}

if ($RequireReady -and -not $ready) {
    exit 1
}

# Explicit success exit, so $LASTEXITCODE is meaningful to callers.
#
# Without this the script simply fell off the end, and PowerShell only sets
# $LASTEXITCODE for NATIVE executables -- so on success it kept whatever value
# was already there. Both callers test `if ($LASTEXITCODE -ne 0) { throw }`:
# tools/deploy-ssv.ps1 in a fresh session saw $null and refused to deploy a
# perfectly good RBF, while tools/build-ssv.ps1 only passed because quartus_sh
# had set 0 earlier in the same session. The latter is the dangerous half -- that
# gate would also have "passed" had this script exited 1.
exit 0
