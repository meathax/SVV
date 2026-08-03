param(
    [string]$Set = 'dynagear',
    [ValidateRange(1, 100000)]
    [int]$Frames = 3,
    # -1 selects the set's authoritative first-comparable token from the
    # immutable preflight manifest.
    [ValidateRange(-1, 100000)]
    [int]$StartFrame = -1,
    [ValidateSet('pixel','trace','state','never')]
    [string]$FreezeOn = 'pixel',
    [ValidateSet('none','attract','gameplay')]
    [string]$ProofMode = 'none',
    [switch]$Diagnostic,
    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 300,
    [string]$Scenario = 'coin_start_p1_gameplay',
    [string]$Session = '',
    [string]$RtlRestore = '',
    [string]$RtlInputJournal = '',
    [ValidateRange(-1, 100000)]
    [int]$DumpIndexFrame = -1,
    [string]$ModelDir = 'C:\tmp\ssv_obj_visual_lockstep'
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$python = (Get-Command python -ErrorAction Stop).Source
$mame = 'D:\Arcade\AI\mame\mame.exe'
$mameSource = 'D:\Arcade\AI\MAMESOURCE\mame'
$simSafe = 'C:\Users\meath\bin\verilator-sim-safe.exe'
if (-not (Test-Path -LiteralPath $mame)) { throw "Missing MAME executable: $mame" }
if (-not (Test-Path -LiteralPath $simSafe)) { throw "Missing safe simulator wrapper: $simSafe" }
$restoreMetadata = $null
if ($RtlRestore) {
    if ($ModelDir -eq 'C:\tmp\ssv_obj_visual_lockstep') {
        $ModelDir = 'C:\tmp\ssv_obj_visual_savable'
    }
    $RtlRestore = [System.IO.Path]::GetFullPath($RtlRestore)
    $restoreMetadataPath = "$RtlRestore.json"
    if (-not (Test-Path -LiteralPath $RtlRestore) -or
        (Get-Item -LiteralPath $RtlRestore).Length -le 0 -or
        -not (Test-Path -LiteralPath $restoreMetadataPath)) {
        throw "Checkpoint lockstep requires a nonempty archive and sidecar: $RtlRestore"
    }
    $restoreMetadata = Get-Content -Raw -LiteralPath $restoreMetadataPath |
        ConvertFrom-Json
    if ($restoreMetadata.schema -ne 'ssv-verilator-checkpoint-v2') {
        throw 'Checkpoint lockstep requires v2 metadata with an RTL-owned input identity'
    }
    if ($restoreMetadata.set -ne $Set -or $restoreMetadata.scenario -ne $Scenario -or
        $restoreMetadata.proof.mode -ne $ProofMode) {
        throw 'Checkpoint set/scenario/proof identity does not match this lockstep request'
    }
    if ($StartFrame -lt 0) { $StartFrame = [int]$restoreMetadata.frame + 1 }
    if ([int]$restoreMetadata.frame -ne $StartFrame - 1) {
        throw "Restore frame $($restoreMetadata.frame) must immediately precede StartFrame $StartFrame"
    }
    if (-not $RtlInputJournal) {
        $RtlInputJournal = [string]$restoreMetadata.input_journal.path
    }
    $RtlInputJournal = [System.IO.Path]::GetFullPath($RtlInputJournal)
}

if (-not $Session) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $Session = Join-Path $project "sim_output\lockstep\$Set-$stamp"
} elseif (-not [System.IO.Path]::IsPathRooted($Session)) {
    $Session = Join-Path $project $Session
}
$Session = [System.IO.Path]::GetFullPath($Session)
if (Test-Path -LiteralPath $Session) {
    throw "Lockstep session must be fresh: $Session"
}

$preflightArgs = @('--set',$Set,'--session',$Session,'--mame',$mame,
    '--mame-source',$mameSource,'--scenario',$Scenario)
if ($RtlRestore) {
    $preflightArgs += @('--start-frame',[string]$StartFrame,
        '--rtl-restore',$RtlRestore,'--input-journal',$RtlInputJournal)
}
& $python (Join-Path $PSScriptRoot 'ssv_lockstep_preflight.py') @preflightArgs
if ($LASTEXITCODE -ne 0) { throw "Static lockstep preflight failed: $LASTEXITCODE" }

foreach ($relative in @('rtl','reference','diff','inputs','logs')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Session $relative) | Out-Null
}
$manifest = Get-Content -Raw -LiteralPath (Join-Path $Session 'manifest.json') |
    ConvertFrom-Json
