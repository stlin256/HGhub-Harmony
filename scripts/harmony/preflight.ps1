<#
.SYNOPSIS
  真机调试前自检（Preflight）：工具链 / 构建产物 / 签名 profile / 设备连接 / 下一步动作。

.DESCRIPTION
  输出一张就绪矩阵并给出下一步命令。退出码：
    0 = 具备真机安装条件（有签名 HAP + 有匹配 bundle 的 debug profile + 设备已连接）
    2 = 尚未就绪（会打印缺少的环节与对应操作）
    1 = 脚本自身执行出错

.EXAMPLE
  .\scripts\harmony\preflight.ps1
  .\scripts\harmony\preflight.ps1 -Json
#>
param(
  [string]$DevEcoHome = '',
  [switch]$Json
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'env.ps1') -DevEcoHome $DevEcoHome -Quiet
$ErrorActionPreference = 'Continue'
$toolchain = $HarmonyToolchain
$rows = New-Object System.Collections.ArrayList
$blockers = New-Object System.Collections.ArrayList

function Add-Row {
  param([string]$Item, [string]$State, [string]$Detail)
  [void]$rows.Add([pscustomobject]@{ Item = $Item; State = $State; Detail = $Detail })
}

# 1) 工具链
$versions = [ordered]@{
  node   = (& $toolchain.NodeExe --version 2>&1 | Out-String).Trim()
  java   = ((& $toolchain.JavaExe -version 2>&1) -join ' ').Trim()
  hdc    = ((& $toolchain.HdcExe -v 2>&1) -join ' ').Trim()
  sdk    = if ($toolchain.SdkDir) { Split-Path -Leaf (Split-Path -Parent $toolchain.SdkDir) } else { '' }
}
Add-Row '工具链' 'OK' ("node " + $versions.node + ' / hdc ' + $versions.hdc)

# 2) 工程与产物
$project = $null
try { $project = Get-HarmonyProjectPath } catch { }
if (-not $project) {
  Add-Row '工程' 'BLOCK' '未找到 harmony/ 工程；请在仓库根目录执行'
  [void]$blockers.Add('未找到 harmony/ 工程')
} else {
  Add-Row '工程' 'OK' $project
}

$bundle = ''
if ($project) {
  try { $bundle = Get-HarmonyBundleName -ProjectPath $project } catch { }
  if (-not $bundle) { [void]$blockers.Add('无法读取 bundleName') }
  else { Add-Row 'bundleName' 'OK' $bundle }
}

