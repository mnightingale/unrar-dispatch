<#
.SYNOPSIS
  Record an ETW CPU-sampling trace of unrar on Windows, for attributing
  extraction time to modules and functions.

.DESCRIPTION
  bench.ps1 says which archives are slow; this says where the time goes inside
  one. It exists because the Windows and Linux numbers diverged in a way the
  wall-clock benchmark could not explain: on a stored 256 MB archive, unrar's
  read phase moves already-cached bytes at ~2.5 GB/s while a minimal
  CreateFile+ReadFile loop with identical flags, chunk size and buffer type
  moves the same bytes at ~10 GB/s.

  Records with xperf and the kernel providers by default. That is deliberate
  rather than incidental: WPR's own profiles pull in managed-code providers,
  and `xperf -a profile` then aborts analysing its own recording with
  HRESULT 0x80070032 on the first .NET event. A kernel-only trace analyses
  cleanly with the toolkit's built-in actions and needs no hand-written
  .wpaProfile. -UseWpr is kept for the case where xperf cannot get the
  single shared NT Kernel Logger because something else holds it.

  MUST be run elevated: ETW kernel sessions require it.

.EXAMPLE
  # Record, then analyse (analysis needs no elevation).
  .\dispatch\profile-win.ps1 -Exe build\unrar64\Release\unrar.exe `
                             -Archive dispatch\corpus\rar5-store-m0.rar
  .\dispatch\profile-win.ps1 -AnalyzeOnly -Etl dispatch\unrar-profile.etl

.NOTES
  Symbols: pass -SymbolPath to resolve function names inside unrar. The build
  writes UnRAR.pdb next to the exe, but MSBuild overwrites it on every build,
  so a PDB kept from an earlier build will silently fail to match a renamed
  exe and you will get module-level attribution only. Copy the PDB aside at
  build time if you intend to profile that exact binary.
#>

param(
  [string]$Exe        = "build\unrar64\Release\unrar.exe",
  [string]$Archive    = "dispatch\corpus\rar5-store-m0.rar",
  [string]$Etl        = "dispatch\unrar-profile.etl",
  [string]$Password   = "benchpw",
  [int]$Runs          = 8,
  [string]$FoldMode   = "",
  [string]$SymbolPath = "",
  [switch]$UseWpr,
  [switch]$AnalyzeOnly,
  [switch]$KeepEtl
)

# Native tools write banners and benign warnings to stderr. Under
# ErrorActionPreference=Stop that alone raises a terminating error, which will
# kill this script on a harmless "no session to stop" during cleanup. Exit
# codes are checked explicitly instead.
$ErrorActionPreference = "Continue"

$Kit   = "${env:ProgramFiles(x86)}\Windows Kits\10\Windows Performance Toolkit"
$Xperf = Join-Path $Kit "xperf.exe"
$Wpr   = "$env:SystemRoot\system32\wpr.exe"

function Test-Elevated {
  return (New-Object Security.Principal.WindowsPrincipal(
            [Security.Principal.WindowsIdentity]::GetCurrent())
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Run-Tool {
  param([string]$Path,[string[]]$Arguments,[switch]$Quiet)
  $text = (& $Path @Arguments 2>&1 | Out-String).Trim()
  $code = $LASTEXITCODE
  if (-not $Quiet) {
    Write-Host ("  > {0} {1}" -f (Split-Path -Leaf $Path),($Arguments -join ' ')) -ForegroundColor DarkGray
    Write-Host ("    exit={0}" -f $code) -ForegroundColor DarkGray
    if ($text) {
      ($text -split "`r?`n" | Select-Object -First 6) |
        ForEach-Object { if ($_.Trim()) { Write-Host "    $_" -ForegroundColor DarkGray } }
    }
  }
  return @{ Code = $code; Out = $text }
}

# ---- analysis ---------------------------------------------------------------

function Invoke-Analysis {
  param([string]$EtlPath)

  if (-not (Test-Path $EtlPath)) { Write-Host "no trace at $EtlPath" -ForegroundColor Red; return $false }
  if (-not (Test-Path $Xperf))   { Write-Host "xperf not found at $Xperf" -ForegroundColor Red; return $false }

  $Dir  = Split-Path -Parent (Resolve-Path $EtlPath)
  $Out  = Join-Path $Dir "unrar-profile.txt"

  # Symbol decoding is opt-in: without -SymbolPath xperf would otherwise try
  # the public symbol server and stall the analysis on a slow download.
  $SymArgs = @()
  if ($SymbolPath -ne "") {
    $env:_NT_SYMBOL_PATH = $SymbolPath
    $SymArgs = @("-symbols")
    Write-Host ("symbols: {0}" -f $SymbolPath) -ForegroundColor Cyan
  } else {
    Write-Host "symbols: off (module-level attribution only; pass -SymbolPath for functions)" -ForegroundColor Yellow
  }

  # -detail is what produces the per-module (or per-function, with symbols)
  # breakdown. Without it the 'profile' action emits only a per-CPU
  # utilisation summary, which says nothing about where the time went.
  #
  # 'profile' is the authority for CPU time: it consumes SampledProfile events
  # only. Do not substitute 'xperf -a stack' for this - that action counts
  # every event carrying a stack, so on a trace with FILE_IO the file-I/O
  # stacks swamp the CPU samples and EtwpTraceStackWalk appears to consume
  # ~59% of the machine. It does not; in the sampled profile ETW is ~1%.
  # Use 'stack -butterfly' for call relationships, never for magnitudes.
  Write-Host "analysing (this takes a while on a large trace)..." -ForegroundColor Cyan
  $a = @("-i",(Resolve-Path $EtlPath).Path,"-tle","-tti") + $SymArgs + @("-o",$Out,"-a","profile","-detail")
  $r = Run-Tool $Xperf $a

  if ((Test-Path $Out) -and ((Get-Item $Out).Length -gt 0)) {
    Write-Host ("`nwrote {0}" -f $Out) -ForegroundColor Green
    return $true
  }

  Write-Host "`nThe 'profile' action produced nothing." -ForegroundColor Red
  if ($r.Out -match "0x80070032") {
    Write-Host "HRESULT 0x80070032 means the trace contains events this action cannot parse -" -ForegroundColor Yellow
    Write-Host "typically a WPR recording carrying managed-code providers. Re-record without" -ForegroundColor Yellow
    Write-Host "-UseWpr so the trace holds only kernel providers." -ForegroundColor Yellow
  }
  return $false
}