$firstComparableToken = [int]$manifest.alignment.first_comparable_token
if ($StartFrame -lt 0) { $StartFrame = $firstComparableToken }
if ($StartFrame -lt $firstComparableToken) {
    throw "StartFrame $StartFrame precedes first comparable token $firstComparableToken for $Set"
}
$width = [int]$manifest.alignment.geometry.rtl[0]
$height = [int]$manifest.alignment.geometry.rtl[1]
$dsw1 = [int]$manifest.alignment.mra_dips.DSW1
$dsw2 = [int]$manifest.alignment.mra_dips.DSW2
$gameId = [int]$manifest.game_id
$descriptorBytes = [Convert]::FromHexString([string]$manifest.mra.descriptor_hex)
$hasSt010 = (($descriptorBytes[9] -band 0x08) -ne 0)
$requestedEndFrame = $StartFrame + $Frames - 1
$proofFrame = -1
$proofSoakFrames = 0
$proofScreenshot = ''
switch ($ProofMode) {
    'attract' {
        if ($Scenario -ne 'attract_idle') {
            throw 'Attract proof requires -Scenario attract_idle'
        }
        $proofFrame = 359
        $proofSoakFrames = 360
    }
    'gameplay' {
        if ($Set -ne 'dynagear') {
            throw 'The current REQUIRE_GAMEPLAY metric is qualified only for dynagear'
        }
        if ($Scenario -notin @('coin_start_p1_gameplay','coin_start_p1_long',
                                'coin_start_p1_runright')) {
            throw 'Dyna gameplay proof requires a qualified coin/start gameplay scenario'
        }
        $proofFrame = 850
        $proofSoakFrames = 851
    }
}
if ($proofFrame -ge 0 -and $requestedEndFrame -lt $proofFrame) {
    throw "ProofMode $ProofMode requires comparison through token $proofFrame; requested end is $requestedEndFrame"
}
if ($proofFrame -ge 0) {
    if ($RtlRestore -and ($StartFrame -ne $proofFrame -or $Frames -ne 1 -or
        [int]$restoreMetadata.proof.frame -ne $proofFrame)) {
        throw 'Checkpoint gameplay proof must restore frame 849 and compare exactly token 850'
    }
    $proofScreenshot = Join-Path $Session `
        ('rtl_proof_{0}_f{1:D3}.ppm' -f $ProofMode, $proofFrame)
    @{
        schema='ssv-lockstep-proof-request-v1'; set=$Set; mode=$ProofMode
        scenario=$Scenario; proof_frame=$proofFrame
        screenshot=$proofScreenshot; requested_end_frame=$requestedEndFrame
    } | ConvertTo-Json | Set-Content -LiteralPath `
        (Join-Path $Session 'proof_request.json')
    if ($RtlRestore) {
        $checkpointProofScreenshot = [string]$restoreMetadata.proof.screenshot
        if (-not $checkpointProofScreenshot) {
            throw 'Checkpoint proof metadata has no Verilator screenshot target'
        }
        if (Test-Path -LiteralPath $checkpointProofScreenshot) {
            Remove-Item -Force -LiteralPath $checkpointProofScreenshot
        }
    }
}
$packetName = 'inputs\frame_000000.json'
$journalTool = Join-Path $PSScriptRoot 'ssv_input_journal.py'
if ($RtlRestore) {
    $stagedIdentityJson = (& $python $journalTool --journal $RtlInputJournal `
        --through $StartFrame --stage-to (Join-Path $Session 'inputs') |
        Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $stagedIdentityJson) {
        throw "Unable to stage verified RTL input prefix through frame $StartFrame"
    }
} else {
    & $python $journalTool --journal (Join-Path $Session 'inputs') --seed-neutral
    if ($LASTEXITCODE -ne 0) { throw 'Unable to seed neutral input packet' }
}

$buildArgs = @{ ModelDir = $ModelDir }
if ($RtlRestore) { $buildArgs.Savable = $true }
& (Join-Path $PSScriptRoot 'build_ssv_visual.ps1') @buildArgs
if ($LASTEXITCODE -ne 0) { throw "Visual build failed: $LASTEXITCODE" }
$printArgs = @{ ModelDir = $ModelDir; PrintExecutable = $true }
if ($RtlRestore) { $printArgs.Savable = $true }
$exe = (& (Join-Path $PSScriptRoot 'build_ssv_visual.ps1') @printArgs |
    Select-Object -Last 1)
if (-not (Test-Path -LiteralPath $exe)) { throw "Missing visual executable: $exe" }
if ($RtlRestore) {
    $signaturePath = Join-Path ([System.IO.Path]::GetFullPath($ModelDir)) `
        'source.signature'
    $signatureHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $signaturePath).Hash
    if ($signatureHash -ne $restoreMetadata.source_signature_sha256) {
        throw 'Checkpoint source signature does not match the selected savable executable'
    }
}

