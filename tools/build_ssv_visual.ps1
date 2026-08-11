param(
    [switch]$Force,
    [switch]$Profile,
    [switch]$Savable,
    [switch]$Headless,
    [switch]$PrintExecutable,
    [string]$ModelDir = 'C:\tmp\ssv_obj_visual'
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$verilator = 'C:\Users\meath\bin\verilator-safe.exe'
$pkgConfig = 'C:\msys64\ucrt64\bin\pkg-config.exe'
$bash = 'C:\msys64\usr\bin\bash.exe'
$objDir = [System.IO.Path]::GetFullPath($ModelDir)
if (-not [System.IO.Path]::IsPathRooted($ModelDir) -or
    $objDir -notmatch '^[A-Za-z]:\\') {
    throw "ModelDir must be an absolute drive path: $ModelDir"
}
if ($objDir -notmatch '^[A-Za-z]:\\[A-Za-z0-9_.\\-]+$') {
    throw "ModelDir must use a no-space, shell-safe absolute drive path: $ModelDir"
}
$exe = Join-Path $objDir 'Vtb_ssv_frame_crc.exe'
$stamp = Join-Path $objDir 'source.signature'
$modeStamp = Join-Path $objDir 'build.mode'
$buildMode = if ($Headless -and $Savable) { 'savable-headless' } `
    elseif ($Headless) { 'headless' } `
    elseif ($Savable) { 'savable' } `
    elseif ($Profile) { 'profile' } else { 'release' }
if ($Savable -and $Profile) {
    throw '-Savable and -Profile require distinct builds and cannot be combined'
}
if (Test-Path -LiteralPath $modeStamp) {
    $priorMode = (Get-Content -Raw -LiteralPath $modeStamp).Trim()
    if ($priorMode -and $priorMode -ne $buildMode) {
        throw "ModelDir $objDir belongs to '$priorMode'; use a distinct directory for '$buildMode'"
    }
}

function ConvertTo-PowerShellLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

if ($PrintExecutable) {
    Write-Output $exe
    exit 0
}

foreach ($tool in @($verilator, $pkgConfig, $bash)) {
    if (-not (Test-Path -LiteralPath $tool)) { throw "Missing build tool: $tool" }
}

$coreSources = @(
    'rtl/ssv_pkg.sv',
    'rtl/ssv_irq.sv',
    'rtl/ssv_video_timing.sv',
    'rtl/common/s32_big_dpram.sv',
    'rtl/video/ssv_palette_ram.sv',
    'rtl/video/ssv_line_buffer4.sv',
    'rtl/video/ssv_gfx_row_fetch.sv',
    'rtl/video/ssv_gfx_row_decode.sv',
    'rtl/video/ssv_bg_renderer.sv',
    'rtl/video/ssv_mlab240_sdp.sv',
    'rtl/video/ssv_cached_sprite_renderer.sv',
    'rtl/audio/ssv_mlab32_sdp.sv',
    'rtl/audio/ssv_es5506_regs.sv',
    'rtl/audio/ssv_es5506_voice.sv',
    'rtl/cpu/v60/s32_v60.sv',
    'rtl/cpu/v60/s32_v60_bus.sv',
    'rtl/cpu/upd96050/upd96050.sv',
    'rtl/cpu/upd96050/upd96050_st010.sv',
    'rtl/cpu/upd96050/ssv_st010_prg_fetch.sv',
    'rtl/ssv_core.sv',
    'rtl/mem/sdram.sv',
    'verif/ssv_tb_ce_cpu.sv',
    'verif/tb_ssv_frame_crc.sv'
)
$visualMainSource = Join-Path $project 'verif/ssv_visual_main.cpp'
$hostSource = if ($Headless) {
    Join-Path $project 'verif/ssv_visual_headless.cpp'
} else {
    Join-Path $project 'verif/ssv_visual_sdl.cpp'
}
$trackedInputs = @($coreSources | ForEach-Object { Join-Path $project $_ }) + @(
    $hostSource,
    (Join-Path $project 'verif/ssv_tb_crc32.svh'),
    $PSCommandPath
)
if ($Savable) { $trackedInputs += $visualMainSource }
foreach ($source in $trackedInputs) {
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing visual source: $source" }
}

$verilatorVersion = (& $verilator --version | Select-Object -First 1)
$sdlCflags = ''
$sdlLibs = ''
if (-not $Headless) {
    $sdlCflags = ((& $pkgConfig --cflags sdl2) -replace '-Dmain=SDL_main', '').Trim()
    $sdlLibs = ((& $pkgConfig --libs sdl2) `
        -replace '-lmingw32', '' `
        -replace '-mwindows', '' `
        -replace '-lSDL2main', '').Trim()
    if ($LASTEXITCODE -ne 0) { throw 'SDL2 pkg-config lookup failed' }
}

