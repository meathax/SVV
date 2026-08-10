# Sweep Quartus SEED to find placement with real margin on the pll_hdmi domain.
#
# Why this exists: Standard Fit crashes quartus_fit on this install (see the
# note in Arcade-SSV.qsf), so fitter effort is not available as a lever. Under
# Fast Fit the 148.5 MHz ascal domain is placement-sensitive - three compiles of
# near-identical logic gave +0.392, +0.119 and -0.141 ns. A single passing build
# is therefore a lottery ticket, not a closed design. Sweep, then pin the seed
# that has margin rather than the one that merely passes.
[CmdletBinding()]
param(
    # Comma-separated, e.g. -Seeds "2,3,5,8". Deliberately a STRING and split
    # here: `pwsh -File script.ps1 -Seeds 2,3,5,8` passes one argument, and an
    # [int[]] parameter coerces "2,3,5,8" to the single value 2358 by reading
    # the commas as thousands separators. That silently sweeps one wrong seed.
    [string]$Seeds = "1,2,3,5,8",
    [string]$QuartusRoot = "D:\Q17"
)
$SeedList = @($Seeds -split '\s*,\s*' | Where-Object { $_ -match '^\d+$' } |
              ForEach-Object { [int]$_ })
if (-not $SeedList.Count) { throw "No valid seeds parsed from '$Seeds'." }

$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$qsf  = Join-Path $repo "Arcade-SSV.qsf"
$log  = Join-Path $repo "output_files\seed-sweep.log"

function Log([string]$m) {
    $line = "{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $m
    $line | Tee-Object -FilePath $log -Append
}

# Worst setup slack across every corner, for the clock we care about.
function Get-HdmiSlack {
    $sta = Join-Path $repo "output_files\Arcade-SSV.sta.summary"
    if (-not (Test-Path $sta)) { return $null }
    $lines = Get-Content $sta
    $worst = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "Model Setup" -and $lines[$i] -match "pll_hdmi") {
            if ($lines[$i+1] -match "Slack\s*:\s*(-?[\d.]+)") {
                $v = [double]$Matches[1]
                if ($null -eq $worst -or $v -lt $worst) { $worst = $v }
            }
        }
    }
    return $worst
}

function Set-SeedUnderSlot([int]$Value) {
    Push-Location $repo
    try {
        $out = & pwsh -NoProfile -File "$repo\tools\build-ssv.ps1" `
            -QuartusRoot $QuartusRoot -SetSeedOnly -Seed $Value 2>&1
        $code = $LASTEXITCODE
    }
    finally { Pop-Location }
    $out | ForEach-Object { Log $_ }
    if ($code -ne 0) {
        throw "Could not set SEED $Value through the global Quartus slot."
    }
}

$original = (Select-String -Path $qsf -Pattern '^set_global_assignment -name SEED (\d+)').Matches.Groups[1].Value
Log "sweeping seeds: $($SeedList -join ', ')  (current SEED $original)"
$results = @()

foreach ($s in $SeedList) {
    Log "SEED $s : queued through the global Quartus slot"
    Push-Location $repo
    try {
        $out = & pwsh -NoProfile -File "$repo\tools\build-ssv.ps1" -QuartusRoot $QuartusRoot -Seed $s 2>&1
        $code = $LASTEXITCODE
    } finally { Pop-Location }

    $slack = Get-HdmiSlack
    $crashed = ($out -match 'ended unexpectedly')
    $status = if ($crashed) { "FITTER CRASH" } elseif ($code -eq 0) { "deployable" } else { "rejected" }
    Log ("SEED {0} : {1}, worst pll_hdmi setup {2}" -f $s, $status,
         $(if ($null -ne $slack) { "$slack ns" } else { "n/a" }))
    $results += [pscustomobject]@{ Seed = $s; Status = $status; Slack = $slack }
}

Log "---- sweep complete ----"
$results | Sort-Object -Property @{E={$_.Slack}; Descending=$true} |
    ForEach-Object { Log ("  SEED {0,-3} {1,-12} {2}" -f $_.Seed, $_.Status, $_.Slack) }

$best = $results | Where-Object { $_.Status -eq 'deployable' -and $null -ne $_.Slack } |
        Sort-Object -Property @{E={$_.Slack}; Descending=$true} | Select-Object -First 1
if ($best) {
    Log "best seed $($best.Seed) at $($best.Slack) ns - pinning it in the QSF"
    Set-SeedUnderSlot $best.Seed
    Log "NOTE: the staged releases\Arcade-SSV.rbf is from the LAST seed compiled, not"
    Log "      necessarily the best. Recompile with the pinned seed before deploying."
} else {
    Log "no deployable seed found - restoring SEED $original"
    Set-SeedUnderSlot ([int]$original)
}