$romDir = if ($Set -eq 'dynagear') {
    Join-Path $project 'sim_output\rom'
} else {
    Join-Path $project "sim_output\rom\$Set"
}
$mainRom = Join-Path $romDir 'maincpu.bin'
$spriteRom = Join-Path $romDir 'sprites.bin'
$sampleRom = Join-Path $romDir 'samples.bin'
$st010Rom = Join-Path $romDir 'st010.bin'
foreach ($rom in @($mainRom,$spriteRom,$sampleRom)) {
    if (-not (Test-Path -LiteralPath $rom)) { throw "Missing simulation image: $rom" }
}
if ($hasSt010 -and -not (Test-Path -LiteralPath $st010Rom)) {
    throw "Missing ST010 simulation image: $st010Rom"
}

$rtlLog = Join-Path $Session 'logs\rtl.log'
$rtlErr = Join-Path $Session 'logs\rtl.err.log'
$mameLog = Join-Path $Session 'logs\mame.log'
$mameErr = Join-Path $Session 'logs\mame.err.log'
$rtlCrc = Join-Path $Session 'rtl_frames.crc'
$rtlStateLegacy = Join-Path $Session 'rtl_state.crc'
$frameLimit = if ($proofFrame -ge 0) {
    [Math]::Max($StartFrame + $Frames, $proofSoakFrames)
} else {
    $StartFrame + $Frames + 2
}
$rtlArgs = @(
    ('"+MAINROM={0}"' -f ($mainRom -replace '\\','/')),
    ('"+SPRROM={0}"' -f ($spriteRom -replace '\\','/')),
    ('"+SMPROM={0}"' -f ($sampleRom -replace '\\','/')),
    ('"+FRAME_CRC={0}"' -f ($rtlCrc -replace '\\','/')),
    ('"+STATE_CRC={0}"' -f ($rtlStateLegacy -replace '\\','/')),
    "+GAME_ID=$gameId", ('+DSW1={0:X2}' -f $dsw1), ('+DSW2={0:X2}' -f $dsw2),
    # Diagnostic sessions need a real CRC seed at the first restored frame;
    # normal lockstep keeps the cheaper start-frame gating.
    "+STATE_START_FRAME=$(if ($Diagnostic) { 0 } else { $StartFrame })",
    "+SCENARIO=$Scenario", "+FRAMES=$frameLimit", "+SOAK_FRAMES=$proofSoakFrames",
    '+CYCLES=9000000000000'
)
if (Test-Path -LiteralPath $st010Rom) {
    $rtlArgs += ('"+ST010ROM={0}"' -f ($st010Rom -replace '\\','/'))
}
if ($Diagnostic) { $rtlArgs += @('+VISUAL_DIAG', '+LIGHT_DIAG') }
if ($RtlRestore) {
    $rtlArgs += ('"+RESTORE={0}"' -f ($RtlRestore -replace '\\','/'))
}
if ($ProofMode -eq 'attract') {
    $rtlArgs += @('+REQUIRE_ATTRACT', '+REQUIRE_VERILATOR_SCREENSHOT',
                  '+STOP_ON_RENDERER_OVERRUN',
                  ('"+DUMP_PPM={0}"' -f ($proofScreenshot -replace '\\','/')),
                  "+DUMP_PPM_FRAME=$proofFrame")
} elseif ($ProofMode -eq 'gameplay') {
    $rtlArgs += @('+REQUIRE_GAMEPLAY', '+REQUIRE_VERILATOR_SCREENSHOT',
                  '+STOP_ON_RENDERER_OVERRUN',
                  ('"+DUMP_PPM={0}"' -f ($proofScreenshot -replace '\\','/')),
                  "+DUMP_PPM_FRAME=$proofFrame")
}