$saveDefine = if ($Savable) { '' } else { ' -DSSV_VISUAL_NO_SAVE' }
$headlessDefine = if ($Headless) { ' -DSSV_HEADLESS' } else { ' -DSDL_MAIN_HANDLED' }
$cflags = "$sdlCflags$headlessDefine$saveDefine -D_GLIBCXX_USE_CXX11_ABI=0 -O3 -march=native -mtune=native"
if (-not $Profile) { $cflags += ' -fomit-frame-pointer' }
$buildProfile = @(
    'top=tb_ssv_frame_crc',
    "mode=$buildMode",
    "headless=$($Headless.ToString().ToLowerInvariant())",
    "display_backend=$(if($Headless){'none'}else{'sdl2'})",
    "defines=SIMULATION,SSV_VISUAL,SSV_VISUAL_BEHAVIORAL_ONLY,$(if($Savable){'SSV_VISUAL_EXTERNAL_CLOCK'}else{'SSV_VISUAL_NO_SAVE'})",
    "timing=$(if($Savable){'off'}else{'on'}),savable=$(if($Savable){'on'}else{'off'}),assert=on",
    'model_threads=1',
    'verilate_jobs=4,build_jobs=4',
    'verilator_opt=-O3',
    "source_profile=$([bool]$Profile)",
    "cflags=$cflags",
    "ldflags=$sdlLibs"
) -join "`n"
$sourceHashes = ($trackedInputs | ForEach-Object {
    $item = Get-Item -LiteralPath $_
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_).Hash
    "$($item.FullName)|$($item.Length)|$hash"
}) -join "`n"
$signature = "$verilatorVersion`n$buildProfile`n$sourceHashes"

if (-not $Force -and (Test-Path -LiteralPath $exe) -and
    (Test-Path -LiteralPath $stamp) -and
    ((Get-Content -Raw -LiteralPath $stamp) -eq $signature)) {
    Write-Host "SSV_VISUAL_CACHE_HIT executable=$exe"
    Write-Host "SSV_VISUAL_VERILATOR $verilatorVersion"
    Set-Content -NoNewline -LiteralPath $modeStamp -Value $buildMode
    exit 0
}

New-Item -ItemType Directory -Force -Path $objDir | Out-Null
$hostName = if ($Headless) { 'ssv_visual_headless.cpp' } else { 'ssv_visual_sdl.cpp' }
$visualCpp = Join-Path $objDir $hostName
Copy-Item -Force -LiteralPath $hostSource -Destination $visualCpp
$visualMainCpp = Join-Path $objDir 'ssv_visual_main.cpp'
if ($Savable) {
    Copy-Item -Force -LiteralPath $visualMainSource -Destination $visualMainCpp
}

$visualSources = @($visualCpp)
if ($Savable) { $visualSources += $visualMainCpp }

