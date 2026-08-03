<#
.SYNOPSIS
  Windows equivalent of crcbench/build-ab.sh - builds unrar twice, with and
  without the CRC32 folding path, so the end-to-end effect can be measured.

.DESCRIPTION
  Microbenchmark throughput is not user-visible speedup: CRC is only a slice of
  unrar's runtime, so this measures the number that actually matters.

  Doing this by hand is error-prone in a way that is not self-announcing. Both
  configurations write to the same build\unrar64\Release\unrar.exe, so the two
  builds have to be told apart by renaming, and getting that rename backwards
  produces two plausible-looking binaries whose A/B result is simply inverted.
  That is why this script verifies the instruction counts at the end and fails
  if they are not what the names claim.

  MSBuild will not notice that only a compiler *define* changed, so /t:Rebuild
  is used for both configurations rather than an incremental build.

  Variants are named so that sort order puts the baseline first, which makes
  bench.ps1's "delta" column read as folding-vs-baseline (positive = faster).

.EXAMPLE
  .\crcbench\build-ab.ps1
  .\dispatch\bench.ps1 -Build crcbench\build-ab -Corpus dispatch\corpus

.NOTES
  Needs msbuild and dumpbin, so run from a Developer Command Prompt for VS, or
  pass -VcVars to have this script call vcvars64.bat itself.
#>

param(
  [string]$OutDir = "crcbench\build-ab",
  [string]$Toolset = "v143",
  [string]$SdkVersion = "10.0",
  [string]$VcVars = ""
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Proj = Join-Path $Root "UnRAR.vcxproj"
$Built = Join-Path $Root "build\unrar64\Release\unrar.exe"

if (-not (Test-Path $Proj)) { Write-Host "UnRAR.vcxproj not found at $Proj" -ForegroundColor Red; exit 1 }

if (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $Root $OutDir }
if (-not (Test-Path $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir) }

# Locate the tools. Everything runs through one cmd.exe per build so that
# vcvars64.bat (a batch file, whose environment cannot outlive its own process)
# and msbuild are in the same shell.
if ($VcVars -eq "") {
  $Candidates = @("Community","Professional","Enterprise","BuildTools") | ForEach-Object {
    "${env:ProgramFiles}\Microsoft Visual Studio\2022\$_\VC\Auxiliary\Build\vcvars64.bat"
  }
  $VcVars = $Candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
$HaveMsbuild = $null -ne (Get-Command msbuild.exe -ErrorAction SilentlyContinue)
if (-not $HaveMsbuild -and -not $VcVars) {
  Write-Host "msbuild not on PATH and no vcvars64.bat found - run from a Developer Command Prompt, or pass -VcVars." -ForegroundColor Red
  exit 1
}
$Prefix = if ($VcVars) { "call `"$VcVars`" >nul && " } else { "" }

function Build-Variant {
  param([string]$Name,[string]$Defines)

  Write-Host ("==> {0}  (CL='{1}')" -f $Name,$Defines) -ForegroundColor Cyan
  $Log = Join-Path $OutDir "$Name.buildlog"
  if (Test-Path $Built) { Remove-Item $Built -Force }

  # `set CL=` with no value clears it, so the folding build is not silently
  # contaminated by a define left over from a previous shell or from the
  # baseline build above it.
  $Cmd = "$Prefix" +
         "set `"CL=$Defines`" && " +
         "msbuild `"$Proj`" /p:Configuration=Release /p:Platform=x64 " +
         "/p:PlatformToolset=$Toolset /p:WindowsTargetPlatformVersion=$SdkVersion " +
         "/t:Rebuild /v:minimal /nologo"
  cmd /c $Cmd > $Log 2>&1

  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Built)) {
    Write-Host "!!! build failed; see $Log" -ForegroundColor Red
    Get-Content $Log -Tail 20 | ForEach-Object { Write-Host "    $_" }
    exit 1
  }
  $Dest = Join-Path $OutDir "unrar-$Name.exe"
  Move-Item -Force $Built $Dest
  Write-Host ("    -> {0}" -f $Dest)
}

Build-Variant -Name "a-nofold" -Defines "/DNO_CRC_FOLD"
Build-Variant -Name "b-fold"   -Defines ""

# ---- verify the two builds are what their names say -------------------------

Write-Host "`nConfirming the two builds really differ:"

$Counts = @{}
$Ok = $true
foreach ($Name in @("a-nofold","b-fold")) {
  $Exe = Join-Path $OutDir "unrar-$Name.exe"
  $Asm = Join-Path $OutDir "$Name.disasm"
  cmd /c "$Prefix dumpbin /disasm:nobytes /nologo `"$Exe`" > `"$Asm`" 2>&1"

  if (-not (Test-Path $Asm)) { Write-Host "  dumpbin unavailable - cannot verify" -ForegroundColor Yellow; $Ok = $false; break }
  $D = Get-Content $Asm
  $P = @($D | Select-String -Pattern '\bpclmulqdq\b').Count
  $V = @($D | Select-String -Pattern '\bvpclmulqdq\b').Count
  $Counts[$Name] = @{ P = $P; V = $V }
  Write-Host ("  {0,-10} pclmulqdq={1,-4} vpclmulqdq={2}" -f $Name,$P,$V)
  Remove-Item $Asm -Force
}

if ($Ok) {
  # The check that matters. A silent rename swap leaves two working binaries
  # whose measured delta is exactly backwards, which is far worse than a build
  # that simply failed.
  if ($Counts["a-nofold"].P -ne 0 -or $Counts["a-nofold"].V -ne 0) {
    Write-Host "`nFAIL: a-nofold contains folding instructions - the builds are swapped or CL leaked." -ForegroundColor Red
    exit 1
  }
  if ($Counts["b-fold"].P -eq 0) {
    Write-Host "`nFAIL: b-fold contains no pclmulqdq - folding was not compiled in." -ForegroundColor Red
    exit 1
  }
  if ($Counts["b-fold"].V -eq 0) {
    Write-Host "`nWARNING: b-fold has no vpclmulqdq - the 256-bit path was compiled out." -ForegroundColor Yellow
    Write-Host "         crcfold.cpp gates it on _MSC_VER >= 1920, so check -Toolset (v143 = VS2022)." -ForegroundColor Yellow
  } else {
    Write-Host "`nOK: baseline is table-only, folding build has both the 128- and 256-bit paths." -ForegroundColor Green
  }
}

Write-Host "`nNow run:"
Write-Host ("  .\dispatch\bench.ps1 -Build {0} -Corpus dispatch\corpus" -f $OutDir)
Write-Host "`nOr skip two builds entirely and compare paths within the folding build:"
Write-Host ("  .\dispatch\bench.ps1 -Exe {0}\unrar-b-fold.exe -FoldModes 0,128,256 -Corpus dispatch\corpus" -f $OutDir)