$rtlEnvironment = @{
    SSV_LOCKSTEP_DIR = $Session
    SSV_LOCKSTEP_SET = $Set
    SSV_LOCKSTEP_WIDTH = [string]$width
    SSV_LOCKSTEP_HEIGHT = [string]$height
    SSV_LOCKSTEP_DSW1 = [string]$dsw1
    SSV_LOCKSTEP_DSW2 = [string]$dsw2
    SSV_LOCKSTEP_TRACE = '1'
    SSV_LOCKSTEP_START_FRAME = [string]$StartFrame
    SSV_LOCKSTEP_FIRST_COMPARABLE_TOKEN = [string]$firstComparableToken
    SSV_LOCKSTEP_RTL_STARTUP_MODE = $(if ($RtlRestore) {
        'checkpoint-restore' } else { 'cold-lockstep' })
    SSV_LOCKSTEP_RESTORE_FRAME = $(if ($RtlRestore) {
        [string]([int]$restoreMetadata.frame) } else { '-1' })
}
$safeArgs = @('--comparison','--',('"{0}"' -f $exe)) + $rtlArgs
$rtl = Start-Process -FilePath $simSafe -ArgumentList $safeArgs `
    -WorkingDirectory $project -RedirectStandardOutput $rtlLog `
    -RedirectStandardError $rtlErr -Environment $rtlEnvironment -PassThru

# Do not start the reference emulator while the safe RTL wrapper is merely
# queued for a shared simulation slot. A short bounded acquisition check keeps
# this chat from consuming MAME/runtime resources while another model is active.
function Get-RtlModelProcess {
    $modelName = [System.IO.Path]::GetFileNameWithoutExtension($exe)
    Get-Process -Name $modelName -ErrorAction SilentlyContinue |
        Where-Object {
            try { $_.Path -ieq $exe } catch { $false }
        } |
        Select-Object -First 1
}

function Stop-RtlModelProcess {
    $model = Get-RtlModelProcess
    if ($model) {
        Stop-Process -Id $model.Id -Force -ErrorAction SilentlyContinue
    }
}