if ($AnalyzeOnly) { if (Invoke-Analysis $Etl) { exit 0 } else { exit 1 } }

# ---- record -----------------------------------------------------------------

if (-not (Test-Elevated)) {
  Write-Host "Must be run from an ELEVATED PowerShell - ETW kernel sessions require it." -ForegroundColor Red
  exit 1
}
foreach ($p in @($Exe,$Archive)) {
  if (-not (Test-Path $p)) { Write-Host "missing: $p" -ForegroundColor Red; exit 1 }
}
$ExeFull = (Get-Item $Exe).FullName
$ArcFull = (Get-Item $Archive).FullName

$EtlDir = Split-Path -Parent $Etl
if ($EtlDir -and -not (Test-Path $EtlDir)) { [void](New-Item -ItemType Directory -Path $EtlDir) }
if (Test-Path $Etl) { Remove-Item $Etl -Force }

Write-Host "clearing any leftover session..." -ForegroundColor Cyan
if (Test-Path $Xperf) { Run-Tool $Xperf @("-stop") -Quiet | Out-Null }
Run-Tool $Wpr @("-cancel") -Quiet | Out-Null

$Recorder = $null
Write-Host "`nstarting trace..." -ForegroundColor Cyan

if (-not $UseWpr -and (Test-Path $Xperf)) {
  # PROFILE          = 1 kHz sampled CPU
  # FILE_IO+INIT     = file reads/writes with durations
  # -stackwalk       = attach stacks to both; a bare sample count would not say
  #                    whether time is in the copy, a fault, or a filter driver
  $r = Run-Tool $Xperf @("-on","PROC_THREAD+LOADER+PROFILE+FILE_IO+FILE_IO_INIT",
                         "-stackwalk","Profile+FileRead",
                         "-BufferSize","1024","-MinBuffers","64","-MaxBuffers","256")
  if ($r.Code -eq 0) {
    # Verify rather than trust: xperf has returned 0 here without creating a
    # session, which then runs the whole workload untraced and merges nothing.
    $chk = Run-Tool $Xperf @("-loggers","NT Kernel Logger") -Quiet
    if ($chk.Out -match "NT Kernel Logger") {
      $Recorder = "xperf"; Write-Host "  started (session confirmed)." -ForegroundColor Green
    } else {
      Write-Host "  xperf returned 0 but no session exists." -ForegroundColor Yellow
    }
  }
}

if (-not $Recorder) {
  Write-Host "trying wpr (note: its traces may not analyse with 'xperf -a profile')" -ForegroundColor Yellow
  foreach ($set in @(@("-start","CPU","-start","FileIO","-filemode"),
                     @("-start","CPU","-filemode"),
                     @("-start","GeneralProfile","-filemode"))) {
    $r = Run-Tool $Wpr $set
    if ($r.Code -eq 0) { $Recorder = "wpr"; Write-Host "  started." -ForegroundColor Green; break }
  }
}

if (-not $Recorder) { Write-Host "`nNo recorder would start." -ForegroundColor Red; exit 1 }

try {
  if ($FoldMode -ne "") { $env:UNRAR_CRC_FOLD = $FoldMode }
  if ($Archive -match 'encrypted') { $Pw = "-p$Password" } else { $Pw = "-p-" }

  Write-Host ("`nrunning {0} x{1} on {2}..." -f (Split-Path -Leaf $ExeFull),$Runs,(Split-Path -Leaf $ArcFull)) -ForegroundColor Cyan
  & $ExeFull t -mt1 $Pw -y $ArcFull *> $null        # warm the file cache
  for ($i = 0; $i -lt $Runs; $i++) { & $ExeFull t -mt1 $Pw -y $ArcFull *> $null }

  if ($FoldMode -ne "") { $env:UNRAR_CRC_FOLD = "" }
}
finally {
  Write-Host "`nstopping trace (merging buffers, takes a few seconds)..." -ForegroundColor Cyan
  if ($Recorder -eq "xperf") { Run-Tool $Xperf @("-d",$Etl) | Out-Null }
  else                       { Run-Tool $Wpr   @("-stop",$Etl) | Out-Null }
}

if (-not (Test-Path $Etl)) { Write-Host "`nno .etl produced" -ForegroundColor Red; exit 1 }
Write-Host ("`nwrote {0} ({1:N0} MB)" -f $Etl,((Get-Item $Etl).Length/1MB)) -ForegroundColor Green

if (Invoke-Analysis $Etl) {
  if (-not $KeepEtl) {
    Write-Host "`n(.etl kept; delete it when done - these run to hundreds of MB)" -ForegroundColor DarkGray
  }
  exit 0
}
exit 1
