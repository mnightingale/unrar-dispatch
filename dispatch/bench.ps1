<#
.SYNOPSIS
  Windows equivalent of dispatch/bench.sh - compares unrar builds over a
  corpus of archives.

.DESCRIPTION
  Uses `unrar t` (test): a full decompress plus CRC check with no disk writes,
  isolating decompression from filesystem I/O.

  Reports per archive, never one aggregate: the code paths have different
  bottlenecks and a win in one is easily hidden by a wash in another. Each row
  also reports its own measured noise floor, and any delta inside that floor
  is labelled 'noise' rather than being allowed to read as a result.

  Written for Windows PowerShell 5.1, so it avoids PowerShell 7-only syntax.

.EXAMPLE
  # Preferred: one binary, CRC path chosen at run time. The columns cannot
  # differ by anything except the CRC implementation.
  .\dispatch\bench.ps1 -Exe unrar.exe -FoldModes 0,128,256 -Corpus dispatch\corpus

.EXAMPLE
  .\dispatch\bench.ps1 -Exe unrar-nofold.exe,unrar-fold.exe -Corpus dispatch\corpus

.EXAMPLE
  .\dispatch\bench.ps1 -Build build\unrar64\Release -Corpus dispatch\corpus -Runs 7

.NOTES
  If execution policy blocks this:
    powershell -ExecutionPolicy Bypass -File dispatch\bench.ps1 ...

  Order matters: the 'delta' column compares the LAST exe against the FIRST,
  so list the baseline first (positive delta means the last one is faster).
#>

param(
  [string[]]$Exe,
  [string]$Build = "",
  [string]$Corpus = "dispatch\corpus",
  [int]$Runs = 5,
  [string]$Password = "benchpw",
  [string[]]$FoldModes
)

$ErrorActionPreference = "Stop"

# ---- normalise comma-separated arguments ------------------------------------

# Running this script as `powershell -File bench.ps1 ...` - which is what the
# execution-policy workaround in .NOTES tells you to do - passes every argument
# as a plain string, so `-FoldModes 0,128,256` arrives as the single token
# "0,128,256" rather than three values.
#
# That is only a nuisance for -Exe, which then fails a Test-Path and stops. For
# -FoldModes it was actively dangerous while the parameter was typed [int[]]:
# PowerShell reads the commas as thousands separators, so "0,128,256" converts
# to the single integer 128256. The run then had one variant instead of three,
# compared it against itself, and printed 0.0% delta / "noise" on every row -
# indistinguishable from folding genuinely not helping. Both parameters are
# taken as strings and split here instead.
function Split-ListArg {
  param([string[]]$Values)
  $Out = @()
  foreach ($V in $Values) {
    foreach ($P in ($V -split ',')) {
      $P = $P.Trim()
      if ($P -ne "") { $Out += $P }
    }
  }
  return ,$Out
}

if ($Exe)       { $Exe = Split-ListArg $Exe }
if ($FoldModes) { $FoldModes = Split-ListArg $FoldModes }

# Only 0, 128 and 256 mean anything to CRCFoldDetect(). Anything else would be
# silently clamped by it to the nearest path (see crcfold.cpp), producing a
# column labelled with a number that is not the path that actually ran.
$Modes = @()
foreach ($M in $FoldModes) {
  if ($M -notmatch '^(0|128|256)$') {
    Write-Host "Invalid -FoldModes value '$M' - expected 0, 128 or 256." -ForegroundColor Red
    exit 2
  }
  $Modes += [int]$M
}

# ---- locate the executables -------------------------------------------------

if (-not $Exe -or $Exe.Count -eq 0) {
  if ($Build -eq "") {
    Write-Host "Give either -Exe <a.exe>,<b.exe> or -Build <dir containing unrar*.exe>" -ForegroundColor Red
    Write-Host "List the baseline first: 'delta' compares the last exe against the first."
    exit 2
  }
  $Exe = @(Get-ChildItem -Path $Build -Filter "unrar*.exe" |
           Sort-Object Name | ForEach-Object { $_.FullName })
}

