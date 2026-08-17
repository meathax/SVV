param(
    [Parameter(Mandatory=$true)][string]$Set,
    [Parameter(Mandatory=$true)][string]$Session,
    [string]$ModelDir = '',
    [int]$Frames = 360,
    [UInt64]$Cycles = 0,
    [string]$Scenario = 'attract_idle',
    [string]$ScenarioFile = '',
    [string]$InputJournal = '',
    [UInt64]$TraceStartCycle = 0,
    [UInt64]$TraceStopCycle = 0,
    [UInt64]$TraceMaxEvents = 0,
    [switch]$RegisterChangeTrace,
    [switch]$DiagnosticNoAttract,
    [switch]$DumpFrameDiag,
    [switch]$AssertIrqCadence,
    [switch]$IgnoreNonblack,
    [switch]$StrictOnly,
    [switch]$NoStateCrc,
    [switch]$Acceleration,
    [string]$Restore = '',
    [UInt64]$SaveCycle = 0,
    [string]$CheckpointControl = '',
    [switch]$LockoutTrace,
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$safeSim = 'D:\vibes\fpga\bin\verilator-sim-safe.exe'
if (-not $ModelDir) {
    $workspace = $env:VERILATOR_WORKSPACE
    if (-not $workspace) {
        $safeVerilator = 'D:\vibes\fpga\bin\verilator-safe.exe'
        $workspace = (& $safeVerilator workspace).Trim()
    }
    $ModelDir = Join-Path $workspace $(if ($Acceleration) { 'obj_headless_save' } else { 'obj_headless' })
}
$sessionPath = [System.IO.Path]::GetFullPath($Session)
$generatedRoot = [System.IO.Path]::GetFullPath((Join-Path $project 'sim_output'))
if (-not $sessionPath.StartsWith($generatedRoot + [System.IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Session must remain below the gitignored sim_output directory'
}
$supported = & python -c "import sys;sys.path.insert(0,'tools');from ssv_supported_sets import SUPPORTED_SETS;print('1' if '$Set' in SUPPORTED_SETS else '0')"
if ($supported.Trim() -ne '1') { throw "Unsupported SSV set: $Set" }
if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build_ssv_headless.ps1') -ModelDir $ModelDir -Savable:$Acceleration
}
$exe = & (Join-Path $PSScriptRoot 'build_ssv_headless.ps1') -ModelDir $ModelDir -Savable:$Acceleration -PrintExecutable
if (-not (Test-Path -LiteralPath $exe)) { throw "Missing headless model: $exe" }

$meta = & python -c "import sys,xml.etree.ElementTree as E;from pathlib import Path;sys.path.insert(0,'tools');from ssv_supported_sets import SUPPORTED_SET_IDS;p=next(p for p in Path('releases').glob('*.mra') if E.parse(p).getroot().findtext('setname')=='$Set');r=E.parse(p).getroot();d=bytes.fromhex((next(n for n in r.findall('rom') if n.get('index')=='1').find('part').text or '').strip());assert len(d)==24 and d[:2]==b'S\x03' and sum(d)%256==0,'release descriptor must be checksum-valid v3';dip=r.find('switches').get('default','FF,FF');a=[int(x,16) for x in dip.split(',')];assert len(a)==2 and all(0<=x<=255 for x in a),'MRA switches default must contain two bytes';print(SUPPORTED_SET_IDS['$Set'],d[13]*2,d[14],a[0],a[1])"
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve authoritative descriptor metadata' }
$gameId, $width, $height, $dsw1Value, $dsw2Value = ($meta -split '\s+')
$dsw1Hex = '{0:X2}' -f [int]$dsw1Value
$dsw2Hex = '{0:X2}' -f [int]$dsw2Value
$imageDir = Join-Path $project "sim_output\rom\$Set"
$main = Join-Path $imageDir 'maincpu.bin'
$sprites = Join-Path $imageDir 'sprites.bin'
$samples = Join-Path $imageDir 'samples.bin'
foreach ($image in @($main, $sprites, $samples)) {
    if (-not (Test-Path -LiteralPath $image)) { throw "Missing private simulation image: $image" }
}
New-Item -ItemType Directory -Force -Path $sessionPath | Out-Null
$arguments = @(
    "+GAME_ID=$gameId", "+MAINROM=$main", "+SPRROM=$sprites", "+SMPROM=$samples",
    "+DSW1=$dsw1Hex", "+DSW2=$dsw2Hex",
    "+SCENARIO=$Scenario", "+FRAMES=$Frames", "+SOAK_FRAMES=$Frames",
    "+FRAME_CRC=$(Join-Path $sessionPath 'rtl-frame.jsonl')",
    "+MISTER_TRACE_OUT=$(Join-Path $sessionPath 'rtl-trace.jsonl')",
    "+HEADLESS_PPM=$(Join-Path $sessionPath 'rtl-native.ppm')",
    "+HEADLESS_PCM=$(Join-Path $sessionPath 'rtl-audio-s16le.pcm')",
    "+HEADLESS_RECEIPT=$(Join-Path $sessionPath 'rtl-receipt.json')",
    "+HEADLESS_WIDTH=$width", "+HEADLESS_HEIGHT=$height"
)
if (-not $NoStateCrc) {
    $arguments += "+STATE_CRC=$(Join-Path $sessionPath 'rtl-state.jsonl')"
}
if (-not $DiagnosticNoAttract) { $arguments += '+REQUIRE_ATTRACT' }
if ($DumpFrameDiag) { $arguments += '+DUMP_FRAME_DIAG' }
if ($AssertIrqCadence) { $arguments += '+ASSERT_IRQ_CADENCE' }
if ($IgnoreNonblack) { $arguments += '+IGNORE_NONBLACK' }
if ($RegisterChangeTrace) {
    $arguments += "+MISTER_REG_TRACE_OUT=$(Join-Path $sessionPath 'rtl-v60-register-change.jsonl')"
}
$st010 = Join-Path $imageDir 'st010.bin'
if (Test-Path -LiteralPath $st010) { $arguments += "+ST010ROM=$st010" }
$scenarioPath = ''
$scenarioManifest = $null
if (-not $ScenarioFile -and $Scenario -eq 'gameplay_neutral') {
    $ScenarioFile = Join-Path $project "verif\scenarios\$Set\gameplay_neutral.json"
}
if ($ScenarioFile) {
    $scenarioPath = [System.IO.Path]::GetFullPath($ScenarioFile)
    if (-not (Test-Path -LiteralPath $scenarioPath)) { throw "Missing gameplay scenario: $scenarioPath" }
    $scenarioSource = Get-Content -Raw -LiteralPath $scenarioPath | ConvertFrom-Json
    $scenarioId = [string]$scenarioSource.id
    if ($scenarioSource.set -ne $Set -or $scenarioId -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Gameplay scenario has an invalid set or id: $scenarioPath"
    }
    $journalPath = Join-Path $project "sim_output\gameplay_journals\$Set\$scenarioId"
    & python (Join-Path $PSScriptRoot 'ssv_gameplay_scenario.py') compile $scenarioPath --output $journalPath
    if ($LASTEXITCODE -ne 0) { throw "Gameplay scenario compilation failed: $scenarioPath" }
    $scenarioManifest = Get-Content -Raw -LiteralPath (Join-Path $journalPath 'manifest.json') | ConvertFrom-Json
    $InputJournal = $journalPath
    $Frames = [int]$scenarioManifest.through_frame + 1
    $arguments = @($arguments | Where-Object { $_ -notmatch '^\+FRAMES=' -and $_ -notmatch '^\+SOAK_FRAMES=' })
    $arguments += "+FRAMES=$Frames"
    $arguments += "+SOAK_FRAMES=$Frames"
    $arguments += "+INPUT_JOURNAL=$InputJournal"
    $arguments += "+SCENARIO_FILE=$scenarioPath"
    $arguments += "+NEUTRAL_AFTER_FRAME=$([int]$scenarioManifest.neutral_after_frame)"
    $arguments += "+GAMEPLAY_ENTRY_FRAME=$([int]$scenarioManifest.neutral_after_frame)"
    $expectedWatchdog = $scenarioManifest.expected_watchdog
    $expectedWatchdogResets = 0
    $expectedWatchdogMinFrame = 0
    $expectedWatchdogMaxFrame = 0
    if ($expectedWatchdog) {
        $expectedWatchdogResets = [int]$expectedWatchdog.resets
        $expectedWatchdogMinFrame = [int]$expectedWatchdog.min_post_video_frame
        $expectedWatchdogMaxFrame = [int]$expectedWatchdog.max_post_video_frame
    }
    $arguments += "+EXPECTED_WATCHDOG_RESETS=$expectedWatchdogResets"
    $arguments += "+EXPECTED_WATCHDOG_MIN_FRAME=$expectedWatchdogMinFrame"
    $arguments += "+EXPECTED_WATCHDOG_MAX_FRAME=$expectedWatchdogMaxFrame"
}
if ($InputJournal -and -not ($arguments | Where-Object { $_ -like '+INPUT_JOURNAL=*' })) {
    $journalPath = [System.IO.Path]::GetFullPath($InputJournal)
    if (-not (Test-Path -LiteralPath $journalPath)) { throw "Input journal does not exist: $journalPath" }
    $arguments += "+INPUT_JOURNAL=$journalPath"
}
# The legacy timed bench defaults to 200M clk_sys cycles, which reaches only
# about post-video frame 225.  Survival Arts measured 383,680,259 clk_sys
# cycles for the 360-frame attract barrier, so keep a measured 600M floor while
# retaining a frame-scaled cap for longer scenarios.  This prevents a complete
# run from being rejected just before run_done while preserving -Cycles as an
# explicit override for bounded diagnostic runs.
if ($Cycles -eq 0) {
    $Cycles = [Math]::Max([UInt64]600000000, ([UInt64]($Frames + 64) * 1000000))
}
$arguments += "+CYCLES=$Cycles"
if ($TraceStartCycle -ne 0) { $arguments += "+TRACE_START_CYCLE=$TraceStartCycle" }
if ($TraceStopCycle -ne 0) { $arguments += "+TRACE_STOP_CYCLE=$TraceStopCycle" }
if ($TraceMaxEvents -ne 0) { $arguments += "+TRACE_MAX_EVENTS=$TraceMaxEvents" }
if ($StrictOnly) { $arguments += '+TRACE_STRICT_ONLY' }
if ($Restore) {
    if (-not $Acceleration) { throw '-Restore requires -Acceleration' }
    $arguments += "+HEADLESS_RESTORE=$Restore"
}
if ($SaveCycle -ne 0) {
    if (-not $Acceleration) { throw '-SaveCycle requires -Acceleration' }
    $arguments += "+HEADLESS_SAVE_CYCLE=$SaveCycle"
    $arguments += "+HEADLESS_CHECKPOINT=$(Join-Path $sessionPath 'rtl-headless.vltsv')"
}
if ($CheckpointControl) {
    if (-not $Acceleration) { throw '-CheckpointControl requires -Acceleration' }
    $arguments += "+HEADLESS_CHECKPOINT_CONTROL=$CheckpointControl"
    $arguments += "+HEADLESS_CHECKPOINT=$(Join-Path $sessionPath 'rtl-headless.vltsv')"
}
$env:MISTER_DIFF_HEADLESS = '1'
$env:SSV_HEADLESS_DSW1 = [string][int]$dsw1Value
$env:SSV_HEADLESS_DSW2 = [string][int]$dsw2Value
if (-not (Test-Path -LiteralPath $safeSim -PathType Leaf)) { throw "Missing safe Verilator simulator launcher: $safeSim" }
& $safeSim $exe @arguments
if ($LASTEXITCODE -ne 0) { throw "Headless RTL capture failed: $LASTEXITCODE" }
$rtlTrace = Join-Path $sessionPath 'rtl-trace.jsonl'
$rtlReceipt = Join-Path $sessionPath 'rtl-receipt.json'
if (-not (Test-Path -LiteralPath $rtlTrace)) { throw 'RTL host stopped without a canonical trace' }
if (-not (Test-Path -LiteralPath $rtlReceipt)) { throw 'RTL host stopped without a receipt' }
$rtlRegisterTrace = Join-Path $sessionPath 'rtl-v60-register-change.jsonl'
if ($RegisterChangeTrace) {
    if (-not (Test-Path -LiteralPath $rtlRegisterTrace -PathType Leaf)) {
        throw "RTL register-change trace is missing: $rtlRegisterTrace"
    }
    $registerRecords = @(Get-Content -LiteralPath $rtlRegisterTrace | ForEach-Object {
        if ($_.Trim()) { $_ | ConvertFrom-Json }
    })
    $registerReceipt = @($registerRecords | Where-Object { $_.record -eq 'receipt' })
    $registerChanges = @($registerRecords | Where-Object { $_.domain -eq 'v60_reg_change' })
    if ($registerReceipt.Count -ne 1 -or $registerReceipt[0].complete -ne $true -or
        [int]$registerReceipt[0].dropped -ne 0 -or
        [int]$registerReceipt[0].count -ne $registerChanges.Count) {
        throw "RTL register-change trace receipt is incomplete or inconsistent: $rtlRegisterTrace"
    }
}
if ($LockoutTrace) { $arguments += '+LOCKOUT_TRACE' }
$receipt = Get-Content -Raw -LiteralPath $rtlReceipt | ConvertFrom-Json
if ($receipt.complete -ne $true -or $receipt.dropped -ne 0) {
    throw "RTL receipt is incomplete or reports drops: $rtlReceipt"
}
if ($scenarioManifest) {
    if ($receipt.native_frames -lt ([int]$scenarioManifest.through_frame + 1)) {
        throw "RTL capture ended before the declared gameplay neutral soak: $($receipt.native_frames) frames"
    }
    # A bounded diagnostic trace may intentionally stop before the gameplay
    # barrier; the model still runs to the declared scenario stop and its
    # receipt/state/frame outputs remain acceptance evidence.  Require the
    # gameplay marker for the normal full-trace lane only.
    if (($TraceStopCycle -eq 0) -and
        -not (Select-String -LiteralPath $rtlTrace -Pattern '"name":"gameplay_entry"' -Quiet)) {
        throw "RTL capture lacks the declared gameplay_entry barrier: $rtlTrace"
    }
}
if ($env:MISTER_TRACE_OUT) {
    $traceDestination = [System.IO.Path]::GetFullPath($env:MISTER_TRACE_OUT)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $traceDestination) | Out-Null
    Copy-Item -LiteralPath $rtlTrace -Destination $traceDestination -Force
}
