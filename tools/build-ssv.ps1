[CmdletBinding()]
param(
    # D:\Q17 is the LITE install, and Lite is what every build of this project
    # has used -- output_files\Arcade-SSV.fit.summary reads "SJ Lite Edition"
    # and the .qsf records LAST_QUARTUS_VERSION "17.0.2 Lite Edition". It is also
    # what the machine's QUARTUS_ROOTDIR already points at.
    #
    # The old default, C:\intelFPGA_lite\17.1, does not exist on this machine, so
    # an unqualified run failed outright -- and reaching for the other install,
    # D:\Q, is worse than failing: D:\Q is 17.0.2 STANDARD Edition. Because child
    # tools resolve through QUARTUS_ROOTDIR, a Standard quartus_sh spawns LITE
    # quartus_map, producing a mixed-edition compile that rewrites the .qsf
    # edition stamp and poisons db\ for later Lite builds. Keep this pointed at
    # the Lite install.
    [string]$QuartusRoot = "D:\Q17",
    [switch]$MapOnly,
    # Run Analysis&Synthesis -> Fitter -> TimeQuest and stop. No assembler, no
    # .rbf, no release staging. This is the measurement mode used while
    # optimizing for a future RBF: it produces the same fit/timing evidence as
    # a full compile, but cannot emit a bitstream, so it is safe to run without
    # RBF-build authorization. Mutually exclusive with -MapOnly.
    [switch]$NoAssemble,
    [Nullable[int]]$Seed,
    [switch]$SetSeedOnly,
    # Queue behind any Quartus build on this machine. Use this only for a
    # deliberate fail-fast CI probe; the default is the safe queued behavior.
    [switch]$NoWait
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$quartusBin = Join-Path $QuartusRoot "quartus\bin64"
$project = "Arcade-SSV"
$qsfPath = Join-Path $repoRoot "$project.qsf"
$slotName = "Global\MiSTer-Quartus-Build-Slot"
$slotPath = Join-Path ([IO.Path]::GetTempPath()) "mister-quartus-build-slot.json"
$slotMutex = $null
$slotOwned = $false
$slotInfo = [ordered]@{
    owner = [Environment]::UserName
    host = [Environment]::MachineName
    wrapper_pid = $PID
    process_ids = @($PID)
    project_root = $repoRoot
    revision = $project
    quartus_root = $QuartusRoot
    map_only = [bool]$MapOnly
    no_assemble = [bool]$NoAssemble
    state = "starting"
    started_utc = (Get-Date).ToUniversalTime().ToString("o")
}

function Get-BuildInputSnapshot {
    $extensions = @(
        '.qpf', '.qsf', '.qip', '.qsys', '.ip', '.tcl', '.sdc',
        '.sv', '.svh', '.v', '.vh', '.vhd', '.vhdl',
        '.mif', '.hex', '.mem'
    )
    $files = @(
        Get-ChildItem -LiteralPath $repoRoot -File -ErrorAction Stop
        foreach ($tree in @('rtl', 'sys')) {
            $treePath = Join-Path $repoRoot $tree
            if (Test-Path -LiteralPath $treePath -PathType Container) {
                Get-ChildItem -LiteralPath $treePath -Recurse -File -ErrorAction Stop
            }
        }
    ) | Where-Object {
        $extensions -contains $_.Extension.ToLowerInvariant()
    } | Sort-Object FullName -Unique

    $inputs = @($files | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($repoRoot.Length).TrimStart([char[]]'\/').Replace('\', '/')
            bytes = $_.Length
            modified_utc = $_.LastWriteTimeUtc.ToString('o')
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    })
    $gitHead = (& git -C $repoRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not record Git HEAD for build provenance.' }
    $gitStatus = @(& git -C $repoRoot status --short)
    if ($LASTEXITCODE -ne 0) { throw 'Could not record Git status for build provenance.' }
    return [ordered]@{
        project_root = $repoRoot
        project = $project
        quartus_root = $QuartusRoot
        captured_utc = (Get-Date).ToUniversalTime().ToString('o')
        git_head = $gitHead
        git_status = $gitStatus
        inputs = $inputs
    }
}

function Write-BuildInputSnapshot([object]$Snapshot, [string]$Name) {
    $snapshotDir = Join-Path $repoRoot '.codex-mister-build'
    New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null
    $path = Join-Path $snapshotDir $Name
    $Snapshot | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "Recorded build-input snapshot $path ($($Snapshot.inputs.Count) files)."
    return $path
}

function Assert-BuildInputsUnchanged([object]$Before, [object]$After) {
    $beforeComparable = [ordered]@{
        git_head = $Before.git_head
        git_status = $Before.git_status
        inputs = $Before.inputs
    } | ConvertTo-Json -Depth 6 -Compress
    $afterComparable = [ordered]@{
        git_head = $After.git_head
        git_status = $After.git_status
        inputs = $After.inputs
    } | ConvertTo-Json -Depth 6 -Compress
    if ($beforeComparable -cne $afterComparable) {
        throw 'Build inputs changed during Quartus; the generated artifact is obsolete.'
    }
    Write-Host 'Build-input fingerprint is unchanged after assembler.'
}

function Get-QuartusProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name LIKE 'quartus%'" -ErrorAction SilentlyContinue)
}

function Write-SlotRecord([string]$State, [object[]]$ProcessIds = @($PID)) {
    $slotInfo.state = $State
    $slotInfo.process_ids = @($ProcessIds | Where-Object { $null -ne $_ })
    $json = $slotInfo | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText(
        $slotPath,
        $json,
        [Text.UTF8Encoding]::new($false)
    )
}

function Read-SlotSummary {
    if (-not (Test-Path -LiteralPath $slotPath -PathType Leaf)) {
        return "owner record unavailable"
    }
    try {
        $record = Get-Content -LiteralPath $slotPath -Raw | ConvertFrom-Json
        return "PID $($record.wrapper_pid), $($record.revision), $($record.project_root), state $($record.state)"
    }
    catch {
        return "owner record unreadable"
    }
}

function Wait-QuartusSlot {
    try {
        $script:slotMutex = [Threading.Mutex]::new($false, $slotName)
    }
    catch {
        throw "Could not create the machine-wide Quartus mutex '$slotName': $($_.Exception.Message)"
    }

    $noticeAt = [DateTime]::MinValue
    while (-not $script:slotOwned) {
        try {
            $script:slotOwned = $script:slotMutex.WaitOne(1000)
        }
        catch [Threading.AbandonedMutexException] {
            # The previous wrapper died; the kernel released the mutex, and
            # this process now owns it. Replace the stale diagnostic record.
            $script:slotOwned = $true
            Write-Host "Recovered an abandoned global Quartus slot."
        }
        if (-not $script:slotOwned -and
            ((Get-Date) - $noticeAt).TotalSeconds -ge 30) {
            $noticeAt = Get-Date
            Write-Host "Waiting for the machine-wide Quartus slot ($((Read-SlotSummary)))."
        }
    }

    # A manually launched Quartus process is outside the named mutex. Do not
    # race it: release, wait, and recheck immediately before launching ours.
    while ($true) {
        $running = @(Get-QuartusProcesses)
        if ($running.Count -eq 0) {
            Write-SlotRecord "claimed"
            Write-Host "Claimed global Quartus slot for $project at $repoRoot (wrapper PID $PID)."
            return
        }

        $pids = @($running | ForEach-Object { $_.ProcessId })
        $description = ($running | ForEach-Object {
            "$($_.Name)#$($_.ProcessId)"
        }) -join ', '
        if ($NoWait) {
            $script:slotMutex.ReleaseMutex()
            $script:slotOwned = $false
            throw "Quartus processes are already active ($description); -NoWait refuses to queue."
        }
        Write-SlotRecord "waiting-for-external-quartus" (@($PID) + $pids)
        Write-Host "Quartus is active outside the wrapper ($description); waiting 30 seconds."
        $script:slotMutex.ReleaseMutex()
        $script:slotOwned = $false
        Start-Sleep -Seconds 30
        while (-not $script:slotOwned) {
            try {
                $script:slotOwned = $script:slotMutex.WaitOne(1000)
            }
            catch [Threading.AbandonedMutexException] {
                $script:slotOwned = $true
            }
        }
    }
}

function Assert-BuildPolicy {
    $qsf = Get-Content -LiteralPath $qsfPath -Raw
    $qipPath = Join-Path $repoRoot 'files.qip'
    $qip = Get-Content -LiteralPath $qipPath -Raw
    # Fast Fit is pinned because Standard Fit CRASHES quartus_fit on this
    # install (Error 293007, peak virtual memory 4649 MB, with 35 GB of host
    # RAM free) - see the note in Arcade-SSV.qsf. It is a toolchain ceiling,
    # not a preference. The pll_hdmi domain is consequently seed-sensitive
    # (+0.392 / +0.119 / -0.141 ns across three compiles); sweep SEED rather
    # than raising fitter effort.
    $required = @(
        'set_global_assignment -name FITTER_EFFORT "FAST FIT"',
        # Raised to MAXIMUM on 13 Aug 2026; see the evidence block in
        # Arcade-SSV.qsf. The pinned setting here is what the guard enforces,
        # so it has to move deliberately with the QSF rather than drift.
        # FITTER_EFFORT "FAST FIT" above is unchanged and still pinned -- it is
        # the Standard Fit *combination* that crashed quartus_fit, not this.
        'set_global_assignment -name ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM',
        'set_global_assignment -name PHYSICAL_SYNTHESIS_COMBO_LOGIC OFF',
        'set_global_assignment -name PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF',
        'set_global_assignment -name ALM_REGISTER_PACKING_EFFORT MEDIUM',
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

    if (([regex]::Matches($qsf, '(?m)^source\s+files\.qip\s*$')).Count -ne 1) {
        throw 'Arcade-SSV.qsf must source files.qip exactly once.'
    }
    if (-not $qip.Contains('rtl/video/ssv_mlab240_sdp.sv')) {
        throw 'files.qip must include the explicit memory wrapper for line_page_starts.'
    }
    if ($qsf -match '(?m)^set_global_assignment -name (SYSTEMVERILOG_FILE|VERILOG_FILE|QIP_FILE|SDC_FILE)\b') {
        throw 'User source declarations belong in files.qip, not Arcade-SSV.qsf.'
    }
    if ($qsf -match '(?m)^set_global_assignment -name VERILOG_MACRO "(?:DBG|DEBUG|DIAG|TRACE)_') {
        throw 'Release QSF contains a diagnostic Verilog macro.'
    }

    $coreRtl = Get-Content -LiteralPath (Join-Path $repoRoot 'rtl\ssv_core.sv') -Raw
    if ($coreRtl.Contains('SSV_ST010_ENABLED')) {
        throw 'ST010 must be runtime descriptor-gated, not compile-time gated.'
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

function Set-QsfSeed([int]$Value) {
    if ($Value -lt 0) {
        throw "SEED must be non-negative, got $Value."
    }
    $qsf = Get-Content -LiteralPath $qsfPath -Raw
    $seedMatches = [regex]::Matches(
        $qsf,
        '(?m)^set_global_assignment -name SEED \d+[ \t]*(?<eol>\r?\n|$)'
    )
    if ($seedMatches.Count -ne 1) {
        throw 'Arcade-SSV.qsf does not contain exactly one replaceable SEED assignment.'
    }
    $seedMatch = $seedMatches[0]
    $replacement = "set_global_assignment -name SEED $Value$($seedMatch.Groups['eol'].Value)"
    $updated = $qsf.Substring(0, $seedMatch.Index) + $replacement +
        $qsf.Substring($seedMatch.Index + $seedMatch.Length)
    [IO.File]::WriteAllText($qsfPath, $updated, [Text.UTF8Encoding]::new($false))
    Write-Host "Set Arcade-SSV.qsf SEED to $Value while holding the global Quartus slot."
}

# Quartus 17.0.2 aborts with a fatal Access Violation inside
# STA_SCC_MGR::find_and_create_scc_bypass_edges (reached from
# read_and_apply_sdc_constraints, i.e. timing-driven synthesis reading the SDC
# against the netlist) when db/ holds incremental state whose netlist shape no
# longer matches the current sources. SMART_RECOMPILE ON makes that reuse the
# default, so a structural RTL change -- removing module instances is enough --
# can turn every subsequent compile into a 20-minute crash whose message names
# neither the database nor the real cause.
#
# The crash is deterministic and survives a single-process retry, so it is not
# the concurrency hazard the global build slot already guards. Moving db/ and
# incremental_db/ aside clears it. That is a real evidence-backed reason to
# discard the incremental database, which is why this recovers automatically --
# but only once per run, only for this exact signature, and the old directories
# are preserved under tmp/ rather than deleted, so a misdiagnosis is reversible.
function Reset-QuartusDatabase([string]$Reason) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $tmpRoot = Join-Path $repoRoot 'tmp'
    New-Item -ItemType Directory -Force $tmpRoot | Out-Null
    foreach ($dir in @('db', 'incremental_db')) {
        $path = Join-Path $repoRoot $dir
        if (Test-Path -LiteralPath $path) {
            $dest = Join-Path $tmpRoot "$dir.stale-$stamp"
            Move-Item -LiteralPath $path -Destination $dest -Force
            Write-Warning "Moved $dir to tmp\$dir.stale-$stamp ($Reason)."
        }
    }
}

# Runs one Quartus stage. Returns $true on success. On a fatal Access
# Violation it returns $false so the caller can reset the database and restart
# the whole stage sequence -- a later stage cannot simply be retried on its
# own, because clearing db/ also discards the earlier stages' output.
function Invoke-QuartusStage([string]$Exe, [string]$Stage) {
    $logDir = Join-Path $repoRoot 'tmp'
    New-Item -ItemType Directory -Force $logDir | Out-Null
    $log = Join-Path $logDir "$Stage.stdout.log"
    # quartus_sta does not accept --read_settings_files/--write_settings_files;
    # passing them is a hard "Error (23024): Unknown long option" before it does
    # any analysis. Only map and fit take the settings-file switches.
    $stageArgs = if ($Stage -eq 'quartus_sta') {
        @($project, '-c', $project)
    }
    else {
        @('--read_settings_files=on', '--write_settings_files=off', $project, '-c', $project)
    }
    & $Exe @stageArgs 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    if (Select-String -Path $log -Pattern 'Fatal Error: Access Violation' -Quiet) {
        return $false
    }
    throw "$Stage failed. Inspect $log and output_files\Arcade-SSV.*.rpt."
}

function Invoke-QuartusStages([string[]]$Stages) {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $ok = $true
        foreach ($stage in $Stages) {
            $exe = Join-Path $quartusBin "$stage.exe"
            if (-not (Test-Path -LiteralPath $exe)) {
                throw "Quartus stage $stage was not found below $QuartusRoot."
            }
            Write-Host "== $stage =="
            if (-not (Invoke-QuartusStage $exe $stage)) {
                if ($attempt -ge 2) {
                    throw "$stage aborted with a fatal Access Violation against a fresh database; this is not the stale-database case."
                }
                Reset-QuartusDatabase "$stage aborted with a fatal Access Violation"
                Write-Warning 'Restarting the Quartus stage sequence once against a fresh database.'
                $ok = $false
                break
            }
        }
        if ($ok) {
            return
        }
    }
}

Push-Location $repoRoot
try {
    if ($MapOnly -and $NoAssemble) {
        throw '-MapOnly and -NoAssemble are mutually exclusive.'
    }
    Assert-BuildPolicy
    Wait-QuartusSlot

    if ($null -ne $Seed) {
        Set-QsfSeed ([int]$Seed)
    }
    if ($SetSeedOnly) {
        if ($null -eq $Seed) {
            throw '-SetSeedOnly requires -Seed.'
        }
        return
    }

    $inputSnapshotBefore = Get-BuildInputSnapshot
    $inputSnapshotBeforePath = Write-BuildInputSnapshot $inputSnapshotBefore 'Arcade-SSV-inputs-before.json'

    $map = Join-Path $quartusBin "quartus_map.exe"
    $flow = Join-Path $quartusBin "quartus_sh.exe"
    if (-not (Test-Path -LiteralPath $flow)) {
        throw "Quartus was not found below $QuartusRoot."
    }

    if ($MapOnly) {
        Invoke-QuartusStages @('quartus_map')
    }
    elseif ($NoAssemble) {
        # Explicit stages instead of --flow compile: quartus_sh's compile flow
        # always runs the assembler, which is exactly what must not happen
        # without RBF authorization.
        Invoke-QuartusStages @('quartus_map', 'quartus_fit', 'quartus_sta')
        Write-Host 'NoAssemble: fit and timing reports refreshed; no RBF was produced.'
    }
    else {
        & $flow --flow compile $project
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Quartus failed. Inspect output_files\Arcade-SSV.*.rpt."
    }

    if (-not $MapOnly -and -not $NoAssemble) {
        $inputSnapshotAfter = Get-BuildInputSnapshot
        $inputSnapshotAfterPath = Write-BuildInputSnapshot $inputSnapshotAfter 'Arcade-SSV-inputs-after.json'
        Assert-BuildInputsUnchanged $inputSnapshotBefore $inputSnapshotAfter

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
        # The universal profile intentionally retains both CPUs and every
        # descriptor-selected optional device.  After moving line metadata
        # from MLABs to available M10Ks, measured fits use about 39.4k ALMs
        # with moderate routing and no congestion.  Keep a fail-closed guard
        # below 96% of the 41,910-ALM device instead of an obsolete 38.5k cap.
        if ($usedAlms -gt 40000) {
            throw "ALM ceiling exceeded: $usedAlms > 40000."
        }
        if ($usedRamBlocks -gt 544) {
            throw "RAM-block ceiling exceeded: $usedRamBlocks > 544."
        }
        # 60, not 59. The ST010 (uPD96050) multiplier is a real DSP block, and
        # until the daughterboard was wired up at the top level its inputs were
        # tied off, so synthesis folded the multiplier away and the design
        # measured 59. Connecting sdr_p5_* and st010_drom_* made it count:
        # 22,934 -> 23,722 registers, +48 Kbit block memory, and 59 -> 60 DSP.
        # The device has 112, so this is headroom spent deliberately, not drift.
        if ($usedDsps -gt 60) {
            throw "DSP ceiling exceeded: $usedDsps > 60."
        }

        $source = Join-Path $repoRoot "output_files\Arcade-SSV.rbf"
        $releaseDir = Join-Path $repoRoot "releases"
        New-Item -ItemType Directory -Force $releaseDir | Out-Null
        $releaseName = "Arcade-SSV.rbf"
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

        # The repository's undated releases/ copy is the MRA-facing artifact.
        # Also retain the skill-required append-only, provenance-stamped copy.
        $archiveDir = Join-Path $repoRoot 'RELEASES'
        New-Item -ItemType Directory -Force $archiveDir | Out-Null
        $date = Get-Date -Format 'yyyyMMdd'
        $archiveBase = "Arcade-SSV_$date"
        $archivePath = Join-Path $archiveDir "$archiveBase.rbf"
        $collision = 0
        while (Test-Path -LiteralPath $archivePath) {
            $collision++
            $archivePath = Join-Path $archiveDir "${archiveBase}_$collision.rbf"
        }
        $archiveStaging = "$archivePath.upload"
        Copy-Item -LiteralPath $source -Destination $archiveStaging
        $archiveHash = (Get-FileHash -LiteralPath $archiveStaging -Algorithm SHA256).Hash
        if ($sourceHash -ne $archiveHash) {
            throw 'Append-only staged RBF hash does not match the Quartus output.'
        }
        Move-Item -LiteralPath $archiveStaging -Destination $archivePath
        $archiveItem = Get-Item -LiteralPath $archivePath
        Write-Host "RELEASE_RBF=$($archiveItem.FullName)"
        Write-Host "RELEASE_BYTES=$($archiveItem.Length)"
        Write-Host "RELEASE_LAST_WRITE=$($archiveItem.LastWriteTime.ToString('o'))"
        Write-Host "RELEASE_SHA256=$archiveHash"
        Write-Host "INPUT_SNAPSHOT_BEFORE=$inputSnapshotBeforePath"
        Write-Host "INPUT_SNAPSHOT_AFTER=$inputSnapshotAfterPath"
    }
}
finally {
    if ($slotOwned -and $slotMutex) {
        try {
            Write-SlotRecord "releasing"
            if (Test-Path -LiteralPath $slotPath -PathType Leaf) {
                Remove-Item -LiteralPath $slotPath -Force -ErrorAction SilentlyContinue
            }
        }
        finally {
            $slotMutex.ReleaseMutex()
            $slotOwned = $false
        }
    }
    if ($slotMutex) {
        $slotMutex.Dispose()
    }
    Pop-Location
}
