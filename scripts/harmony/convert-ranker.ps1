<#
.SYNOPSIS
  ONNX -> MindSpore Lite .ms 转换（Windows x64，可复现）。

.DESCRIPTION
  MindSpore Lite Windows 包不自带 MinGW 运行时，converter_lite 直接运行会报 0xC0000135/0xC0000139。
  本脚本从 DevEco Studio 的 codescanner 插件取兼容的 MinGW DLL 补齐 converter 目录，然后转换并 benchmark。

  前置：
    1) 下载 MindSpore Lite 2.11 Windows 包并解压到 scripts/harmony/.local/tools/mindspore-lite/
       https://ms-release.obs.cn-north-4.myhuaweicloud.com/2.11.0/MindSporeLite/lite/release/windows/mindspore-lite-2.11.0-win-x64.zip
    2) Python + onnx（pip install onnx）
    3) DevEco Studio 26（自带 codescanner 插件的 MinGW 运行时）

  典型流程：
    python scripts/harmony/train-ranker.py
    pwsh scripts/harmony/convert-ranker.ps1
    Copy-Item scripts/harmony/.local/ranker/ranker.ms harmony/entry/src/main/resources/rawfile/recommend/ranker_v1.ms
#>
[CmdletBinding()]
param(
  [string]$Onnx = '',
  [string]$OutBase = '',
  [string]$Python = '',
  [switch]$SkipBenchmark
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $here '..\..')).Path
$toolsRoot = Join-Path $repoRoot 'scripts\harmony\.local\tools'
$pkgDir = Join-Path $toolsRoot 'mindspore-lite\mindspore-lite-2.11.0-win-x64'
$converterDir = Join-Path $pkgDir 'tools\converter\converter'

if ($Onnx.Length -eq 0) { $Onnx = Join-Path $repoRoot 'scripts\harmony\.local\ranker\ranker.onnx' }
if ($OutBase.Length -eq 0) { $OutBase = Join-Path $repoRoot 'scripts\harmony\.local\ranker\ranker' }
if (-not (Test-Path -LiteralPath $Onnx)) { throw "ONNX not found: $Onnx" }
if (-not (Test-Path -LiteralPath (Join-Path $converterDir 'converter_lite.exe'))) {
  throw "converter_lite.exe not found: $converterDir（先下载并解压 MindSpore Lite 2.11 Windows 包）"
}

# 1) 补齐 MinGW 运行时（DevEco codescanner 插件）
$envPs1 = Join-Path $repoRoot 'scripts\harmony\env.ps1'
. $envPs1 -Quiet
$mingwDir = Join-Path $HarmonyToolchain.DevEcoHome 'plugins\codescanner\cpp-agent\release'
foreach ($name in @('libstdc++-6.dll', 'libgcc_s_seh-1.dll', 'libwinpthread-1.dll')) {
  $src = Join-Path $mingwDir $name
  if (-not (Test-Path -LiteralPath $src)) { throw "missing MinGW runtime: $src" }
  Copy-Item -LiteralPath $src -Destination (Join-Path $converterDir $name) -Force
}
$ssp = Join-Path $converterDir 'libssp-0.dll'
if (-not (Test-Path -LiteralPath $ssp)) { throw "libssp-0.dll missing in converter dir: $converterDir" }

# 2) 转换
$libDir = Join-Path $pkgDir 'tools\converter\lib'
$runtimeLib = Join-Path $pkgDir 'runtime\lib'
$env:PATH = $converterDir + ';' + $libDir + ';' + $runtimeLib + ';' + $env:PATH
$log = $OutBase + '.convert.log'
$convArgs = @('--fmk=ONNX', ('--modelFile=' + (Resolve-Path -LiteralPath $Onnx).Path), ('--outputFile=' + $OutBase), '--optimize=general')
Write-Host ('[convert] converter_lite ' + ($convArgs -join ' ')) -ForegroundColor Cyan
$p = Start-Process -FilePath (Join-Path $converterDir 'converter_lite.exe') -ArgumentList $convArgs -NoNewWindow -Wait -PassThru -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
$out = Get-Content -LiteralPath $log -Raw
if ($p.ExitCode -ne 0 -or $out -notmatch 'CONVERT RESULT SUCCESS:0') { throw "convert failed (exit=$($p.ExitCode)), see $log" }
$ms = $OutBase + '.ms'
if (-not (Test-Path -LiteralPath $ms)) { throw "output not found: $ms" }
Write-Host ("[convert] OK -> $ms (" + (Get-Item -LiteralPath $ms).Length + ' bytes)') -ForegroundColor Green

# 3) benchmark 冒烟
if (-not $SkipBenchmark) {
  $env:PATH = $converterDir + ';' + $libDir + ';' + $runtimeLib + ';' + (Join-Path $pkgDir 'runtime\third_party\glog') + ';' + $env:PATH
  $benchLog = $OutBase + '.benchmark.log'
  $bp = Start-Process -FilePath (Join-Path $pkgDir 'tools\benchmark\benchmark.exe') -ArgumentList @(('--modelFile=' + (Resolve-Path -LiteralPath $ms).Path), '--modelType=MindIR_Lite', '--device=CPU', '--loopCount=5', '--warmUpLoopCount=1') -NoNewWindow -Wait -PassThru -RedirectStandardOutput $benchLog -RedirectStandardError ($benchLog + '.err')
  Get-Content -LiteralPath $benchLog -Raw | Select-String 'AvgRunTime|Success' | ForEach-Object { Write-Host ('[bench] ' + $_.Line.Trim()) }
  if ($bp.ExitCode -ne 0) { throw "benchmark failed, see $benchLog" }
}
Write-Host ('[convert] sha256 ' + (Get-FileHash -LiteralPath $ms -Algorithm SHA256).Hash)