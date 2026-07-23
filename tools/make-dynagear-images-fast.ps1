[CmdletBinding()]
param(
    [string]$ZipPath = (Join-Path (Split-Path -Parent $PSScriptRoot) "rom\dynagear.zip"),
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) "sim_output\rom")
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -TypeDefinition @"
public static class DynagearRomTools {
    public static byte[] Interleave(byte[] low, byte[] high) {
        var output = new byte[low.Length + high.Length];
        for (int i = 0; i < low.Length; i++) {
            output[2 * i] = low[i];
            output[2 * i + 1] = high[i];
        }
        return output;
    }
    public static byte[] Swap16(byte[] input) {
        var output = new byte[input.Length];
        for (int i = 0; i < input.Length; i += 2) {
            output[i] = input[i + 1];
            output[i + 1] = input[i];
        }
        return output;
    }
}
"@

New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ZipPath))
try {
    function Read-Entry([string]$name) {
        $entry = $zip.GetEntry($name)
        if (-not $entry) { throw "Missing $name in $ZipPath" }
        $stream = $entry.Open()
        $memory = [IO.MemoryStream]::new()
        try { $stream.CopyTo($memory); return ,$memory.ToArray() }
        finally { $stream.Dispose(); $memory.Dispose() }
    }

    $program = [DynagearRomTools]::Interleave(
        (Read-Entry "si002-prl.u4"), (Read-Entry "si002-prh.u3"))
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "maincpu.bin"), $program)

    $sprites = [byte[]]::new(0xC00000)
    $offset = 0
    foreach ($name in "si002-01.u27","si002-04.u26","si002-02.u23",
             "si002-05.u22","si002-03.u17","si002-06.u16") {
        $raw = Read-Entry $name
        [Buffer]::BlockCopy($raw, 0, $sprites, $offset, $raw.Length)
        $offset += $raw.Length
    }
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "sprites.bin"), $sprites)

    $samples = [byte[]]::new(0x400000)
    $offset = 0
    foreach ($name in "si002-07.u9","si002-08.u8","si002-09.u7","si002-10.u6") {
        $raw = [DynagearRomTools]::Swap16((Read-Entry $name))
        [Buffer]::BlockCopy($raw, 0, $samples, $offset, $raw.Length)
        $offset += $raw.Length
    }
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "samples.bin"), $samples)
    Write-Host "Created ignored simulation images in $OutputDirectory"
}
finally {
    $zip.Dispose()
}
