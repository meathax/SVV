[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("cairblad", "vasara", "vasara2")]
    [string]$Game,
    [string]$ZipPath = "",
    [string]$OutputDirectory = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not $ZipPath) {
    $ZipPath = Join-Path (Split-Path -Parent $PSScriptRoot) ("rom\{0}.zip" -f $Game)
}
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) ("sim_output\rom\{0}" -f $Game)
}

Add-Type -TypeDefinition @"
using System;

public static class SsvFamilyRomTools {
    public static byte[] Swap16(byte[] input) {
        byte[] output = new byte[input.Length];
        for (int i = 0; i < input.Length; i += 2) {
            output[i] = input[i + 1];
            output[i + 1] = input[i];
        }
        return output;
    }

    public static byte[] Interleave(byte[] low, byte[] high) {
        byte[] output = new byte[low.Length + high.Length];
        for (int i = 0; i < low.Length; i++) {
            output[2 * i] = low[i];
            output[2 * i + 1] = high[i];
        }
        return output;
    }

    public static byte[] PackGraphics(byte[] raw, int regionBytes) {
        int quarterBytes = regionBytes / 4;
        int tiles = regionBytes / 128;
        byte[] packed = new byte[regionBytes];
        for (int code = 0; code < tiles; code++) {
            for (int row = 0; row < 8; row++) {
                int dst = (code * 8 + row) * 16;
                for (int quarter = 0; quarter < 4; quarter++) {
                    int src = quarter * quarterBytes + code * 32 + row * 4;
                    for (int b = 0; b < 4; b++)
                        packed[dst + quarter * 4 + b] = raw[src + b];
                }
            }
        }
        return packed;
    }
}
"@

New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ZipPath))
try {
    function Read-Entry([string]$Name) {
        $entry = $zip.GetEntry($Name)
        if (-not $entry) { throw "Missing $Name in $ZipPath" }
        $stream = $entry.Open()
        $memory = [IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            return ,$memory.ToArray()
        } finally {
            $stream.Dispose()
            $memory.Dispose()
        }
    }

    if ($Game -eq "cairblad") {
        $main = [byte[]]::new(0x200000)
        $data = Read-Entry "ac1810e0.u32"
        [Buffer]::BlockCopy($data, 0, $main, 0, $data.Length)

        $raw = [byte[]]::new(0x2000000)
        $gfxNames = @(
            "ac1801m0.u6", "ac1802m0.u9", "ac1803m0.u7",
            "ac1804m0.u10", "ac1805m0.u8", "ac1806m0.u11"
        )
        for ($i = 0; $i -lt $gfxNames.Count; $i++) {
            $part = Read-Entry $gfxNames[$i]
            [Buffer]::BlockCopy($part, 0, $raw, $i * 0x400000, $part.Length)
        }
        $samples = [SsvFamilyRomTools]::Swap16((Read-Entry "ac1410m0.u41"))
    } else {
        $main = [byte[]]::new(0x400000)
        $data = Read-Entry "data.u34"
        [Buffer]::BlockCopy($data, 0, $main, 0, $data.Length)
        $lowName = if ($Game -eq "vasara") { "prg-l.u30" } else { "prg-l.u30" }
        $highName = if ($Game -eq "vasara") { "prg-h.u31" } else { "prg-h.u31" }
        $tail = [SsvFamilyRomTools]::Interleave(
            (Read-Entry $lowName), (Read-Entry $highName))
        [Buffer]::BlockCopy($tail, 0, $main, 0x200000, $tail.Length)
        [Buffer]::BlockCopy($tail, 0, $main, 0x300000, $tail.Length)

        $raw = [byte[]]::new(0x2000000)
        $gfxNames = @("a0.u1", "b0.u2", "c0.u3", "d0.u4")
        for ($i = 0; $i -lt $gfxNames.Count; $i++) {
            $part = Read-Entry $gfxNames[$i]
            [Buffer]::BlockCopy($part, 0, $raw, $i * 0x800000, $part.Length)
        }
        $samples = [byte[]]::new(0x800000)
        $sampleNames = if ($Game -eq "vasara") {
            @("s0.u36", "s1.u37")
        } else {
            @("s0.u36", "s1.u37")
        }
        for ($bank = 0; $bank -lt $sampleNames.Count; $bank++) {
            $part = Read-Entry $sampleNames[$bank]
            for ($i = 0; $i -lt $part.Length; $i++)
                $samples[$bank * 0x400000 + $i * 2] = $part[$i]
        }
    }

    $packed = [SsvFamilyRomTools]::PackGraphics($raw, 0x2000000)
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "maincpu.bin"), $main)
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "sprites_packed.bin"), $packed)
    [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "samples.bin"), $samples)
    Write-Host ("Created {0} images: main={1} gfx_packed={2} samples={3}" -f
        $Game, $main.Length, $packed.Length, $samples.Length)
} finally {
    $zip.Dispose()
}
