param(
    [switch]$Force,
    [switch]$Savable,
    [switch]$PrintExecutable,
    [string]$ModelDir = ''
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$verilator = 'D:\vibes\fpga\bin\verilator-safe.exe'
$bash = 'D:\vibes\fpga\toolchains\msys64\usr\bin\bash.exe'
if (-not $ModelDir) {
    $workspace = $env:VERILATOR_WORKSPACE
    if (-not $workspace) { $workspace = (& $verilator workspace).Trim() }
    $ModelDir = Join-Path $workspace $(if ($Savable) { 'obj_headless_save' } else { 'obj_headless' })
}
$objDir = [System.IO.Path]::GetFullPath($ModelDir)
if (-not [System.IO.Path]::IsPathRooted($ModelDir) -or $objDir -notmatch '^[Rr]:\\Verilator\\') {
    throw "ModelDir must be an absolute R:\Verilator workspace path: $ModelDir"
}
$exe = Join-Path $objDir 'Vtb_ssv_frame_crc.exe'
if ($PrintExecutable) { Write-Output $exe; exit 0 }
foreach ($tool in @($verilator, $bash)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "Missing native UCRT64 tool: $tool" }
}

$sourceNames = @(
    'rtl/ssv_pkg.sv', 'rtl/ssv_irq.sv', 'rtl/ssv_video_timing.sv',
    'rtl/common/s32_big_dpram.sv', 'rtl/video/ssv_palette_ram.sv',
    'rtl/video/ssv_line_buffer4.sv', 'rtl/video/ssv_gfx_row_fetch.sv',
    'rtl/video/ssv_gfx_row_decode.sv', 'rtl/video/ssv_bg_renderer.sv',
    'rtl/video/ssv_mlab240_sdp.sv', 'rtl/video/ssv_cached_sprite_renderer.sv',
    'rtl/audio/ssv_mlab32_sdp.sv', 'rtl/audio/ssv_srmp7_bank.sv',
    'rtl/audio/ssv_es5506_regs.sv',
    'rtl/audio/ssv_es5506_voice.sv', 'rtl/cpu/v60/s32_v60.sv',
    'rtl/cpu/v60/s32_v60_bus.sv', 'rtl/cpu/upd96050/upd96050.sv',
    'rtl/cpu/upd96050/upd96050_st010.sv',
    'rtl/cpu/upd96050/ssv_st010_prg_fetch.sv', 'rtl/ssv_core.sv',
    'rtl/mem/sdram.sv', 'verif/ssv_tb_ce_cpu.sv',
    'verif/ssv_sdram_module.sv', 'verif/ssv_sdram_harness.sv',
    'verif/ssv_diff_probe.sv', 'verif/tb_ssv_frame_crc.sv'
)
$hostSourceName = 'verif/ssv_headless_main.cpp'
$sources = @($sourceNames | ForEach-Object { Join-Path $project $_ })
$hostSource = Join-Path $project $hostSourceName
$tracked = @($sourceNames + $hostSourceName + 'verif/ssv_tb_crc32.svh' | ForEach-Object {
    Join-Path $project $_
})
foreach ($source in $tracked) {
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing headless source: $source" }
}