$rtlChild = $null
# Let the machine-wide safe scheduler drain a queued visual model before
# declaring a lane unavailable.  The reference emulator is still withheld
# until the RTL child is actually running, so this does not strand MAME.
$slotDeadline = (Get-Date).AddSeconds([Math]::Min($TimeoutSeconds, 120))
while ((Get-Date) -lt $slotDeadline) {
    if ($rtl.HasExited) {
        throw "Safe RTL wrapper exited before launching the model: $($rtl.ExitCode)"
    }
    try {
        $rtlChild = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($rtl.Id)" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($exe) } |
            Select-Object -First 1
    } catch {
        $rtlChild = $null
    }
    if (-not $rtlChild) { $rtlChild = Get-RtlModelProcess }
    if ($rtlChild) { break }
    Start-Sleep -Milliseconds 100
}
if (-not $rtlChild) {
    Set-Content -LiteralPath (Join-Path $Session 'STOP.txt') `
        -Value 'safe simulation slot not acquired within bounded wait'
    Stop-Process -Id $rtl.Id -Force -ErrorAction SilentlyContinue
    $rtl.WaitForExit()
    @{
        schema='ssv-lockstep-cleanup-v1'; reason='simulation slot wait expired'
        rtl_pid=$rtl.Id; rtl_exit=$rtl.ExitCode; rtl_forced=$true
        mame_started=$false; timestamp=(Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Session 'cleanup.json')
    throw 'Safe simulation slot was busy; MAME was not launched'
}
$rtlChildPid = if ($rtlChild.PSObject.Properties.Name -contains 'ProcessId') {
    [int]$rtlChild.ProcessId
} else {
    [int]$rtlChild.Id
}
Write-Host "SSV_LOCKSTEP_RTL_SLOT_ACQUIRED wrapper_pid=$($rtl.Id) model_pid=$rtlChildPid"

$mameProcess = $null
$watchdog = $null
$coordinatorExit = -1
$rtlForced = $false
$mameForced = $false
try {
# MAME's display_startup_screens() suppresses blocking warning screens only
# when -seconds_to_run is below 300 seconds (ui.cpp). Lockstep pauses the
# reference at every token and needs only ~15 emulated seconds through Dyna
# frame 850; the independent watchdog owns wall-clock cleanup.
$mameRunSeconds = [Math]::Max(30, [Math]::Min(299, $TimeoutSeconds + 15))
$mameArgs = @(
    $Set, '-rompath', ('"{0}"' -f (Join-Path $project 'rom')), '-window', '-nomaximize',
    '-skip_gameinfo', '-seconds_to_run', [string]$mameRunSeconds, '-throttle',
    '-video', 'opengl', '-sound', 'auto', '-output', 'console',
    # SSV's PORT_IMPULSE(10) is a MAME UI convenience.  Lockstep packets
    # already carry the raw PCB input level for each native interval, so do
    # not add hidden coin-latch state between the RTL owner and MAME.
    '-coin_impulse', '-1',
    '-autoboot_delay', '0',
    '-cfg_directory', ('"{0}"' -f (Join-Path $Session 'mame\cfg')),
    '-nvram_directory', ('"{0}"' -f (Join-Path $Session 'mame\nvram')),
    '-state_directory', ('"{0}"' -f (Join-Path $Session 'mame\state')),
    '-snapshot_directory', ('"{0}"' -f (Join-Path $Session 'mame\snapshot')),
    '-autoboot_script', ('"{0}"' -f (Join-Path $PSScriptRoot 'mame-ssv-lockstep.lua'))
)
$mameEnvironment = @{
    SSV_LOCKSTEP_DIR = $Session
    SSV_LOCKSTEP_SET = $Set
    SSV_LOCKSTEP_WIDTH = [string]$width
    SSV_LOCKSTEP_HEIGHT = [string]$height
    SSV_LOCKSTEP_START_FRAME = [string]$StartFrame
    SSV_LOCKSTEP_FIRST_COMPARABLE_TOKEN = [string]$firstComparableToken
    SSV_LOCKSTEP_REFERENCE_STARTUP_MODE = $(if ($RtlRestore) {
        'cold-reference-replay' } else { 'cold-lockstep' })
    SSV_LOCKSTEP_CATCHUP_TARGET = $(if ($RtlRestore) {
        [string]$StartFrame } else { '-1' })
    SSV_LOCKSTEP_STRICT_INPUTS = $(if ($RtlRestore) { '1' } else { '0' })
}
if ($DumpIndexFrame -ge 0) {
    $mameEnvironment['SSV_LOCKSTEP_DUMP_INDEX_FRAME'] = [string]$DumpIndexFrame
    $mameEnvironment['SSV_LOCKSTEP_DUMP_INDEX_PATH'] =
        (Join-Path $Session ("reference/frame_{0:D6}.index" -f $DumpIndexFrame))
}
$mameProcess = Start-Process -FilePath $mame -ArgumentList $mameArgs `
    -WorkingDirectory $project -RedirectStandardOutput $mameLog `
    -RedirectStandardError $mameErr -Environment $mameEnvironment -PassThru

# The Lua adapter publishes readiness immediately, before game boot. Bound
# this separately from the much longer gameplay timeout so a transient MAME
# startup failure cannot strand the RTL comparison slot.
$referenceReadyPath = Join-Path $Session 'reference_ready.json'
$referenceReadyDeadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $referenceReadyDeadline -and
       -not (Test-Path -LiteralPath $referenceReadyPath)) {
    if ($mameProcess.HasExited) {
        throw "MAME exited before reference readiness: $($mameProcess.ExitCode)"
    }
    Start-Sleep -Milliseconds 100
}
if (-not (Test-Path -LiteralPath $referenceReadyPath)) {
    throw 'MAME reference adapter did not publish readiness within 15 seconds'
}

$watchdog = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',
        ('"{0}"' -f (Join-Path $PSScriptRoot 'ssv_lockstep_watchdog.ps1')),
        '-LauncherPid',$PID,'-RtlPid',$rtl.Id,
        '-RtlStartTicks',$rtl.StartTime.ToUniversalTime().Ticks,
        '-RtlExecutable',('"{0}"' -f $exe),
        '-MamePid',$mameProcess.Id,
        '-MameStartTicks',$mameProcess.StartTime.ToUniversalTime().Ticks,
        '-Session',('"{0}"' -f $Session))

Write-Host "SSV_LOCKSTEP_STARTED set=$Set rtl_pid=$($rtl.Id) mame_pid=$($mameProcess.Id) session=$Session"
    $coordinatorArgs = @('--session',$Session,'--start-frame',[string]$StartFrame,
        '--frames',[string]$Frames,'--timeout',[string]$TimeoutSeconds,
        '--total-timeout',[string]$TimeoutSeconds,'--freeze-on',$FreezeOn)
    if ($RtlRestore) { $coordinatorArgs += '--reference-catchup' }
    & $python (Join-Path $PSScriptRoot 'ssv_lockstep_compare.py') @coordinatorArgs
    $coordinatorExit = $LASTEXITCODE
    if ($proofFrame -ge 0 -and $coordinatorExit -in @(0,5)) {
        # Releasing the compared proof token lets the bounded RTL model reach
        # its own gate checks and exit naturally. Do not publish STOP first or
        # SSV_VISUAL's user-quit path would bypass REQUIRE_* validation.
        if (-not $rtl.WaitForExit(30000)) {
            throw "RTL did not reach the bounded $ProofMode gate after token $proofFrame"
        }
        if ($rtl.ExitCode -ne 0) {
            throw "RTL $ProofMode gate failed with exit $($rtl.ExitCode); inspect $rtlLog"
        }
        if ($RtlRestore) {
            if (-not (Test-Path -LiteralPath $checkpointProofScreenshot) -or
                (Get-Item -LiteralPath $checkpointProofScreenshot).Length -le 0) {
                throw "Restored Verilator emitted no proof screenshot: $checkpointProofScreenshot"
            }
            Copy-Item -Force -LiteralPath $checkpointProofScreenshot `
                -Destination $proofScreenshot
        }
        if (-not (Test-Path -LiteralPath $proofScreenshot) -or
            (Get-Item -LiteralPath $proofScreenshot).Length -le 0) {
            throw "RTL $ProofMode gate emitted no non-empty screenshot: $proofScreenshot"
        }
        $gateMarker = if ($ProofMode -eq 'gameplay') { 'GAMEPLAY_FRAME f=850' }
                      else { 'PASS tb_ssv_frame_crc' }
        if (-not (Select-String -LiteralPath $rtlLog -SimpleMatch $gateMarker -Quiet) -or
            -not (Select-String -LiteralPath $rtlLog -SimpleMatch `
                    'PASS tb_ssv_frame_crc' -Quiet)) {
            throw "RTL $ProofMode gate markers are missing from $rtlLog"
        }
        @{
            schema='ssv-lockstep-proof-result-v1'; set=$Set; mode=$ProofMode
            scenario=$Scenario; proof_frame=$proofFrame; rtl_exit=$rtl.ExitCode
            screenshot=$proofScreenshot
            screenshot_bytes=(Get-Item -LiteralPath $proofScreenshot).Length
            coordinator_exit=$coordinatorExit; status='rtl_gate_pass'
        } | ConvertTo-Json | Set-Content -LiteralPath `
            (Join-Path $Session 'proof_result.json')
    }
} finally {
    Set-Content -LiteralPath (Join-Path $Session 'STOP.txt') -Value 'finite session complete'
    foreach ($entry in @(@($rtl,'rtl'),@($mameProcess,'mame'))) {
        $process = $entry[0]
        $name = $entry[1]
        if (-not $process) { continue }
        if (-not $process.WaitForExit(10000)) {
            if ($name -eq 'rtl') {
                Stop-RtlModelProcess
            }
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit()
            if ($name -eq 'rtl') { $rtlForced = $true } else { $mameForced = $true }
        }
    }
    @{
        schema='ssv-lockstep-cleanup-v1'; coordinator_exit=$coordinatorExit
        rtl_pid=$rtl.Id; rtl_exit=$(if($rtl.HasExited){$rtl.ExitCode}else{$null}); rtl_forced=$rtlForced
        rtl_closed=(-not (Get-Process -Id $rtl.Id -ErrorAction SilentlyContinue))
        mame_pid=$(if($mameProcess){$mameProcess.Id}else{$null})
        mame_exit=$(if($mameProcess -and $mameProcess.HasExited){$mameProcess.ExitCode}else{$null})
        mame_forced=$mameForced
        mame_closed=$(if($mameProcess){-not (Get-Process -Id $mameProcess.Id -ErrorAction SilentlyContinue)}else{$true})
        timestamp=(Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Session 'cleanup.json')
    # The hidden watchdog now exits as soon as cleanup.json appears. Bound the
    # wait and remove only this launcher's exact watcher if it does not.
    if ($watchdog -and -not $watchdog.WaitForExit(3000)) {
        Stop-Process -Id $watchdog.Id -Force -ErrorAction SilentlyContinue
        $watchdog.WaitForExit()
    }
}

Write-Host "SSV_LOCKSTEP_CLEANUP rtl_forced=$rtlForced mame_forced=$mameForced"
exit $coordinatorExit