$arguments = @(
    '--cc', '--exe', '--assert', '-O3',
    '-Wno-fatal', '-Wno-WIDTHTRUNC', '-Wno-WIDTHEXPAND', '-Wno-UNOPTFLAT',
    '-Wno-CASEINCOMPLETE', '-Wno-BLKANDNBLK', '-Wno-MULTIDRIVEN',
    '-Wno-INITIALDLY', '-Wno-DECLFILENAME', '-Wno-PINMISSING',
    '-Wno-UNSIGNED', '-Wno-WIDTH', '-Wno-CASEOVERLAP', '-Wno-UNUSED',
    '-Wno-PINCONNECTEMPTY', '-Wno-VARHIDDEN', '-Wno-UNUSEDSIGNAL',
    '+define+SIMULATION', '-DSSV_VISUAL',
    '+define+SSV_VISUAL_BEHAVIORAL_ONLY', '-Iverif',
    '--top-module', 'tb_ssv_frame_crc', '--Mdir', $objDir,
    '--threads', '1', '--verilate-jobs', '4'
) + $coreSources + $visualSources + @(
    '-CFLAGS', $cflags, '-LDFLAGS', $sdlLibs
)
if ($Savable) {
    $arguments = @('--no-timing', '--savable',
                   '+define+SSV_VISUAL_EXTERNAL_CLOCK') +
                 $arguments
} else {
    $arguments = @('--main', '--timing',
                   '+define+SSV_VISUAL_NO_SAVE') + $arguments
}
if ($Profile) {
    $arguments = @('--prof-cfuncs') + $arguments
}
$generationCommand = "& $(ConvertTo-PowerShellLiteral $verilator) " +
    (($arguments | ForEach-Object {
        ConvertTo-PowerShellLiteral ([string]$_)
    }) -join ' ')
Write-Host "SSV_VISUAL_VERILATOR $verilatorVersion"
Write-Host "SSV_VISUAL_TOP tb_ssv_frame_crc"
Write-Host "SSV_VISUAL_GENERATE_COMMAND $generationCommand"

Push-Location $project
try {
    & $verilator @arguments
    $generationExit = $LASTEXITCODE
} finally {
    Pop-Location
}
Write-Host "SSV_VISUAL_GENERATE_EXIT $generationExit"
if ($generationExit -ne 0) { throw "Visual Verilator generation failed: $generationExit" }

$msysTemp = Join-Path $objDir 'msys_tmp'
New-Item -ItemType Directory -Force -Path $msysTemp | Out-Null
$objMsys = ('/{0}/{1}' -f $objDir.Substring(0, 1).ToLowerInvariant(),
    ($objDir.Substring(3) -replace '\\', '/'))
$tempMsys = ('/{0}/{1}' -f $msysTemp.Substring(0, 1).ToLowerInvariant(),
    ($msysTemp.Substring(3) -replace '\\', '/'))
$makeOptimization = if ($Headless) {
    " OPT_FAST='-O3 -march=native -mtune=native' OPT_SLOW='-O3 -march=native -mtune=native'"
} else { '' }
$makeCommand = "export MSYSTEM=UCRT64; export PATH=/ucrt64/bin:/usr/bin; " +
    "export TMP='$tempMsys'; export TEMP=`$TMP; export TMPDIR=`$TMP; " +
    "cd '$objMsys'; mingw32-make -f Vtb_ssv_frame_crc.mk -j4$makeOptimization"
$buildCommand = "& $(ConvertTo-PowerShellLiteral $bash) " +
    "'--noprofile' '--norc' '-c' $(ConvertTo-PowerShellLiteral $makeCommand)"
Write-Host "SSV_VISUAL_BUILD_COMMAND $buildCommand"
& $bash --noprofile --norc -c $makeCommand
$buildExit = $LASTEXITCODE
Write-Host "SSV_VISUAL_BUILD_EXIT $buildExit"
if ($buildExit -ne 0) { throw "Visual Verilator C++ build failed: $buildExit" }
if (-not (Test-Path -LiteralPath $exe)) { throw "Build did not produce $exe" }

Set-Content -NoNewline -LiteralPath $stamp -Value $signature
Set-Content -NoNewline -LiteralPath $modeStamp -Value $buildMode
Write-Host "SSV_VISUAL_BUILT executable=$exe"
