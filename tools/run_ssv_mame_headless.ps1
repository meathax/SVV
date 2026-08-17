param(
    [Parameter(Mandatory=$true)][string]$Set,
    [Parameter(Mandatory=$true)][string]$Session,
    [int]$Frames = 360,
    [ValidateSet('all','cpu_data','none')][string]$BusMode = 'all',
    [switch]$StrictOnly,
    [int]$BusStartFrame = -1,
    [int]$BusStopFrame = -1,
    [switch]$InstructionCapture,
    [switch]$DebuggerInstructionTrace,
    [switch]$DebuggerRegisterChangeTrace,
    [switch]$StateCrcCapture,
    [switch]$NoFrameArtifacts,
    [switch]$UnbufferedTrace,
    [switch]$FlushFrameRecords,
    [switch]$BarrierSidecar,
    [int]$IrqHandlerPc = -1,
    [switch]$StateCapture,
    [int]$StateAddress = -1,
    [int]$StatePc = -1,
    [string]$InputJournal = '',
    [string]$ScenarioFile = '',
    [string]$Mame = 'D:\Arcade\AI\mameexe\mame.exe',
    [string]$RomPath = 'D:\Arcade\AI\MAME 0.289 ROMs (merged)'
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
if ($Frames -le 0) { throw 'Frames must be positive' }
if (($BusStartFrame -ge 0) -and ($BusStopFrame -ge 0) -and $BusStopFrame -lt $BusStartFrame) {
    throw 'BusStopFrame must be greater than or equal to BusStartFrame'
}
if ($StrictOnly -and $BusMode -ne 'cpu_data') {
    throw '-StrictOnly requires -BusMode cpu_data'
}
if (-not (Test-Path -LiteralPath $Mame -PathType Leaf)) { throw "Missing pinned MAME executable: $Mame" }
$Mame = [System.IO.Path]::GetFullPath($Mame)
$version = (& $Mame -version | Select-Object -First 1).Trim()
if ($version -ne '0.289 (mame0289)') {
    throw "Differential reference requires MAME 0.289 (mame0289), got: $version"
}
$mameSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $Mame).Hash.ToLowerInvariant()
$supported = & python -c "import sys;sys.path.insert(0,'tools');from ssv_supported_sets import SUPPORTED_SETS;print('1' if '$Set' in SUPPORTED_SETS else '0')"
if ($supported.Trim() -ne '1') { throw "Unsupported SSV set: $Set" }
$scenarioPath = ''
$scenarioManifest = $null
if (-not $ScenarioFile -and $env:SSV_GAMEPLAY_SCENARIO) { $ScenarioFile = $env:SSV_GAMEPLAY_SCENARIO }
if (-not $ScenarioFile -and $Set -and $env:SSV_GAMEPLAY_LANE -eq '1') {
    $ScenarioFile = Join-Path $project "verif\scenarios\$Set\gameplay_neutral.json"
}
if ($ScenarioFile) {
    $scenarioPath = [System.IO.Path]::GetFullPath($ScenarioFile)
    if (-not (Test-Path -LiteralPath $scenarioPath)) { throw "Missing gameplay scenario: $scenarioPath" }
    $scenarioSource = Get-Content -Raw -LiteralPath $scenarioPath | ConvertFrom-Json
    if ($scenarioSource.set -ne $Set) {
        throw "Gameplay scenario set '$($scenarioSource.set)' does not match requested set '$Set'"
    }
    if ($scenarioSource.mame -and $scenarioSource.mame -ne '0.289') {
        throw "Gameplay scenario is not pinned to MAME 0.289: $scenarioPath"
    }
    $scenarioId = [string]$scenarioSource.id
    if ($scenarioId -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Gameplay scenario id is not a safe journal directory name: $scenarioPath"
    }
    $journalPath = Join-Path $project "sim_output\gameplay_journals\$Set\$scenarioId"
    & python (Join-Path $PSScriptRoot 'ssv_gameplay_scenario.py') compile $scenarioPath --output $journalPath
    if ($LASTEXITCODE -ne 0) { throw "Gameplay scenario compilation failed: $scenarioPath" }
    $scenarioManifest = Get-Content -Raw -LiteralPath (Join-Path $journalPath 'manifest.json') | ConvertFrom-Json
    if ($scenarioManifest.set -ne $Set) { throw "Compiled gameplay journal set mismatch: $($scenarioManifest.set)" }
    if ([int]$scenarioManifest.packet_count -ne ([int]$scenarioManifest.through_frame + 1)) {
        throw 'Compiled gameplay journal packet count does not cover every frame'
    }
    $InputJournal = $journalPath
    $Frames = [int]$scenarioManifest.through_frame + 1
}
$meta = & python -c "import xml.etree.ElementTree as E;from pathlib import Path;p=next(p for p in Path('releases').glob('*.mra') if E.parse(p).getroot().findtext('setname')=='$Set');r=E.parse(p).getroot();d=bytes.fromhex((next(n for n in r.findall('rom') if n.get('index')=='1').find('part').text or '').strip());assert len(d)==24 and d[:2]==b'S\x03' and sum(d)%256==0,'release descriptor must be checksum-valid v3';dip=r.find('switches').get('default','FF,FF');a=[int(x,16) for x in dip.split(',')];assert len(a)==2 and all(0<=x<=255 for x in a),'MRA switches default must contain two bytes';print(d[13]*2,d[14],((16-d[2])<<20),a[0],a[1])"
if ($LASTEXITCODE -ne 0 -or @($meta -split '\s+').Count -ne 5) {
    throw "Unable to resolve authoritative descriptor metadata for set: $Set"
}
$width, $height, $romBase, $dsw1Value, $dsw2Value = ($meta -split '\s+')
$sessionPath = [System.IO.Path]::GetFullPath($Session)
$generatedRoot = [System.IO.Path]::GetFullPath((Join-Path $project 'sim_output'))
if (-not $sessionPath.StartsWith($generatedRoot + [System.IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Session must remain below the gitignored sim_output directory'
}
if ($InputJournal -and -not (Test-Path -LiteralPath $InputJournal)) {
    throw "Input journal does not exist: $InputJournal"
}
$journalManifest = $scenarioManifest
if ($InputJournal) {
    $InputJournal = [System.IO.Path]::GetFullPath($InputJournal)
    if (-not $journalManifest) {
        $journalManifestPath = Join-Path $InputJournal 'manifest.json'
        if (-not (Test-Path -LiteralPath $journalManifestPath -PathType Leaf)) {
            throw "Direct input journal is missing its immutable manifest: $journalManifestPath"
        }
        $journalManifest = Get-Content -Raw -LiteralPath $journalManifestPath | ConvertFrom-Json
        if ($journalManifest.set -ne $Set) {
            throw "Input journal set '$($journalManifest.set)' does not match requested set '$Set'"
        }
        if ([int]$journalManifest.packet_count -lt $Frames) {
            throw "Input journal has only $($journalManifest.packet_count) packets but the run requires $Frames"
        }
    }
}
$mameRoot = Join-Path $sessionPath 'mame'
foreach ($name in @('cfg','nvram','state','snapshot')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $mameRoot $name) | Out-Null
}
if ($BarrierSidecar -and $BusMode -ne 'none') {
    throw '-BarrierSidecar is restricted to -BusMode none so the raw stream remains bounded'
}
$journalSha256 = ''
if ($journalManifest) {
    $journalSha256 = [string]$journalManifest.semantic_sha256
    if ($journalSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'Input journal manifest lacks a valid semantic_sha256'
    }
    $journalSha256 = $journalSha256.ToLowerInvariant()
}
# Attract-mode runs intentionally have no gameplay journal.  Bind that
# contract to the SHA-256 of an empty byte stream so the Lua trace and the
# streaming finalizer still carry a concrete, reproducible identity instead
# of forwarding an empty PowerShell argument.
if (-not $journalManifest) {
    $journalSha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
}
# Do not let a caller's stale environment leak a previous scenario contract
# into an attract-mode run.
foreach ($name in @('SSV_HEADLESS_SCENARIO_FILE','SSV_HEADLESS_NEUTRAL_AFTER_FRAME',
        'SSV_HEADLESS_GAMEPLAY_ENTRY_FRAME','SSV_HEADLESS_PPM_FRAMES',
        'SSV_HEADLESS_JOURNAL_REQUIRED','SSV_HEADLESS_MAME_VERSION',
        'SSV_HEADLESS_MAME_SHA256','SSV_HEADLESS_JOURNAL_SHA256',
        'SSV_HEADLESS_STRICT_ONLY',
        'SSV_HEADLESS_STATE_CAPTURE','SSV_HEADLESS_STATE_ADDRESS','SSV_HEADLESS_STATE_PC',
        'SSV_HEADLESS_INSN_CAPTURE','SSV_HEADLESS_DEBUGGER_INSN_TRACE',
        'SSV_HEADLESS_DEBUGGER_REG_CHANGE_TRACE','SSV_HEADLESS_IRQ_HANDLER_PC',
        'SSV_HEADLESS_STATE_CRC_CAPTURE','SSV_HEADLESS_STATE_CRC_OUTPUT',
        'SSV_HEADLESS_DSW1','SSV_HEADLESS_DSW2',
        'SSV_HEADLESS_BARRIER_PATH','SSV_HEADLESS_BARRIER_DIR','SSV_HEADLESS_DISABLE_PPM',
        'SSV_HEADLESS_EXPECTED_WATCHDOG_RESETS','SSV_HEADLESS_EXPECTED_WATCHDOG_MIN_FRAME',
        'SSV_HEADLESS_EXPECTED_WATCHDOG_MAX_FRAME')) {
    Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
}
$env:SSV_HEADLESS_DIR = $sessionPath.Replace('\','/')
$env:SSV_HEADLESS_SET = $Set
$env:SSV_HEADLESS_WIDTH = $width
$env:SSV_HEADLESS_HEIGHT = $height
$env:SSV_HEADLESS_ROM_BASE = $romBase
$env:SSV_HEADLESS_FRAMES = $Frames
$env:SSV_HEADLESS_INPUT_JOURNAL = $InputJournal
$env:SSV_HEADLESS_AUDIO_RATE = '48000'
$env:SSV_HEADLESS_MAME_VERSION = $version
$env:SSV_HEADLESS_MAME_SHA256 = $mameSha256
$env:SSV_HEADLESS_JOURNAL_SHA256 = $journalSha256
$env:SSV_HEADLESS_COIN_IMPULSE = '-1'
$env:SSV_HEADLESS_DSW1 = [string][int]$dsw1Value
$env:SSV_HEADLESS_DSW2 = [string][int]$dsw2Value
$env:SSV_HEADLESS_EXPECTED_WATCHDOG_RESETS = '0'
$env:SSV_HEADLESS_EXPECTED_WATCHDOG_MIN_FRAME = '0'
$env:SSV_HEADLESS_EXPECTED_WATCHDOG_MAX_FRAME = '0'
$env:SSV_HEADLESS_BUS_MODE = $BusMode
$env:SSV_HEADLESS_STRICT_ONLY = if ($StrictOnly) { '1' } else { '0' }
$env:SSV_HEADLESS_BUS_START_FRAME = [string]$BusStartFrame
$env:SSV_HEADLESS_BUS_STOP_FRAME = [string]$BusStopFrame
$env:SSV_HEADLESS_UNBUFFERED_TRACE = if ($UnbufferedTrace) { '1' } else { '0' }
$env:SSV_HEADLESS_FLUSH_FRAME_RECORDS = if ($FlushFrameRecords) { '1' } else { '0' }
$env:SSV_HEADLESS_DISABLE_PPM = if ($NoFrameArtifacts) { '1' } else { '0' }
$barrierDir = Join-Path $sessionPath 'mame-barriers'
if ($BarrierSidecar) {
    New-Item -ItemType Directory -Force -Path $barrierDir | Out-Null
    $env:SSV_HEADLESS_BARRIER_DIR = $barrierDir.Replace('\','/')
}
$env:SSV_HEADLESS_INSN_CAPTURE = if ($InstructionCapture) { '1' } else { '0' }
$env:SSV_HEADLESS_DEBUGGER_INSN_TRACE = if ($DebuggerInstructionTrace) { '1' } else { '0' }
$env:SSV_HEADLESS_DEBUGGER_REG_CHANGE_TRACE = if ($DebuggerRegisterChangeTrace) { '1' } else { '0' }
$stateCrcPath = Join-Path $sessionPath 'mame-state.crc'
$env:SSV_HEADLESS_STATE_CRC_CAPTURE = if ($StateCrcCapture) { '1' } else { '0' }
if ($StateCrcCapture) { $env:SSV_HEADLESS_STATE_CRC_OUTPUT = $stateCrcPath.Replace('\','/') }
if ($IrqHandlerPc -ge 0) { $env:SSV_HEADLESS_IRQ_HANDLER_PC = ('{0:X}' -f $IrqHandlerPc) }
$env:SSV_HEADLESS_STATE_CAPTURE = if ($StateCapture) { '1' } else { '0' }
if ($StateAddress -ge 0) { $env:SSV_HEADLESS_STATE_ADDRESS = [string]$StateAddress }
if ($StatePc -ge 0) { $env:SSV_HEADLESS_STATE_PC = [string]$StatePc }
if ($scenarioManifest) {
    $env:SSV_HEADLESS_SCENARIO_FILE = $scenarioPath.Replace('\','/')
    $env:SSV_HEADLESS_NEUTRAL_AFTER_FRAME = [string]$scenarioManifest.neutral_after_frame
    $env:SSV_HEADLESS_GAMEPLAY_ENTRY_FRAME = [string]$scenarioManifest.neutral_after_frame
    if (-not $NoFrameArtifacts) {
        $env:SSV_HEADLESS_PPM_FRAMES = "$([int]$scenarioManifest.neutral_after_frame),$([int]$scenarioManifest.through_frame)"
    }
    $env:SSV_HEADLESS_JOURNAL_REQUIRED = '1'
    $expectedWatchdog = $journalManifest.expected_watchdog
    if ($expectedWatchdog) {
        $env:SSV_HEADLESS_EXPECTED_WATCHDOG_RESETS = [string][int]$expectedWatchdog.resets
        $env:SSV_HEADLESS_EXPECTED_WATCHDOG_MIN_FRAME = [string][int]$expectedWatchdog.min_post_video_frame
        $env:SSV_HEADLESS_EXPECTED_WATCHDOG_MAX_FRAME = [string][int]$expectedWatchdog.max_post_video_frame
    }
}
$arguments = @(
    '-noreadconfig', $Set, '-rompath', $RomPath, '-video', 'none', '-sound', 'none',
    '-coin_impulse', '-1',
    '-samplerate', '48000', '-wavwrite', (Join-Path $sessionPath 'mame-audio.wav'),
    '-nothrottle', '-skip_gameinfo', '-autoboot_delay', '0',
    '-autoboot_script', (Join-Path $PSScriptRoot 'mame-ssv-headless.lua'),
    '-cfg_directory', (Join-Path $mameRoot 'cfg'),
    '-nvram_directory', (Join-Path $mameRoot 'nvram'),
    '-state_directory', (Join-Path $mameRoot 'state'),
    '-snapshot_directory', (Join-Path $mameRoot 'snapshot')
)
if ($DebuggerInstructionTrace -or $DebuggerRegisterChangeTrace) {
    # The "none" debugger keeps MAME windowless while enabling the CPU's real
    # device_debug::instruction_hook for the opt-in trace artifact.
    $arguments += @('-debug', '-debugger', 'none')
}
if ($DebuggerRegisterChangeTrace) { $arguments += '-debuglog' }
$mameExit = 0
if ($DebuggerRegisterChangeTrace) {
    $staleDebuggerLog = Join-Path $mameRoot 'debug.log'
    if (Test-Path -LiteralPath $staleDebuggerLog) {
        Remove-Item -LiteralPath $staleDebuggerLog -Force
    }
}
Push-Location $(if ($DebuggerRegisterChangeTrace) { $mameRoot } else { $project })
try {
    & $Mame @arguments
    $mameExit = $LASTEXITCODE
}
finally {
    Pop-Location
}
if ($mameExit -ne 0) { throw "Headless MAME capture failed: $mameExit" }
$debuggerTrace = Join-Path $sessionPath 'mame-v60-debugger.tr'
if ($DebuggerInstructionTrace) {
    if (-not (Test-Path -LiteralPath $debuggerTrace -PathType Leaf) -or
        (Get-Item -LiteralPath $debuggerTrace).Length -le 0) {
        throw "MAME debugger instruction trace is missing or empty: $debuggerTrace"
    }
    if (-not (Select-String -LiteralPath $debuggerTrace -SimpleMatch 'SSVREG ' -Quiet)) {
        throw "MAME debugger trace contains no pre-execution register records: $debuggerTrace"
    }
    if ($IrqHandlerPc -ge 0) {
        $irqEntryPath = Join-Path $sessionPath 'mame-v60-irq-entry.jsonl'
        $irqPattern = '^SSVREG cursor=(?<cursor>\d+) pc=(?<pc>[0-9A-Fa-f]+) opcode=(?<opcode>[0-9A-Fa-f]+) psw=(?<psw>[0-9A-Fa-f]+)'
        $irqLines = @(
            '{"schema":"ssv-v60-irq-entry-v1","producer":"mame-0.289-debugger-trace"}'
        )
        foreach ($line in Get-Content -LiteralPath $debuggerTrace) {
            $match = [regex]::Match($line, $irqPattern)
            if (-not $match.Success -or
                [Convert]::ToInt32($match.Groups['pc'].Value, 16) -ne $IrqHandlerPc) { continue }
            $irqLines += ([ordered]@{
                domain = 'v60_irq_entry'
                event = 'handler_entry'
                phase = 'before_execute'
                seq = $irqLines.Count - 1
                handler_pc = $IrqHandlerPc
                opcode = [Convert]::ToInt32($match.Groups['opcode'].Value, 16)
                psw = [Convert]::ToInt64($match.Groups['psw'].Value, 16)
                input_cursor = [Convert]::ToInt32($match.Groups['cursor'].Value, 10)
            } | ConvertTo-Json -Compress)
        }
        if ($irqLines.Count -le 1) { throw 'MAME IRQ handler probe emitted no entries' }
        Set-Content -LiteralPath $irqEntryPath -Value $irqLines -Encoding UTF8
    }
}
$debuggerRegisterLog = Join-Path $mameRoot 'debug.log'
if ($DebuggerRegisterChangeTrace) {
    if (-not (Test-Path -LiteralPath $debuggerRegisterLog -PathType Leaf) -or
        -not (Select-String -LiteralPath $debuggerRegisterLog -SimpleMatch 'SSVREGCHANGE ' -Quiet)) {
        throw "MAME debugger register-change trace is missing or empty: $debuggerRegisterLog"
    }
}
$mameTrace = Join-Path $sessionPath 'mame-trace.jsonl'
if (-not (Test-Path -LiteralPath $mameTrace)) {
    throw 'MAME stopped without a canonical trace'
}
if ($BarrierSidecar) {
    $barrierFiles = @(Get-ChildItem -LiteralPath $barrierDir -Filter 'record_*.json' -File | Sort-Object Name)
    if ($barrierFiles.Count -eq 0) {
        throw "MAME stopped without barrier sidecar records: $barrierDir"
    }
    $mergedTrace = "$mameTrace.merge"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $mergedLines = @(
        foreach ($file in $barrierFiles) { Get-Content -LiteralPath $file.FullName }
        Get-Content -LiteralPath $mameTrace
    )
    [System.IO.File]::WriteAllLines($mergedTrace, $mergedLines, $utf8NoBom)
    Move-Item -LiteralPath $mergedTrace -Destination $mameTrace -Force
}
$receiptPath = Join-Path $sessionPath 'mame-receipt.json'
& python (Join-Path $PSScriptRoot 'finalize_ssv_mame_trace.py') `
    $mameTrace $receiptPath --journal-sha256 $journalSha256 `
    $(if ($StrictOnly) { '--strict-only' }) `
    $(if ($IrqHandlerPc -ge 0) { @('--irq-handler-pc', [string]$IrqHandlerPc) }) `
    $(if ($scenarioManifest) {
        @('--expected-frames', [string]([int]$scenarioManifest.through_frame + 1),
           '--neutral-after-frame', [string][int]$scenarioManifest.neutral_after_frame)
    })
if ($LASTEXITCODE -ne 0) { throw "MAME trace finalization failed: $mameTrace" }
$receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
# Windows PowerShell 5.1 does not expose PowerShell Core's `utf8NoBOM`
# encoding enum.  Use the no-BOM spelling where available and fall back to
# its compatible UTF-8 writer otherwise; both produce JSON accepted by the
# canonical readers (the Windows writer may add a harmless BOM).  Use the
# common enum name because this script may be hosted by either PowerShell
# edition and some providers reject the PowerShell-7-only utf8NoBOM value.
$jsonEncoding = 'UTF8'
$stateCrcPath = Join-Path $sessionPath 'mame-state.crc'
if ($StateCrcCapture) {
    if (-not (Test-Path -LiteralPath $stateCrcPath -PathType Leaf) -or
        (Get-Item -LiteralPath $stateCrcPath).Length -le 0) {
        throw "MAME state CRC sidecar is missing or empty: $stateCrcPath"
    }
    $stateLines = @(Get-Content -LiteralPath $stateCrcPath | Where-Object { $_.Trim() })
    if ($stateLines.Count -ne [int]$receipt.frames) {
        throw "MAME state CRC count $($stateLines.Count) does not equal frame count $($receipt.frames)"
    }
    for ($index = 0; $index -lt $stateLines.Count; $index++) {
        $expected = '^STATE\s+' + $index + '\s+list512=[0-9a-fA-F]{8}\s+spr8k=[0-9a-fA-F]{8}\s+scroll63=[0-9a-fA-F]{8}\s+pal512=[0-9a-fA-F]{8}$'
        if ($stateLines[$index] -notmatch $expected) {
            throw "MAME state CRC sidecar is malformed at frame $index"
        }
    }
    $receipt | Add-Member -NotePropertyName state_crc_capture -NotePropertyValue $true
    $receipt | Add-Member -NotePropertyName state_crc_path -NotePropertyValue $stateCrcPath
    $receipt | Add-Member -NotePropertyName state_crc_sha256 -NotePropertyValue ((Get-FileHash -Algorithm SHA256 -LiteralPath $stateCrcPath).Hash.ToLowerInvariant())
} else {
    $receipt | Add-Member -NotePropertyName state_crc_capture -NotePropertyValue $false
}
$receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $receiptPath -Encoding $jsonEncoding
$wav = Join-Path $sessionPath 'mame-audio.wav'
if (-not (Test-Path -LiteralPath $wav) -or (Get-Item -LiteralPath $wav).Length -le 44) {
    throw "MAME did not emit a non-empty 48 kHz WAV capture: $wav"
}
$normalized = Join-Path $sessionPath 'mame-audio-s16le-48k-stereo.pcm'
& python (Join-Path $PSScriptRoot 'normalize_audio.py') $wav $normalized
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $normalized)) {
    throw "MAME audio normalization failed: $wav"
}
if ($env:MISTER_TRACE_OUT) {
    $traceDestination = [System.IO.Path]::GetFullPath($env:MISTER_TRACE_OUT)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $traceDestination) | Out-Null
    Copy-Item -LiteralPath $mameTrace -Destination $traceDestination -Force
}