$unsignedHap = $null
$signedHap = $null
$localSignedHap = $null
if ($project) {
  $buildDir = Join-Path $project 'entry\build'
  $allHaps = @(Get-ChildItem -LiteralPath $buildDir -Recurse -Filter '*.hap' -ErrorAction SilentlyContinue)
  $unsignedHap = $allHaps | Where-Object { $_.Name -like '*-unsigned.hap' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $signedHap = $allHaps | Where-Object { $_.Name -like '*-signed.hap' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $localDir = Join-Path $PSScriptRoot '.local\local-sign'
  if (Test-Path -LiteralPath $localDir) {
    $localSignedHap = Get-ChildItem -LiteralPath $localDir -Filter '*-local-signed.hap' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
}
if ($signedHap) {
  Add-Row '构建产物' 'OK' ('签名 HAP: ' + $signedHap.Name + ' (' + $signedHap.Length + ' bytes)')
} elseif ($unsignedHap) {
  Add-Row '构建产物' 'WARN' ('仅未签名 HAP: ' + $unsignedHap.Name + '（可编译验证，不能装真机）')
} else {
  Add-Row '构建产物' 'BLOCK' '没有 HAP；先运行 .\scripts\harmony\build.ps1'
  [void]$blockers.Add('没有 HAP 产物')
}
if ($localSignedHap) {
  Add-Row 'Plan B 实验' 'INFO' ('本地测试 CA 签名 HAP: ' + $localSignedHap.Name + '（零售机大概率不可安装）')
}

# 3) 签名 profile / 签名配置
$signingConfigured = $false
$profileMatch = $false
if ($project) {
  $buildProfile = Join-Path $project 'build-profile.json5'
  if (Test-Path -LiteralPath $buildProfile) {
    $text = [IO.File]::ReadAllText($buildProfile)
    if ($text -match '"signingConfigs"\s*:\s*\[\s*\{') { $signingConfigured = $true }
  }
}
$verifyScript = Join-Path $PSScriptRoot 'verify-signing.ps1'
$profileSummary = ''
if ((Test-Path -LiteralPath $verifyScript) -and $bundle) {
  $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifyScript -Target list -Json 2>$null
  try {
    $parsed = (($raw -join [Environment]::NewLine) | ConvertFrom-Json)
    foreach ($p in @($parsed.Profiles)) {
      if ($p.BundleName -eq $bundle -and $p.Verified) { $profileMatch = $true; $profileSummary = ($p.Profile + ' (' + $p.Type + ', 有效期至 ' + $p.ValidTo + ')') }
    }
  } catch { }
}
if ($profileMatch) {
  Add-Row '签名 profile' 'OK' ('存在匹配 bundle 的 profile: ' + $profileSummary)
} else {
  Add-Row '签名 profile' 'BLOCK' ('未找到 ' + $bundle + ' 的 debug/release profile：需在 DevEco Studio 登录华为账号并勾选自动签名（详见 docs/harmony/ENVIRONMENT.md 4.4）')
  [void]$blockers.Add('缺少匹配 bundleName 的签名 profile（需用户一次 DevEco 自动签名）')
}
if ($signingConfigured) { Add-Row '签名配置' 'OK' 'harmony/build-profile.json5 已包含 signingConfigs' }
else { Add-Row '签名配置' 'WARN' 'harmony/build-profile.json5 未配置 signingConfigs（自动签名后会写入）' }

# 4) 设备
$targets = @(Get-HarmonyHdcTargets -Toolchain $toolchain)
$readyTargets = @($targets | Where-Object { $_.State -eq 'Ready' })
if ($readyTargets.Count -gt 0) {
  Add-Row '设备' 'OK' ('已连接 ' + $readyTargets.Count + ' 台: ' + (($readyTargets | ForEach-Object { $_.Id }) -join ', '))
} else {
  Add-Row '设备' 'BLOCK' '没有已连接且就绪的真机（hdc list targets）；请开启开发者模式 + USB 调试后插入'
  [void]$blockers.Add('没有已连接的真机')
}

# 5) 输出
$result = [pscustomobject]@{
  Ready    = ($blockers.Count -eq 0)
  Bundle   = $bundle
  Blockers = @($blockers)
  Rows     = @($rows)
}
if ($Json) {
  $result | ConvertTo-Json -Depth 6
} else {
  Write-Host ''
  Write-Host '=== HGhub Harmony 真机调试 Preflight ===' -ForegroundColor Cyan
  foreach ($r in $rows) {
    $color = 'Gray'
    if ($r.State -eq 'OK') { $color = 'Green' } elseif ($r.State -eq 'BLOCK') { $color = 'Red' } elseif ($r.State -eq 'WARN') { $color = 'Yellow' }
    Write-Host ('[{0,-5}] {1,-12} {2}' -f $r.State, $r.Item, $r.Detail) -ForegroundColor $color
  }
  Write-Host ''
  if ($blockers.Count -eq 0) {
    Write-Host '就绪：可以执行 .\scripts\harmony\build.ps1 -> install.ps1 -> device.ps1 log/screenshot' -ForegroundColor Green
  } else {
    Write-Host '尚未就绪，待办：' -ForegroundColor Yellow
    foreach ($b in $blockers) { Write-Host ('  - ' + $b) }
  }
}
if ($blockers.Count -gt 0) { exit 2 } else { exit 0 }
