<#
.SYNOPSIS
  Report what a set of unrar builds actually are, to confirm they differ only
  in the way you intended.

.DESCRIPTION
  A CRC32 change cannot make LZ-dominated archives slower. If a benchmark
  shows a uniform slowdown across archives where CRC is a small fraction of
  the work, the builds almost certainly differ by more than the CRC define -
  wrong Platform (Win32 vs x64), wrong Configuration (Debug vs Release), a
  different PlatformToolset, or stale objects from a non-Rebuild build.

  This checks the things that would explain that.

.EXAMPLE
  .\dispatch\check-builds.ps1 -Exe unrar-nofold.exe,unrar-fold.exe

.NOTES
  Needs dumpbin, so run from a Developer Command Prompt / after vcvars64.bat.
#>

param(
  [Parameter(Mandatory=$true)]
  [string[]]$Exe
)

# `powershell -File check-builds.ps1 -Exe a.exe,b.exe` passes the whole list as
# one string, so split it back apart rather than reporting both paths missing.
$Exe = @($Exe | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } |
         Where-Object { $_ -ne "" })

$HasDumpbin = $null -ne (Get-Command dumpbin.exe -ErrorAction SilentlyContinue)
if (-not $HasDumpbin) {
  Write-Host "dumpbin not on PATH - run from a Developer Command Prompt for VS." -ForegroundColor Yellow
  Write-Host "Continuing with file metadata only.`n"
}

foreach ($E in $Exe) {
  if (-not (Test-Path $E)) {
    Write-Host "Not found: $E" -ForegroundColor Red
    continue
  }
  $F = Get-Item $E

  Write-Host ("=== {0} ===" -f $F.Name) -ForegroundColor Cyan
  Write-Host ("  size            : {0:N0} bytes" -f $F.Length)
  Write-Host ("  modified        : {0}" -f $F.LastWriteTime)

  if ($HasDumpbin) {
    $Headers = & dumpbin.exe /headers $F.FullName 2>$null

    $Machine = ($Headers | Select-String -Pattern 'machine \(' | Select-Object -First 1)
    if ($Machine) { Write-Host ("  machine         : {0}" -f $Machine.ToString().Trim()) }

    # A Debug build links the debug CRT; that alone would explain a uniform
    # slowdown far better than any CRC change.
    $Deps = & dumpbin.exe /dependents $F.FullName 2>$null
    $DebugCrt = $Deps | Select-String -Pattern 'VCRUNTIME\d+D\.dll|MSVCP\d+D\.dll|ucrtbased\.dll'
    if ($DebugCrt) {
      Write-Host "  CRT             : DEBUG runtime - this is a Debug build!" -ForegroundColor Red
    } else {
      Write-Host "  CRT             : release"
    }

    # Which CRC path is compiled in.
    $Disasm = & dumpbin.exe /disasm:nobytes $F.FullName 2>$null
    $Pclmul  = @($Disasm | Select-String -Pattern '\bpclmulqdq\b').Count
    $Vpclmul = @($Disasm | Select-String -Pattern '\bvpclmulqdq\b').Count
    Write-Host ("  pclmulqdq       : {0}" -f $Pclmul)
    Write-Host ("  vpclmulqdq      : {0}" -f $Vpclmul)

    if ($Pclmul -eq 0 -and $Vpclmul -eq 0) {
      Write-Host "  -> folding is NOT present (built with -DNO_CRC_FOLD, or crcfold.cpp not reached)"
    } elseif ($Vpclmul -eq 0) {
      Write-Host "  -> fold-128 only (256-bit path compiled out: toolset older than VS2019?)"
    } else {
      Write-Host "  -> fold-128 and fold-256 both present"
    }
  }
  Write-Host ""
}

Write-Host "Both builds must match on machine, CRT and toolset, and differ ONLY in"
Write-Host "the pclmulqdq counts. If they differ in anything else, the benchmark is"
Write-Host "comparing build configurations rather than the CRC implementation."
Write-Host ""
Write-Host "Better still, skip two builds entirely - one folding-enabled binary can"
Write-Host "select the path at run time:"
Write-Host "  set UNRAR_CRC_FOLD=0    # table only (baseline)"
Write-Host "  set UNRAR_CRC_FOLD=128  # force 128-bit folding"
Write-Host "  set UNRAR_CRC_FOLD=256  # 256-bit if the CPU supports it"
