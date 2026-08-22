param()

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$verilator = 'D:\vibes\fpga\bin\verilator-safe.exe'
$safeSim = 'D:\vibes\fpga\bin\verilator-sim-safe.exe'
$workspace = (& $verilator workspace).Trim()
if (-not $workspace.StartsWith('R:\Verilator\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Unsafe Verilator workspace: $workspace"
}
$env:VERILATOR_WORKSPACE = $workspace
$objDir = Join-Path $workspace 'obj_sprite_unit'
$exe = Join-Path $objDir 'Vtb_ssv_line_buffer4.exe'
$cacheObjDir = Join-Path $workspace 'obj_sprite_cache_unit'
$cacheExe = Join-Path $cacheObjDir 'Vtb_ssv_cached_sprite_renderer.exe'
New-Item -ItemType Directory -Force -Path $objDir,$cacheObjDir | Out-Null

$priorPath = $env:PATH
$env:PATH = "D:\vibes\fpga\toolchains\msys64\ucrt64\bin;D:\vibes\fpga\toolchains\msys64\usr\bin;$priorPath"
$env:MISTER_DIFF_HEADLESS = '1'
try {
    Push-Location $project
    try {
        & $verilator --binary --build --timing --sched-zero-delay --assert `
            --x-initial unique --x-assign unique -O3 --threads 1 -j 4 `
            --top-module tb_ssv_line_buffer4 --Mdir $objDir `
            -CFLAGS '-O3 -march=native -D_GLIBCXX_USE_CXX11_ABI=0' `
            verif/tb_ssv_line_buffer4.sv `
            rtl/video/ssv_mlab88_sdp.sv rtl/video/ssv_line_buffer4.sv
        if ($LASTEXITCODE -ne 0) { throw "Sprite unit build failed: $LASTEXITCODE" }
        & $safeSim $exe
        if ($LASTEXITCODE -ne 0) { throw "Sprite unit run failed: $LASTEXITCODE" }

        & $verilator --binary --build --timing --sched-zero-delay --assert `
            --x-initial unique --x-assign unique -O3 --threads 1 -j 4 `
            --top-module tb_ssv_cached_sprite_renderer --Mdir $cacheObjDir `
            -Iverif `
            -CFLAGS '-O3 -march=native -D_GLIBCXX_USE_CXX11_ABI=0' `
            verif/ssv_cached_sprite_renderer_design.sv `
            verif/tb_ssv_cached_sprite_renderer.sv
        if ($LASTEXITCODE -ne 0) { throw "Sprite cache unit build failed: $LASTEXITCODE" }
        & $safeSim $cacheExe
        if ($LASTEXITCODE -ne 0) { throw "Sprite cache unit run failed: $LASTEXITCODE" }
    }
    finally { Pop-Location }
}
finally {
    $env:PATH = $priorPath
}