if ($Exe.Count -lt 1) {
  Write-Host "No executables found." -ForegroundColor Red
  exit 1
}

# Resolve to full paths. PowerShell's & operator will not run a bare
# "unrar.exe" from the current directory the way cmd does - it needs a path
# with a directory component, or something on PATH. Test-Path is happy with
# the bare name, so without this the check passes and the call fails.
$Resolved = @()
foreach ($E in $Exe) {
  if (-not (Test-Path $E)) {
    Write-Host "Not found: $E" -ForegroundColor Red
    exit 1
  }
  $Resolved += (Get-Item $E).FullName
}
$Exe = $Resolved

if (-not (Test-Path $Corpus)) {
  Write-Host "No corpus at $Corpus" -ForegroundColor Red
  Write-Host "Copy dispatch\corpus over from another machine, or generate it with dispatch/make-corpus.sh where rar is available."
  exit 1
}

# ---- select archives --------------------------------------------------------

# Multi-volume sets are driven from part01 only; skip continuation volumes so
# they are not timed as separate archives.
$Archives = Get-ChildItem -Path $Corpus -Filter "*.rar" | Where-Object {
  if ($_.Name -match '\.part(\d+)\.rar$') { [int]$Matches[1] -eq 1 } else { $true }
} | Sort-Object Name

if ($Archives.Count -eq 0) {
  Write-Host "No .rar archives in $Corpus" -ForegroundColor Red
  exit 1
}

# ---- measurement ------------------------------------------------------------

# Min-of-N after a discarded warmup. The first read pulls the archive into the
# file cache; including it inflates the spread enough to mask real effects.
#
# Noise is (median - min), not (max - min): a single scheduler hiccup destroys
# the latter and would label reproducible effects as noise.
function Measure-Best {
  param(
    [string]$ExePath,
    [string[]]$CmdArgs,
    [int]$Count,
    $FoldMode
  )

  # Selecting the CRC path at run time keeps everything else about the binary
  # identical, which removes build configuration and anti-virus first-run
  # scanning as sources of difference between the columns.
  if ($null -ne $FoldMode) {
    $env:UNRAR_CRC_FOLD = "$FoldMode"
  }

  & $ExePath @CmdArgs *> $null

  $Times = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $Count; $i++) {
    $Sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $ExePath @CmdArgs *> $null
    $Sw.Stop()
    [void]$Times.Add($Sw.Elapsed.TotalMilliseconds)
  }

  if ($null -ne $FoldMode) {
    Remove-Item Env:\UNRAR_CRC_FOLD -ErrorAction SilentlyContinue
  }

  $Sorted = $Times | Sort-Object
  $Lo  = $Sorted[0]
  $Med = $Sorted[[int]([math]::Floor($Sorted.Count / 2))]

  $Noise = 0.0
  if ($Lo -gt 0) { $Noise = (($Med - $Lo) / $Lo) * 100.0 }

  return @{ Min = $Lo; Noise = $Noise }
}

# A "variant" is an executable, optionally paired with a UNRAR_CRC_FOLD value.
# Comparing modes of ONE binary is strongly preferred over comparing two
# separately-built binaries: it is impossible for the columns to differ by
# anything except the CRC path.
$Variants = @()
foreach ($E in $Exe) {
  $Base = [System.IO.Path]::GetFileNameWithoutExtension($E)
  if ($Modes.Count -gt 0) {
    foreach ($M in $Modes) {
      $Label = "fold=$M"
      if ($Exe.Count -gt 1) { $Label = "$Base/$M" }
      $Variants += @{ Path = $E; Name = $Label; Fold = $M }
    }
  } else {
    $Variants += @{ Path = $E; Name = $Base; Fold = $null }
  }
}

$Names = @($Variants | ForEach-Object { $_.Name })

Write-Host ("runs per measurement: {0} (min-of-N)   variants: {1}" -f $Runs, $Variants.Count)
if ($Modes.Count -gt 0) {
  Write-Host "comparing UNRAR_CRC_FOLD modes of one binary (0=table, 128/256=folding)"
}

