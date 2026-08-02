param(
    [string]$Set = 'dynagear',
    [Nullable[int]]$SaveFrame = $null,
    [Nullable[long]]$SaveNativeFrame = $null,
    [string]$Restore = '',
    [string]$Checkpoint = '',
    [string]$InputJournal = '',
    [ValidateSet('none','gameplay')]
    [string]$ProofMode = 'none',
    [switch]$Detached,
    [ValidateRange(10, 600)]
    [int]$TimeoutSeconds = 120,
    [ValidateRange(0, 100000)]
    [int]$CaptureStartFrame = 850,
    [string]$Scenario = 'coin_start_p1_gameplay',
    [string]$ModelDir = 'C:\tmp\ssv_obj_visual_savable',
    [string]$OutputTag = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSHOME `
    'Modules\Microsoft.PowerShell.Utility\Microsoft.PowerShell.Utility.psd1') `
    -Force -ErrorAction Stop
$project = Split-Path -Parent $PSScriptRoot
$python = (Get-Command python -ErrorAction Stop).Source
$simSafe = 'C:\Users\meath\bin\verilator-sim-safe.exe'
$build = Join-Path $PSScriptRoot 'build_ssv_visual.ps1'
if (-not (Test-Path -LiteralPath $simSafe)) {
    throw "Missing safe simulator wrapper: $simSafe"
}

function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return (($sha.ComputeHash($stream) | ForEach-Object {
                $_.ToString('X2')
            }) -join '')
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

$manifestPath = Join-Path $project 'tools\ssv_supported_sets.py'
Push-Location (Split-Path -Parent $manifestPath)
try {
    # Avoid quoted Python dictionary keys here: native Windows argument parsing
    # strips those quotes before Python sees an inline -c command.
    $manifestJson = (& $python -c `
        'import json; from ssv_supported_sets import SUPPORTED_SET_IDS; print(json.dumps(SUPPORTED_SET_IDS, sort_keys=True))' |
        Out-String).Trim()
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0 -or -not $manifestJson) {
    throw "Unable to read authoritative set manifest: $manifestPath"
}
$setMap = $manifestJson | ConvertFrom-Json
$setEntry = $setMap.PSObject.Properties |
    Where-Object { $_.Name -ieq $Set } | Select-Object -First 1
if ($null -eq $setEntry) { throw "Unsupported SSV set: $Set" }
$Set = $setEntry.Name
$gameId = [int]$setEntry.Value

# Checkpoint runs must use the same MRA-owned DIP defaults as cold lockstep.
# The old Dyna-only FF/FD literal silently gave every other set the wrong
# cabinet configuration, which makes a restored archive ineligible evidence.
$mraPath = Get-ChildItem -LiteralPath (Join-Path $project 'mra') -Filter '*.mra' |
    Where-Object {
        try {
            ([xml](Get-Content -Raw -LiteralPath $_.FullName)).misterromdescription.setname -eq $Set
        } catch { $false }
    } | Select-Object -First 1 -ExpandProperty FullName
if (-not $mraPath) { throw "Unable to locate generated MRA for set: $Set" }
$mraXml = [xml](Get-Content -Raw -LiteralPath $mraPath)
$dipFields = @([string]$mraXml.misterromdescription.switches.default -split ',')
if ($dipFields.Count -ne 2) {
    throw "MRA switches default must contain DSW1,DSW2: $mraPath"
}
try {
    $dsw1 = [Convert]::ToInt32($dipFields[0], 16)
    $dsw2 = [Convert]::ToInt32($dipFields[1], 16)
} catch {
    throw "Invalid hexadecimal MRA switches default in ${mraPath}: $($dipFields -join ',')"
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
    if (-not (Test-Path -LiteralPath $rom)) {
        throw "Missing private simulation image: $rom"
    }
}
if ($gameId -in @(4,5,7) -and -not (Test-Path -LiteralPath $st010Rom)) {
    throw "Missing private ST010 simulation image: $st010Rom"
}

$checkpointDir = Join-Path $project 'sim_output\checkpoints'
New-Item -ItemType Directory -Force -Path $checkpointDir | Out-Null
if (-not $Checkpoint) {
    $Checkpoint = Join-Path $checkpointDir "$Set.vltsv"
}
$Checkpoint = [System.IO.Path]::GetFullPath($Checkpoint)
$journalTool = Join-Path $PSScriptRoot 'ssv_input_journal.py'
if (-not $InputJournal) { $InputJournal = "$Checkpoint.inputs" }
$InputJournal = [System.IO.Path]::GetFullPath($InputJournal)
New-Item -ItemType Directory -Force -Path $InputJournal | Out-Null
& $python $journalTool --journal $InputJournal --seed-neutral
if ($LASTEXITCODE -ne 0) { throw 'Unable to seed RTL input journal' }
$scenarioPath = Join-Path $project "verif\scenarios\$Set\$Scenario.json"
if (-not (Test-Path -LiteralPath $scenarioPath)) {
    throw "Missing deterministic scenario identity: $scenarioPath"
}
$scenarioHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $scenarioPath).Hash
if ($Restore) {
    $Restore = [System.IO.Path]::GetFullPath($Restore)
    if (-not (Test-Path -LiteralPath $Restore) -or
        (Get-Item -LiteralPath $Restore).Length -le 0) {
        throw "Restore checkpoint is missing or empty: $Restore"
    }
}
if ($null -ne $SaveFrame -and $null -ne $SaveNativeFrame) {
    throw 'Choose only one bounded save coordinate: -SaveFrame or -SaveNativeFrame'
}
if ($null -eq $SaveFrame -and $null -eq $SaveNativeFrame -and -not $Detached) {
    throw 'Use -Detached for interactive F5/Ctrl+S, or provide -SaveFrame/-SaveNativeFrame for a bounded chunk'
}

& $build -Savable -ModelDir $ModelDir
if ($LASTEXITCODE -ne 0) { throw "Savable visual build failed: $LASTEXITCODE" }
$exe = (& $build -Savable -ModelDir $ModelDir -PrintExecutable |
    Select-Object -Last 1)
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Missing savable visual executable: $exe"
}
$signaturePath = Join-Path ([System.IO.Path]::GetFullPath($ModelDir)) 'source.signature'
if (-not (Test-Path -LiteralPath $signaturePath)) {
    throw "Missing savable build signature: $signaturePath"
}
$signatureHash = Get-Sha256 $signaturePath
$mainHash = Get-Sha256 $mainRom
$spriteHash = Get-Sha256 $spriteRom
$sampleHash = Get-Sha256 $sampleRom

if ($Restore) {
    $restoreMetadataPath = "$Restore.json"
    if (Test-Path -LiteralPath $restoreMetadataPath) {
        $restoreMetadata = Get-Content -Raw -LiteralPath $restoreMetadataPath |
            ConvertFrom-Json
        $restoreArchive = Get-Item -LiteralPath $Restore
        $restoreArchiveHash = Get-Sha256 $Restore
        $metadataChecks = @{
            schema = $restoreMetadata.schema -in @(
                'ssv-verilator-checkpoint-v1','ssv-verilator-checkpoint-v2',
                'ssv-verilator-checkpoint-v3')
            set = $restoreMetadata.set -eq $Set
            game_id = [int]$restoreMetadata.game_id -eq $gameId
            scenario = $restoreMetadata.scenario -eq $Scenario
            capture_start = [int]$restoreMetadata.capture_start_frame -eq $CaptureStartFrame
            archive_size = [long]$restoreMetadata.archive_bytes -eq $restoreArchive.Length
            archive_hash = $restoreMetadata.archive_sha256 -eq $restoreArchiveHash
            source = $restoreMetadata.source_signature_sha256 -eq $signatureHash
            main = $restoreMetadata.media.maincpu_sha256 -eq $mainHash
            sprites = $restoreMetadata.media.sprites_sha256 -eq $spriteHash
            samples = $restoreMetadata.media.samples_sha256 -eq $sampleHash
            proof = $(if ($restoreMetadata.schema -in @(
                'ssv-verilator-checkpoint-v2','ssv-verilator-checkpoint-v3')) {
                $restoreMetadata.proof.mode -eq $ProofMode
            } else { $ProofMode -eq 'none' })
        }
        $failedMetadataChecks = @($metadataChecks.GetEnumerator() |
            Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
        if ($failedMetadataChecks.Count -ne 0) {
            throw "Checkpoint metadata mismatch ($($failedMetadataChecks -join ',')): $restoreMetadataPath"
        }
        $restoreCoordinateKind = if ($restoreMetadata.schema -eq `
                'ssv-verilator-checkpoint-v3') {
            [string]$restoreMetadata.coordinate.kind
        } else { 'frame' }
        $restoreCoordinateValue = if ($restoreMetadata.schema -eq `
                'ssv-verilator-checkpoint-v3') {
            [long]$restoreMetadata.coordinate.value
        } else { [long]$restoreMetadata.frame }
        if ($null -ne $SaveFrame) {
            if ($restoreCoordinateKind -ne 'frame') {
                throw 'A pre-video native-frame checkpoint must first be advanced to software video enable before using -SaveFrame'
            }
            if ($restoreCoordinateValue -ge [long]$SaveFrame) {
                throw "SaveFrame must advance beyond restored frame $restoreCoordinateValue"
            }
        }
        if ($null -ne $SaveNativeFrame) {
            if ($restoreCoordinateKind -ne 'native_frame') {
                throw 'SaveNativeFrame restore requires a native-frame checkpoint'
            }
            if ($restoreCoordinateValue -ge [long]$SaveNativeFrame) {
                throw "SaveNativeFrame must advance beyond restored native frame $restoreCoordinateValue"
            }
        }
        if ($restoreMetadata.schema -in @(
                'ssv-verilator-checkpoint-v2','ssv-verilator-checkpoint-v3')) {
            $restoreThrough = [int]$restoreMetadata.input_journal.through_frame
            $journalJson = (& $python $journalTool --journal $InputJournal `
                --through $restoreThrough | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $journalJson) {
                throw "Checkpoint input journal is incomplete through frame $restoreThrough"
            }
            $journalIdentity = $journalJson | ConvertFrom-Json
            if ($journalIdentity.semantic_sha256 -ne `
                    $restoreMetadata.input_journal.semantic_sha256 -or
                $restoreMetadata.input_identity.scenario_sha256 -ne $scenarioHash) {
                throw "Checkpoint input identity mismatch: $restoreMetadataPath"
            }
        }
    } else {
        Write-Warning "Trusted pre-metadata checkpoint restore: $Restore; the next save will add a versioned sidecar"
    }
}

$tag = if ($OutputTag) { $OutputTag } else { "${Set}_checkpoint" }
if ($tag -notmatch '^[A-Za-z0-9_-]+$') {
    throw "OutputTag contains unsupported characters: $tag"
}
$outputDir = Join-Path $project 'sim_output\checkpoint_visual'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$stdoutLog = Join-Path $outputDir "$tag.log"
$stderrLog = Join-Path $outputDir "$tag.err.log"
$statusPath = Join-Path $outputDir "$tag.status"
$screenshotPath = Join-Path $outputDir "$tag.bmp"
$crcPath = Join-Path $outputDir "$tag.frames.crc"
$statePath = Join-Path $outputDir "$tag.state.crc"
foreach ($stale in @($statusPath,"$statusPath.tmp")) {
    if (Test-Path -LiteralPath $stale) {
        Remove-Item -Force -LiteralPath $stale
    }
}
$proofFrame = -1
$proofScreenshot = $null
$modelFrameLimit = 2000000000
$modelSoakFrames = 0
if ($ProofMode -eq 'gameplay') {
    if ($null -ne $SaveNativeFrame) {
        throw 'Pre-video native-frame checkpoints cannot claim gameplay proof'
    }
    if ($Set -ne 'dynagear' -or $Scenario -notin @(
        'coin_start_p1_gameplay','coin_start_p1_long','coin_start_p1_runright')) {
        throw 'Checkpoint gameplay proof is qualified only for Dyna Gear gameplay scenarios'
    }
    $proofFrame = 850
    $modelFrameLimit = 851
    $modelSoakFrames = 851
    $proofScreenshot = Join-Path $checkpointDir `
        ('{0}-proof-gameplay-f{1:D3}.ppm' -f $Set, $proofFrame)
}

$modelArgs = @(
    ('"+MAINROM={0}"' -f ($mainRom -replace '\\','/')),
    ('"+SPRROM={0}"' -f ($spriteRom -replace '\\','/')),
    ('"+SMPROM={0}"' -f ($sampleRom -replace '\\','/')),
    ('"+FRAME_CRC={0}"' -f ($crcPath -replace '\\','/')),
    ('"+STATE_CRC={0}"' -f ($statePath -replace '\\','/')),
    "+GAME_ID=$gameId", ('+DSW1={0:X2}' -f $dsw1),
    ('+DSW2={0:X2}' -f $dsw2),
    "+STATE_START_FRAME=$CaptureStartFrame", "+SCENARIO=$Scenario",
    "+FRAMES=$modelFrameLimit", "+SOAK_FRAMES=$modelSoakFrames",
    '+CYCLES=9000000000000',
    ('"+CHECKPOINT={0}"' -f ($Checkpoint -replace '\\','/'))
)
if (Test-Path -LiteralPath $st010Rom) {
    $modelArgs += ('"+ST010ROM={0}"' -f ($st010Rom -replace '\\','/'))
}
if ($ProofMode -eq 'gameplay') {
    $modelArgs += @('+REQUIRE_GAMEPLAY', '+REQUIRE_VERILATOR_SCREENSHOT',
        '+STOP_ON_RENDERER_OVERRUN',
        ('"+DUMP_PPM={0}"' -f ($proofScreenshot -replace '\\','/')),
        "+DUMP_PPM_FRAME=$proofFrame")
}
if ($Restore) {
    $modelArgs += ('"+RESTORE={0}"' -f ($Restore -replace '\\','/'))
}
if ($null -ne $SaveFrame) {
    $modelArgs += "+SAVE_FRAME=$([int]$SaveFrame)"
}
if ($null -ne $SaveNativeFrame) {
    $modelArgs += "+SAVE_NATIVE_FRAME=$([long]$SaveNativeFrame)"
}
$safeArgs = @('--comparison','--',('"{0}"' -f $exe)) + $modelArgs

$oldStatusEnvironment = [Environment]::GetEnvironmentVariable(
    'SSV_VISUAL_STATUS', 'Process')
$oldScreenshotEnvironment = [Environment]::GetEnvironmentVariable(
    'SSV_VISUAL_SCREENSHOT', 'Process')
$oldJournalEnvironment = [Environment]::GetEnvironmentVariable(
    'SSV_RTL_INPUT_JOURNAL_DIR', 'Process')
try {
    # Process-local inheritance works on both Windows PowerShell 5.1 and
    # PowerShell 7; Start-Process -Environment is PowerShell 7-only.
    [Environment]::SetEnvironmentVariable(
        'SSV_VISUAL_STATUS', $statusPath, 'Process')
    [Environment]::SetEnvironmentVariable(
        'SSV_VISUAL_SCREENSHOT', $screenshotPath, 'Process')
    [Environment]::SetEnvironmentVariable(
        'SSV_RTL_INPUT_JOURNAL_DIR', $InputJournal, 'Process')
    $process = Start-Process -FilePath $simSafe -ArgumentList $safeArgs `
        -WorkingDirectory $project -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog -PassThru
} finally {
    [Environment]::SetEnvironmentVariable(
        'SSV_VISUAL_STATUS', $oldStatusEnvironment, 'Process')
    [Environment]::SetEnvironmentVariable(
        'SSV_VISUAL_SCREENSHOT', $oldScreenshotEnvironment, 'Process')
    [Environment]::SetEnvironmentVariable(
        'SSV_RTL_INPUT_JOURNAL_DIR', $oldJournalEnvironment, 'Process')
}

# Refuse to strand an interactive window or consume MAME/runtime resources
# while another chat owns the safe model slot.
$child = $null
$slotDeadline = (Get-Date).AddSeconds(15)
while ((Get-Date) -lt $slotDeadline) {
    if ($process.HasExited) {
        throw "Safe wrapper exited before launching the model: $($process.ExitCode)"
    }
    $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id)" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($exe) } |
        Select-Object -First 1
    if ($child) { break }
    Start-Sleep -Milliseconds 100
}
if (-not $child) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    $process.WaitForExit()
    throw 'Safe simulation slot was busy; checkpoint visual was not launched'
}

Write-Host "SSV_CHECKPOINT_VISUAL_STARTED set=$Set wrapper_pid=$($process.Id) model_pid=$($child.ProcessId) checkpoint=$Checkpoint"
if ($Detached) {
    Write-Host 'SSV_CHECKPOINT_VISUAL_CONTROLS F5/Ctrl+S saves at the next completed native frame; close the SDL window to exit.'
    exit 0
}

if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($process.Id)" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($exe) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    $process.WaitForExit()
    throw "Checkpoint chunk exceeded the $TimeoutSeconds-second wall-clock ceiling"
}
if ($process.ExitCode -ne 0) {
    throw "Checkpoint visual exited $($process.ExitCode); inspect $stdoutLog and $stderrLog"
}
if (-not (Test-Path -LiteralPath $Checkpoint) -or
    (Get-Item -LiteralPath $Checkpoint).Length -le 0) {
    throw "Checkpoint run emitted no nonempty archive: $Checkpoint"
}
$saveCoordinateName = if ($null -ne $SaveNativeFrame) {
    'native_frame'
} else { 'frame' }
$saveCoordinateValue = if ($null -ne $SaveNativeFrame) {
    [long]$SaveNativeFrame
} else { [long]$SaveFrame }
$saveMarker = "SSV_VISUAL_CHECKPOINT_SAVED ${saveCoordinateName}=$saveCoordinateValue"
if (-not (Select-String -LiteralPath $stdoutLog -SimpleMatch $saveMarker -Quiet)) {
    throw "Checkpoint save marker is missing: $saveMarker"
}
if (-not (Select-String -LiteralPath $stdoutLog -SimpleMatch `
        'SSV_VISUAL_WINDOW_OPEN' -Quiet)) {
    throw "Native visual window did not open; inspect $stdoutLog"
}
if ($Restore -and -not (Select-String -LiteralPath $stdoutLog -SimpleMatch `
        'SSV_RESTORE_OK' -Quiet)) {
    throw "Fresh-process restore marker is missing; inspect $stdoutLog"
}

$archive = Get-Item -LiteralPath $Checkpoint
$journalThrough = if ($null -ne $SaveNativeFrame) { 0 } else {
    [int]$SaveFrame + 1
}
$journalJson = (& $python $journalTool --journal $InputJournal `
    --through $journalThrough | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $journalJson) {
    throw "Saved checkpoint lacks an RTL-owned input prefix through frame $journalThrough"
}
$journalIdentity = $journalJson | ConvertFrom-Json
$metadataPath = "$Checkpoint.json"
$metadataTemporary = "$metadataPath.tmp"
$metadataBackup = "$metadataPath.bak"
$metadata = @{
    schema = 'ssv-verilator-checkpoint-v3'
    set = $Set
    game_id = $gameId
    frame = $(if ($null -ne $SaveFrame) { [int]$SaveFrame } else { -1 })
    coordinate = @{
        kind = $saveCoordinateName
        value = $saveCoordinateValue
    }
    scenario = $Scenario
    capture_start_frame = $CaptureStartFrame
    archive = $archive.FullName
    archive_bytes = $archive.Length
    archive_sha256 = Get-Sha256 $archive.FullName
    source_signature_sha256 = $signatureHash
    verilator = (& 'C:\Users\meath\bin\verilator.exe' --version | Select-Object -First 1)
    top = 'tb_ssv_frame_crc'
    media = @{
        maincpu_sha256 = $mainHash
        sprites_sha256 = $spriteHash
        samples_sha256 = $sampleHash
    }
    input_journal = $journalIdentity
    input_identity = @{
        scenario_path = [System.IO.Path]::GetFullPath($scenarioPath)
        scenario_sha256 = $scenarioHash
        owner = 'rtl'
        packet_for_first_post_restore_frame = $journalThrough
    }
    proof = @{
        mode = $ProofMode
        frame = $(if ($proofFrame -ge 0) { $proofFrame } else { $null })
        screenshot = $proofScreenshot
        max_frames = $modelFrameLimit
        soak_frames = $modelSoakFrames
    }
    restored_from = $(if ($Restore) { $Restore } else { $null })
    timestamp = (Get-Date).ToUniversalTime().ToString('o')
}
$metadata | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $metadataTemporary
if (Test-Path -LiteralPath $metadataPath) {
    if (Test-Path -LiteralPath $metadataBackup) {
        Remove-Item -Force -LiteralPath $metadataBackup
    }
    Move-Item -LiteralPath $metadataPath -Destination $metadataBackup
}
Move-Item -LiteralPath $metadataTemporary -Destination $metadataPath
Write-Host "SSV_CHECKPOINT_VISUAL_PASS set=$Set ${saveCoordinateName}=$saveCoordinateValue bytes=$($archive.Length) path=$($archive.FullName)"
