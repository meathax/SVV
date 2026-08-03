param(
    [string]$Set = 'dynagear',
    [ValidateRange(0, 9)]
    [Nullable[int]]$GameId = $null,
    [switch]$Detached,
    [int]$VerifyTimeoutSeconds = 300,
    [int]$DumpTilemapFrame = -1,
    [string]$ModelDir = 'C:\tmp\ssv_obj_visual',
    [string]$OutputTag = '',
    [ValidateRange(8000, 192000)]
    [int]$AudioOutputRate = 48000,
    [ValidateRange(5, 500)]
    [int]$AudioPrimeMs = 40,
    [ValidateRange(20, 2000)]
    [int]$AudioMaxQueueMs = 250
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$buildScript = Join-Path $PSScriptRoot 'build_ssv_visual.ps1'
$simSafe = 'C:\Users\meath\bin\verilator-sim-safe.exe'
if (-not (Test-Path -LiteralPath $simSafe)) { throw "Missing safe simulator wrapper: $simSafe" }

$manifestPath = Join-Path $project 'tools\ssv_supported_sets.py'
$python = Get-Command python -ErrorAction Stop
$manifestJson = (& $python.Source -c `
    'import json, runpy, sys; ns = runpy.run_path(sys.argv[1]); print(json.dumps(ns["SUPPORTED_SET_IDS"], sort_keys=True))' `
    $manifestPath | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $manifestJson) {
    throw "Unable to read authoritative SSV set manifest: $manifestPath"
}
try {
    $setMap = $manifestJson | ConvertFrom-Json
} catch {
    throw "Invalid authoritative SSV set manifest output: $($_.Exception.Message)"
}
$setEntry = $setMap.PSObject.Properties |
    Where-Object { $_.Name -ieq $Set } |
    Select-Object -First 1
if ($null -eq $setEntry) {
    throw "Set is not in the authoritative SSV supported-set manifest: $Set"
}
$Set = $setEntry.Name
$resolvedGameId = [int]$setEntry.Value
if ($null -ne $GameId -and [int]$GameId -ne $resolvedGameId) {
    throw "Set/GameId mismatch: $Set requires GameId $resolvedGameId, not $GameId"
}

$romDir = if ($Set -eq 'dynagear') {
    Join-Path $project 'sim_output\rom'
} else {
    Join-Path $project "sim_output\rom\$Set"
}
$mainRom = Join-Path $romDir 'maincpu.bin'
$spriteRom = Join-Path $romDir 'sprites.bin'
$sampleRom = Join-Path $romDir 'samples.bin'
foreach ($rom in @($mainRom, $spriteRom, $sampleRom)) {
    if (-not (Test-Path -LiteralPath $rom)) { throw "Missing private simulation image: $rom" }
}

$outputDir = Join-Path $project 'sim_output\visual'
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$runTag = if ($OutputTag) { $OutputTag } else { $Set }
if ($runTag -notmatch '^[A-Za-z0-9_-]+$') {
    throw "OutputTag may contain only letters, digits, underscores, and hyphens: $runTag"
}
if ($AudioPrimeMs -ge $AudioMaxQueueMs) {
    throw "AudioPrimeMs must be lower than AudioMaxQueueMs"
}
$stdoutLog = Join-Path $outputDir "${runTag}_visual.log"
$stderrLog = Join-Path $outputDir "${runTag}_visual.err.log"
$statusPath = Join-Path $outputDir "${runTag}_visual.status"
$screenshotPath = Join-Path $outputDir "${runTag}_visual_latest.bmp"
$crcPath = Join-Path $outputDir "${runTag}_visual_frames.crc"
$tagLockPath = Join-Path $outputDir "${runTag}_visual.lock.json"

if (-not ('SsvVisual.NativeWindow' -as [type])) {
    Add-Type -Namespace SsvVisual -Name NativeWindow -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindow(System.IntPtr hWnd);
'@
}

function Read-VisualStatusFields([string]$Path, [int]$Attempts = 8) {
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Path) {
                $raw = (Get-Content -Raw -LiteralPath $Path -ErrorAction Stop).Trim()
                if ($raw) { return @($raw -split '\s+') }
            }
        } catch [System.IO.IOException] {
            # The producer replaces the status file once per frame.
        } catch [System.UnauthorizedAccessException] {
            # A sharing violation is transient on Windows; retry below.
        }
        if ($attempt + 1 -lt $Attempts) { Start-Sleep -Milliseconds 20 }
    }
    return $null
}

