[CmdletBinding()]
param(
	[string]$Receipt = "sim_output/receipts/all-focused-no-rbf.json",
	[string]$RunToken = "",
	[switch]$HardwareOnly,
	[switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$project = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$receiptPath = if ([System.IO.Path]::IsPathRooted($Receipt)) {
	[System.IO.Path]::GetFullPath($Receipt)
} else {
	[System.IO.Path]::GetFullPath((Join-Path $project $Receipt))
}
$logRoot = Join-Path ([System.IO.Path]::GetDirectoryName($receiptPath)) 'all-focused-no-rbf-logs'
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$runToken = if ($RunToken) { $RunToken } else { [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') }
$msysTempRoot = "/d/Arcade/AI/SVV/tmp/all-focused-$runToken"

function Invoke-GitText([string[]]$Arguments) {
	# A locked-down host may deny Git's optional global excludes file.  That
	# warning must not become a PowerShell NativeCommandError; the command's
	# exit status still fails closed below.
	$oldNativePreference = $PSNativeCommandUseErrorActionPreference
	$oldErrorPreference = $ErrorActionPreference
	$PSNativeCommandUseErrorActionPreference = $false
	$ErrorActionPreference = 'Continue'
	$result = & git -C $project @Arguments 2>$null
	$ErrorActionPreference = $oldErrorPreference
	$PSNativeCommandUseErrorActionPreference = $oldNativePreference
	if ($LASTEXITCODE -ne 0) { return $null }
	return (($result | Out-String).Trim())
}

$gitStatus = Invoke-GitText @('status', '--short')
$git = [ordered]@{
	head = Invoke-GitText @('rev-parse', 'HEAD')
	branch = Invoke-GitText @('branch', '--show-current')
	dirty = -not [string]::IsNullOrWhiteSpace($gitStatus)
	status_short = if ($gitStatus) { @($gitStatus -split "`r?`n") } else { @() }
}

$hardwareTops = @(
	'tb_ssv_rom_loader','tb_ssv_cfg','tb_ssv_irq','tb_ssv_video_timing',
	'tb_ssv_palette_ram','tb_ssv_clock_ratio','tb_ssv_host_guard',
	'tb_ssv_video_mode_guard','tb_ssv_input_matrix','tb_ssv_nvram_bridge',
	'tb_ssv_screen_rotate_ddram','tb_ssv_core_memory_windows',
	'tb_ssv_gfx_row_fetch','tb_ssv_bg_renderer','tb_ssv_tilemap_page',
	'tb_ssv_cached_sprite_renderer','tb_ssv_line_buffer4',
	'tb_ssv_st010_prg_fetch','tb_ssv_sdram_command_timing',
	'tb_ssv_sdram_module_contract','tb_ssv_sdram_fairness',
	'tb_ssv_loader_image','tb_ssv_scandoubler','tb_ssv_loader_core_boot',
	'tb_ssv_rom_write_ack','tb_ssv_watchdog','tb_ssv_watchdog_mode0',
	'tb_ssv_watchdog_mode2'
) -join ','

$steps = @(
	[ordered]@{ name='hardware_shape_audit'; kind='native'; argv=@('python','tools/verify_ssv_hardware_shapes.py') },
	[ordered]@{ name='python_compile'; kind='native'; argv=@('python','-m','py_compile','tools/gen_ssv_mras.py','tools/ssv_cfg_block.py','tools/ssv_supported_sets.py','tools/verify_ssv_universal_profile.py') },
	[ordered]@{ name=$(if ($HardwareOnly) { 'universal_hardware_profile' } else { 'universal_profile_media' }); kind='native'; argv=$(if ($HardwareOnly) { @('python','tools/verify_ssv_universal_profile.py') } else { @('python','tools/verify_ssv_universal_profile.py','--require-roms') }) },
	[ordered]@{ name='bringup_sims'; kind='msys'; script=$(if ($HardwareOnly) { "SSV_BRINGUP_ONLY=$hardwareTops bash verif/run_bringup_sims.sh" } else { 'bash verif/run_bringup_sims.sh' }) },
	[ordered]@{ name='audio_sims'; kind='msys'; script=$(if ($HardwareOnly) { 'UNIT_ONLY=1 bash verif/run_audio_sims.sh' } else { 'bash verif/run_audio_sims.sh' }) },
	[ordered]@{ name='v60_sims'; kind='msys'; script='bash verif/v60/run_v60_verilator.sh' },
	[ordered]@{ name='upd96050_sims'; kind='msys'; script='bash verif/upd96050/run_upd96050_verilator.sh' }
)
if (-not $HardwareOnly) {
	$steps += [ordered]@{ name='sdram_bench_build'; kind='msys'; script='JOBS=4 OUT=/d/Arcade/AI/SVV/tmp/sdram-bench bash verif/run_sdram_bench.sh build' }
	$steps += [ordered]@{ name='sdram_bench_real'; kind='msys'; script='JOBS=4 OUT=/d/Arcade/AI/SVV/tmp/sdram-bench bash verif/run_sdram_bench.sh real' }
}

$run = [ordered]@{
	schema = 'ssv-all-focused-no-rbf-receipt-v1'
	project = $project
	started_utc = [DateTime]::UtcNow.ToString('o')
	ended_utc = $null
	status = if ($DryRun) { 'dry_run' } else { 'running' }
	headless = $true
	verilator_runtime_threads = 1
	serialized = $true
	quartus_rbf = $false
	scope = if ($HardwareOnly) { 'pcb_chip_hardware_rtl_bringup_only' } else { 'all_focused' }
	git = $git
	steps = @()
}

function Write-Receipt {
	$parent = [System.IO.Path]::GetDirectoryName($receiptPath)
	New-Item -ItemType Directory -Force -Path $parent | Out-Null
	$temp = "$receiptPath.tmp"
	$run | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding utf8
	Move-Item -Force -LiteralPath $temp -Destination $receiptPath
}

Write-Receipt
$failed = $false
foreach ($step in $steps) {
	$started = [DateTime]::UtcNow
	$log = Join-Path $logRoot ($step.name + '.log')
	if ($step.kind -eq 'native') {
		$command = @($step.argv)
	} else {
		$stageTmp = "$msysTempRoot/$($step.name)"
		$msysScript = "set -euo pipefail; cd /d/Arcade/AI/SVV; export HOME=/tmp; export PATH=/c/Users/meath/bin:/ucrt64/bin:/usr/bin; export VERILATOR_ROOT=/ucrt64/share/verilator; export MISTER_DIFF_HEADLESS=1; export TMPDIR=$stageTmp; export TMP=`$TMPDIR; export TEMP=`$TMPDIR; mkdir -p `"`$TMPDIR`"; " + $step.script
		$command = @('C:\msys64\usr\bin\env.exe','MSYSTEM=UCRT64','CHERE_INVOKING=1','C:\msys64\usr\bin\bash.exe','-lc',$msysScript)
	}
	$record = [ordered]@{
		name = $step.name
		command = $command
		started_utc = $started.ToString('o')
		ended_utc = $null
		exit_code = $null
		status = if ($DryRun) { 'dry_run' } else { 'running' }
		log = $log
	}
	$run.steps += $record
	Write-Receipt
	if ($DryRun) {
		$record.ended_utc = [DateTime]::UtcNow.ToString('o')
		Write-Host ('DRY RUN: ' + ($command -join ' '))
		Write-Receipt
		continue
	}

	Push-Location $project
	try {
		$oldNativePreference = $PSNativeCommandUseErrorActionPreference
		$oldStageErrorPreference = $ErrorActionPreference
		$PSNativeCommandUseErrorActionPreference = $false
		$ErrorActionPreference = 'Continue'
		& $command[0] $command[1..($command.Count - 1)] 2>&1 |
			Tee-Object -FilePath $log
		$record.exit_code = $LASTEXITCODE
	} catch {
		$_ | Out-String | Add-Content -LiteralPath $log
		$record.exit_code = 1
	} finally {
		$PSNativeCommandUseErrorActionPreference = $oldNativePreference
		$ErrorActionPreference = $oldStageErrorPreference
		Pop-Location
	}
	$record.ended_utc = [DateTime]::UtcNow.ToString('o')
	$record.status = if ($record.exit_code -eq 0) { 'pass' } else { 'fail' }
	Write-Receipt
	if ($record.exit_code -ne 0) {
		$failed = $true
		break
	}
}

$run.ended_utc = [DateTime]::UtcNow.ToString('o')
$run.status = if ($DryRun) { 'dry_run' } elseif ($failed) { 'fail' } else { 'pass' }
Write-Receipt
Write-Host "Receipt: $receiptPath"
if ($failed) { exit 1 }
exit 0