$mode = if ($Savable) { 'checkpoint-acceleration' } else { 'cold-acceptance' }
$version = (& $verilator --version | Select-Object -First 1)
# Verilator's FST writer includes fstcpp_writer.cpp, which unconditionally
# includes lz4.h.  The native UCRT64 installation on some hosts has the
# runtime liblz4 DLL but not the matching development header.  Keep tracing
# available in that case by falling back to the built-in VCD writer; tracing is
# compile-time support only here (the headless harness never opens a wave).
$lz4Header = Join-Path (Split-Path -Parent $verilator) '..\include\lz4.h'
$traceArguments = @('--trace-fst')
$traceBackend = 'fst'
if (-not (Test-Path -LiteralPath ([System.IO.Path]::GetFullPath($lz4Header)))) {
    $traceArguments = @('--trace')
    $traceBackend = 'vcd-fallback-no-lz4-header'
    Write-Host "SSV_HEADLESS_TRACE_FALLBACK backend=$traceBackend header=$([System.IO.Path]::GetFullPath($lz4Header))"
}
$effectiveTiming = if ($Savable) { 'false' } else { 'true' }
$signatureText = @(
    $version,
    "mode=$mode",
    'headless=true',
    'display_backend=none',
    'threads=1',
    "timing=$effectiveTiming",
    "trace_backend=$traceBackend",
    ($tracked | ForEach-Object {
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash
        "$_|$hash"
    })
) -join "`n"
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
    $signatureBytes = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($signatureText))
} finally {
    $sha256.Dispose()
}
$signature = -join ($signatureBytes | ForEach-Object { $_.ToString('X2') })
$stamp = Join-Path $objDir 'headless.signature'
if (-not $Force -and (Test-Path -LiteralPath $exe) -and
    (Test-Path -LiteralPath $stamp) -and
    ((Get-Content -Raw -LiteralPath $stamp).Trim() -eq $signature)) {
    Write-Host "SSV_HEADLESS_CACHE_HIT executable=$exe mode=$mode"
    exit 0
}

New-Item -ItemType Directory -Force -Path $objDir | Out-Null
$timingArguments = if ($Savable) {
    # Verilator 5.050 rejects --timing together with --savable.  The
    # checkpoint profile is intentionally externally clocked by the host and
    # has its own save/restore guards in tb_ssv_frame_crc.sv.
    @('--no-timing', '--assert')
} else {
    @('--timing', '--sched-zero-delay', '--assert')
}
$profileDefines = @('+define+SIMULATION', '+define+SSV_HEADLESS_DIFF', '+define+SSV_VISUAL_EXTERNAL_CLOCK')
if ($Savable) { $profileDefines += '+define+SSV_HEADLESS_SAVABLE' }
$arguments = @(
    '--cc', '--exe', '--build'
) + $timingArguments + @(
    '--x-initial', 'unique', '--x-assign', 'unique'
) + $traceArguments + @(
    '--MMD',
    '-O3', '--threads', '1', '-j', '4', '--output-split', '20000',
    '--top-module', 'tb_ssv_frame_crc', '--Mdir', $objDir,
    $profileDefines, ('-I' + (Join-Path $project 'verif')),
    '-Wno-fatal', '-Wno-WIDTHTRUNC', '-Wno-WIDTHEXPAND', '-Wno-UNOPTFLAT',
    '-Wno-CASEINCOMPLETE', '-Wno-BLKANDNBLK', '-Wno-MULTIDRIVEN',
    '-Wno-INITIALDLY', '-Wno-DECLFILENAME', '-Wno-PINMISSING',
    '-Wno-UNSIGNED', '-Wno-WIDTH', '-Wno-CASEOVERLAP', '-Wno-UNUSED',
    '-Wno-PINCONNECTEMPTY', '-Wno-VARHIDDEN', '-Wno-UNUSEDSIGNAL'
) + $sources + @(
    $hostSource, '-CFLAGS',
    ('-O3 -march=native -D_GLIBCXX_USE_CXX11_ABI=0' +
     $(if ($Savable) { ' -DSSV_HEADLESS_SAVABLE' } else { '' }))
)
if ($Savable) { $arguments = @('--savable') + $arguments }

$priorPath = $env:PATH
$env:PATH = "D:\vibes\fpga\toolchains\msys64\ucrt64\bin;D:\vibes\fpga\toolchains\msys64\usr\bin;$priorPath"
$env:MISTER_DIFF_HEADLESS = '1'
try {
    Push-Location $project
    try { & $verilator @arguments } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "Headless Verilator build failed: $LASTEXITCODE" }
} finally {
    $env:PATH = $priorPath
}
if (-not (Test-Path -LiteralPath $exe)) { throw "Build did not produce $exe" }
Set-Content -NoNewline -LiteralPath $stamp -Value $signature
Write-Host "SSV_HEADLESS_BUILT executable=$exe mode=$mode threads=1 display_backend=none trace_backend=$traceBackend"