function Assert-OutputTagAvailable {
    if (Test-Path -LiteralPath $tagLockPath) {
        $lockItem = Get-Item -LiteralPath $tagLockPath
        $record = $null
        try {
            $record = Get-Content -Raw -LiteralPath $tagLockPath |
                ConvertFrom-Json -ErrorAction Stop
        } catch {
            if ($lockItem.LastWriteTimeUtc -gt (Get-Date).ToUniversalTime().AddMinutes(-1)) {
                throw "OutputTag is currently reserved by another launcher: $runTag"
            }
        }
        if ($null -ne $record -and $null -ne $record.pid) {
            $owner = Get-Process -Id ([int]$record.pid) -ErrorAction SilentlyContinue
            if ($owner) {
                $sameProcess = $true
                if ($null -ne $record.start_ticks) {
                    try {
                        $sameProcess =
                            $owner.StartTime.ToUniversalTime().Ticks -eq [int64]$record.start_ticks
                    } catch {
                        $sameProcess = $true
                    }
                }
                if ($sameProcess) {
                    throw "OutputTag is already active: $runTag (pid=$($owner.Id))"
                }
            }
        }
        Remove-Item -Force -LiteralPath $tagLockPath
    }

    $legacyFields = Read-VisualStatusFields -Path $statusPath
    if ($null -ne $legacyFields -and $legacyFields.Count -ge 9) {
        $legacyHandle = [uint64]$legacyFields[7]
        $legacyFlags = [uint32]$legacyFields[8]
        if ($legacyHandle -ne 0 -and ($legacyFlags -band 4) -ne 0 -and
            [SsvVisual.NativeWindow]::IsWindow(
                [IntPtr]::new([int64]$legacyHandle))) {
            throw "OutputTag is already owned by a visible legacy run: $runTag"
        }
    }
}

function Remove-OwnedTagLock([int]$OwnerPid) {
    if (-not (Test-Path -LiteralPath $tagLockPath)) { return }
    try {
        $record = Get-Content -Raw -LiteralPath $tagLockPath | ConvertFrom-Json
        if ([int]$record.pid -eq $OwnerPid) {
            Remove-Item -Force -LiteralPath $tagLockPath
        }
    } catch {
        # Keep an ambiguous lock; the next launcher applies stale-lock checks.
    }
}

Assert-OutputTagAvailable
$launcher = Get-Process -Id $PID
$reservation = @{
    pid = $PID
    start_ticks = $launcher.StartTime.ToUniversalTime().Ticks
    kind = 'launcher_reservation'
    output_tag = $runTag
} | ConvertTo-Json -Compress
try {
    $lockStream = [System.IO.File]::Open(
        $tagLockPath, [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $lockBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($reservation)
        $lockStream.Write($lockBytes, 0, $lockBytes.Length)
    } finally {
        $lockStream.Dispose()
    }
} catch [System.IO.IOException] {
    throw "OutputTag was reserved concurrently by another launcher: $runTag"
}

try {
    & $buildScript -ModelDir $ModelDir
    if ($LASTEXITCODE -ne 0) { throw "Visual build failed: $LASTEXITCODE" }
    $exe = (& $buildScript -ModelDir $ModelDir -PrintExecutable |
        Select-Object -Last 1)
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Missing visual executable: $exe"
    }
} catch {
    Remove-OwnedTagLock -OwnerPid $PID
    throw
}

foreach ($stale in @($statusPath, "$statusPath.tmp")) {
    if (Test-Path -LiteralPath $stale) { Remove-Item -Force -LiteralPath $stale }
}

Write-Warning 'The SSV live visual timing model has no full-state checkpoint support; F5/Ctrl+S reports this in the window log.'
Write-Host "SSV_VISUAL_AUDIO_CONFIG output_rate=$AudioOutputRate prime_ms=$AudioPrimeMs max_queue_ms=$AudioMaxQueueMs"
$arguments = @(
    ('"+MAINROM={0}"' -f ($mainRom -replace '\\', '/')),
    ('"+SPRROM={0}"' -f ($spriteRom -replace '\\', '/')),
    ('"+SMPROM={0}"' -f ($sampleRom -replace '\\', '/')),
    ('"+FRAME_CRC={0}"' -f ($crcPath -replace '\\', '/')),
    "+GAME_ID=$resolvedGameId", '+SCENARIO=visual_live',
    '+FRAMES=2000000000', '+SOAK_FRAMES=0', '+CYCLES=9000000000000'
)
if ($DumpTilemapFrame -ge 0) {
    $arguments += "+DUMP_TILEMAP=$DumpTilemapFrame"
}

