<#
.SYNOPSIS
  安装 HAP 到已连接的 HarmonyOS 真机并启动（hdc install -r + aa start）。

.DESCRIPTION
  默认流程：选设备 → 找最新签名 HAP → hdc install -r → aa start → 打印进程号。
  没有签名 HAP 时会明确报错（unsigned HAP 无法安装），并提示先完成签名（见 ENVIRONMENT.md Plan A）。
  -DryRun 只打印将执行的命令，不需要连接设备。

.EXAMPLE
  .\scripts\harmony\install.ps1
  .\scripts\harmony\install.ps1 -DryRun
  .\scripts\harmony\install.ps1 -HapPath harmony\entry\build\default\outputs\default\entry-default-signed.hap -ClearData
  .\scripts\harmony\install.ps1 -Device <serial> -NoLaunch
#>
param(
  [string]$DevEcoHome = '',
  [string]$ProjectPath = '',
  [string]$Device = '',
  [string]$HapPath = '',
  [string]$BundleName = '',
  [string]$AbilityName = 'EntryAbility',
  [string]$ModuleName = 'entry',
  [switch]$NoLaunch,
  [switch]$AllowUnsigned,
  [switch]$ClearData,
  [switch]$DryRun,
  [int]$LaunchWaitSeconds = 3
)

. (Join-Path $PSScriptRoot 'env.ps1') -DevEcoHome $DevEcoHome -Quiet
$toolchain = $HarmonyToolchain
$ErrorActionPreference = 'Continue'

$project = $null
try { $project = Get-HarmonyProjectPath -ProjectPath $ProjectPath } catch { }
if (-not $BundleName) {
  if ($project) { $BundleName = Get-HarmonyBundleName -ProjectPath $project }
  if (-not $BundleName) { throw '无法确定 bundleName：用 -BundleName 指定，或确保 harmony/ 工程存在。' }
}

if (-not $HapPath) {
  if (-not $project) { throw '未指定 -HapPath，且未找到 harmony/ 工程。' }
  $hap = Get-HarmonyHap -ProjectPath $project -IncludeUnsigned
  if (-not $hap) {
    throw "没有找到 HAP 产物。先运行 .\scripts\harmony\build.ps1"
  }
  $HapPath = $hap.FullName
  if ($hap.Name -like '*-unsigned.hap' -and -not $AllowUnsigned) {
    throw @"
只找到未签名 HAP：$HapPath
unsigned HAP 不能安装到真机。请先完成签名：
  1) DevEco Studio → Project Structure → Signing Configs → Automatically generate signature（需华为账号登录）
  2) 重新运行 .\scripts\harmony\build.ps1（产出 *-signed.hap）
  3) 再运行本脚本
详见 docs/harmony/ENVIRONMENT.md「签名方案」。
"@
  }
}
$HapPath = (Resolve-Path -LiteralPath $HapPath -ErrorAction Stop).Path
if ((Split-Path -Leaf $HapPath) -like '*-unsigned.hap' -and -not $AllowUnsigned) {
  throw "拒绝安装 unsigned HAP：$HapPath（如确需实验，加 -AllowUnsigned，但设备通常会拒绝）"
}

$targetDevice = $Device
if (-not $targetDevice) {
  if ($DryRun) {
    $targetDevice = '<device>'
  } else {
    $targetDevice = Select-HarmonyDevice -Toolchain $toolchain
  }
}

$commands = [Collections.Generic.List[object]]::new()
$commands.Add([pscustomobject]@{ Label = 'install'; Args = @('-t', $targetDevice, 'install', '-r', $HapPath) })
if ($ClearData) {
  $commands.Add([pscustomobject]@{ Label = 'force-stop'; Args = @('-t', $targetDevice, 'shell', "aa force-stop $BundleName") })
  $commands.Add([pscustomobject]@{ Label = 'clear-data'; Args = @('-t', $targetDevice, 'shell', "bm clean -n $BundleName -d") })
  $commands.Add([pscustomobject]@{ Label = 'clear-cache'; Args = @('-t', $targetDevice, 'shell', "bm clean -n $BundleName -c") })
}
if (-not $NoLaunch) {
  $commands.Add([pscustomobject]@{ Label = 'start'; Args = @('-t', $targetDevice, 'shell', "aa start -a $AbilityName -b $BundleName -m $ModuleName") })
}

Write-Host ''
Write-Host "HAP:    $HapPath" -ForegroundColor Cyan
Write-Host "bundle: $BundleName   ability: $AbilityName   device: $targetDevice"
Write-Host ('-' * 72)

if ($DryRun) {
  Write-Host 'DRY RUN（不执行任何设备命令）：' -ForegroundColor Yellow
  foreach ($command in $commands) {
    Write-Host ("  hdc " + ($command.Args -join ' '))
  }
  Write-Host ''
  exit 0
}

$failed = $false
foreach ($command in $commands) {
  Write-Host ("[hdc {0}] hdc {1}" -f $command.Label, ($command.Args -join ' ')) -ForegroundColor Yellow
  $output = & $toolchain.HdcExe @($command.Args) 2>&1
  $exitCode = $LASTEXITCODE
  $text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
  if ($text) { Write-Host $text }
  if ($exitCode -ne 0) {
    Write-Host ("[FAIL] hdc {0} exit={1}" -f $command.Label, $exitCode) -ForegroundColor Red
    if ($command.Label -eq 'install') {
      Write-Host '安装失败常见原因：' -ForegroundColor Yellow
      Write-Host '  - 9568322 / signature not trusted：签名不受信任（release 证书或本地自签不能侧载到零售机）'
      Write-Host '  - bundleName 与 profile 不一致：hvigor 构建阶段应已报 00303074'
      Write-Host '  - device-ids 白名单不含本机 UDID：用 DevEco 自动签名重新生成 debug profile'
      Write-Host '  - 手机未解锁/未授权 USB 调试：hdc list targets -v 检查状态'
    }
    $failed = $true
    break
  }
}

if (-not $failed -and -not $NoLaunch) {
  Start-Sleep -Seconds $LaunchWaitSeconds
  $pidOutput = & $toolchain.HdcExe -t $targetDevice shell "pidof $BundleName" 2>&1
  $processId = (($pidOutput | ForEach-Object { [string]$_ }) -join ' ').Trim()
  if ($processId) {
    Write-Host "[OK] 应用已启动，进程号: $processId" -ForegroundColor Green
  } else {
    Write-Host '[WARN] aa start 已返回，但 pidof 未看到进程；用 device.ps1 log 看启动日志。' -ForegroundColor Yellow
  }
}

Write-Host ''
if ($failed) { exit 1 }
Write-Host '下一步：' -ForegroundColor Cyan
Write-Host '  .\scripts\harmony\device.ps1 log -Follow            # 抓 hilog'
Write-Host '  .\scripts\harmony\device.ps1 screenshot             # 真机截图'
Write-Host '  .\scripts\harmony\verify-signing.ps1 -Target hap -HapPath <hap>   # 校验签名'
Write-Host ''
exit 0