# With one variant the 'delta' column compares that column against itself and
# reports 0.0% on every row, which reads as "no difference" rather than as
# "nothing was compared". Say so, loudly.
if ($Variants.Count -lt 2) {
  Write-Host "WARNING: only one variant - 'delta' compares it against itself and will be 0.0% on every row." -ForegroundColor Yellow
  Write-Host "         Pass two executables, or -FoldModes 0,256, to actually compare something." -ForegroundColor Yellow
}
# Process creation costs far more on Windows than the fork+exec these numbers
# are usually compared against on Linux - tens of milliseconds once the loader,
# the CRT and on-access anti-virus scanning are counted, against roughly one.
# That is a fixed cost inside every row below, so it shrinks every percentage
# delta without changing the underlying millisecond saving. Measure it rather
# than leaving the reader to wonder why the same change reads smaller here.
$FloorRuns = 7
& $Variants[0].Path *> $null
$FloorTimes = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $FloorRuns; $i++) {
  $Sw = [System.Diagnostics.Stopwatch]::StartNew()
  & $Variants[0].Path *> $null
  $Sw.Stop()
  [void]$FloorTimes.Add($Sw.Elapsed.TotalMilliseconds)
}
$Floor = ($FloorTimes | Sort-Object)[0]
Write-Host ("process launch floor: {0:N0}ms (measured, no archive) - included in every row below" -f $Floor)
Write-Host ""

foreach ($Mode in @("mt1", "default")) {

  if ($Mode -eq "mt1") {
    $MtArg = @("-mt1")
    $Label = "single-thread (-mt1)"
  } else {
    $MtArg = @()
    $Label = "default threads"
  }

  Write-Host ("########  {0}  ########" -f $Label)

  $Header = "{0,-24}" -f "archive"
  foreach ($N in $Names) { $Header += "{0,14}" -f $N }
  $Header += "{0,10}{1,8}   {2}" -f "delta", "noise", "verdict"
  Write-Host $Header

  foreach ($A in $Archives) {
    # Any *encrypted* archive shares the fixed benchmark password.
    if ($A.Name -match 'encrypted') { $Pw = "-p$Password" } else { $Pw = "-p-" }

    $Row = "{0,-24}" -f [System.IO.Path]::GetFileNameWithoutExtension($A.Name)

    $Baseline = 0.0
    $Last = 0.0
    $WorstNoise = 0.0
    $First = $true

    foreach ($V in $Variants) {
      $CmdArgs = @("t") + $MtArg + @($Pw, "-y", $A.FullName)
      $R = Measure-Best -ExePath $V.Path -CmdArgs $CmdArgs -Count $Runs -FoldMode $V.Fold

      $Row += "{0,12:N0}ms" -f $R.Min
      if ($First) { $Baseline = $R.Min; $First = $false }
      $Last = $R.Min
      if ($R.Noise -gt $WorstNoise) { $WorstNoise = $R.Noise }
    }

    if ($Baseline -gt 0) {
      $Delta = (($Baseline - $Last) / $Baseline) * 100.0
      if ([math]::Abs($Delta) -le $WorstNoise) {
        $Verdict = "noise"
      } elseif ($Delta -gt 0) {
        $Verdict = "FASTER"
      } else {
        $Verdict = "SLOWER"
      }
      $Row += "{0,9:+0.0;-0.0;0.0}%{1,7:N1}%   {2}" -f $Delta, $WorstNoise, $Verdict
    } else {
      $Row += "{0,10}" -f "n/a"
    }

    Write-Host $Row
  }

  Write-Host ""
}

Write-Host "delta   = last variant vs first (positive means the last variant is faster)"
Write-Host "noise   = worst run-to-run spread (median-min) seen for that row"
Write-Host "verdict = 'noise' means |delta| <= noise, i.e. not a measurable difference"
Write-Host ""
Write-Host ("Every row includes the {0:N0}ms launch floor above. To compare a percentage" -f $Floor)
Write-Host "against a Linux run, subtract it from both columns first - on Linux that"
Write-Host "floor is about 1ms, so the same saving reads as a larger percentage there."