$oldStatus = $env:SSV_VISUAL_STATUS
$oldScreenshot = $env:SSV_VISUAL_SCREENSHOT
$oldAudioRate = $env:SSV_VISUAL_AUDIO_RATE
$oldAudioPrime = $env:SSV_VISUAL_AUDIO_PRIME_MS
$oldAudioMaxQueue = $env:SSV_VISUAL_AUDIO_MAX_QUEUE_MS
try {
    $env:SSV_VISUAL_STATUS = $statusPath
    $env:SSV_VISUAL_SCREENSHOT = $screenshotPath
    $env:SSV_VISUAL_AUDIO_RATE = [string]$AudioOutputRate
    $env:SSV_VISUAL_AUDIO_PRIME_MS = [string]$AudioPrimeMs
    $env:SSV_VISUAL_AUDIO_MAX_QUEUE_MS = [string]$AudioMaxQueueMs
    $safeArguments = @('--', $exe) + $arguments
    $process = Start-Process -FilePath $simSafe -ArgumentList $safeArguments `
        -WorkingDirectory $project `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru
} catch {
    Remove-OwnedTagLock -OwnerPid $PID
    throw
} finally {
    $env:SSV_VISUAL_STATUS = $oldStatus
    $env:SSV_VISUAL_SCREENSHOT = $oldScreenshot
    $env:SSV_VISUAL_AUDIO_RATE = $oldAudioRate
    $env:SSV_VISUAL_AUDIO_PRIME_MS = $oldAudioPrime
    $env:SSV_VISUAL_AUDIO_MAX_QUEUE_MS = $oldAudioMaxQueue
}

$processLock = @{
    pid = $process.Id
    start_ticks = $process.StartTime.ToUniversalTime().Ticks
    kind = 'visual_process'
    output_tag = $runTag
    executable = $exe
} | ConvertTo-Json -Compress
Set-Content -NoNewline -LiteralPath $tagLockPath -Value $processLock

Write-Host "SSV_VISUAL_STARTED set=$Set game_id=$resolvedGameId pid=$($process.Id) executable=$exe"
Write-Host "SSV_VISUAL_LOG stdout=$stdoutLog stderr=$stderrLog"

$deadline = (Get-Date).AddSeconds($VerifyTimeoutSeconds)
$windowHandle = [IntPtr]::Zero
$verifiedFrame = -1
$verifiedChecksum = 0
$verifiedChanges = 0
$verifiedWindowFlags = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 250
    $live = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    if (-not $live) {
        Remove-OwnedTagLock -OwnerPid $process.Id
        $tail = if (Test-Path -LiteralPath $stderrLog) {
            (Get-Content -Tail 30 -LiteralPath $stderrLog) -join "`n"
        } else { '<no stderr log>' }
        throw "Visual process exited before verification. stderr:`n$tail"
    }
    $live.Refresh()
    $fields = Read-VisualStatusFields -Path $statusPath
    if ($null -ne $fields) {
        if ($fields.Count -ge 5) {
            $verifiedFrame = [int64]$fields[0]
            $verifiedChecksum = [uint32]$fields[1]
            $verifiedChanges = [int64]$fields[2]
        }
        if ($fields.Count -ge 9) {
            $nativeHandle = [uint64]$fields[7]
            $verifiedWindowFlags = [uint32]$fields[8]
            if ($nativeHandle -ne 0)
                { $windowHandle = [IntPtr]::new([int64]$nativeHandle) }
        }
    }
    if ($windowHandle -ne [IntPtr]::Zero -and
        ($verifiedWindowFlags -band 4) -ne 0 -and
        $verifiedFrame -gt 0 -and $verifiedChanges -gt 0) { break }
}

if ($windowHandle -eq [IntPtr]::Zero) {
    throw "SDL process $($process.Id) did not expose a native window handle within $VerifyTimeoutSeconds seconds"
}
if (($verifiedWindowFlags -band 4) -eq 0) {
    throw "SDL native window 0x$('{0:x}' -f $windowHandle.ToInt64()) was not reported shown within $VerifyTimeoutSeconds seconds"
}
if ($verifiedFrame -le 0 -or $verifiedChanges -le 0) {
    throw "SDL window opened, but changing video was not proven within $VerifyTimeoutSeconds seconds (frame=$verifiedFrame changes=$verifiedChanges)"
}

Write-Host ("SSV_VISUAL_VERIFIED pid={0} hwnd=0x{1:x} frame={2} checksum={3:x8} changes={4}" -f `
    $process.Id, $windowHandle.ToInt64(), $verifiedFrame, $verifiedChecksum, $verifiedChanges)
Write-Host 'SSV_VISUAL_RUNNING The simulator remains open until the user closes the SDL window.'

if (-not $Detached) {
    $process.WaitForExit()
    Remove-OwnedTagLock -OwnerPid $process.Id
    Write-Host "SSV_VISUAL_RUNTIME_EXIT $($process.ExitCode)"
    exit $process.ExitCode
}
