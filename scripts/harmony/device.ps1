<#
.SYNOPSIS
  HarmonyOS 真机调试助手（hdc 封装）：列设备、启动/停止、日志、截图、清数据、卸载、设备信息、取 UDID。

.DESCRIPTION
  子命令（第一个位置参数）：
    list        列出 hdc 目标（默认命令）
    start       启动应用（aa start）
    stop        强制停止应用（aa force-stop）
    log         抓 hilog（-Tag 客户端过滤 / -DurationSeconds 定时 / -Follow 持续）
    screenshot  真机截图（优先 uitest screenCap，回退 snapshot_display）并拉回本地
    clear-data  清应用数据与缓存（bm clean -d/-c）
    uninstall   卸载应用
    info        设备信息（型号/API/设备类型）
    udid        读取设备 UDID（用于 AGC/DevEco 调试设备白名单；属设备标识，勿提交仓库）
    help        显示帮助

.EXAMPLE
  .\scripts\harmony\device.ps1
  .\scripts\harmony\device.ps1 log -Tag HGHub -DurationSeconds 20
  .\scripts\harmony\device.ps1 screenshot
  .\scripts\harmony\device.ps1 clear-data
  .\scripts\harmony\device.ps1 udid
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet('list', 'start', 'stop', 'log', 'screenshot', 'clear-data', 'uninstall', 'info', 'udid', 'help')]
  [string]$Command = 'list',
  [string]$DevEcoHome = '',
  [string]$ProjectPath = '',
  [string]$Device = '',
  [string]$BundleName = '',
  [string]$AbilityName = 'EntryAbility',
  [string]$ModuleName = 'entry',
  [string[]]$WantParams = @(),
  [string]$Tag = '',
  [int]$DurationSeconds = 0,
  [int]$Tail = 80,
  [string]$OutFile = '',
  [string]$OutDir = '',
  [switch]$Follow,
  [switch]$DryRun,
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'env.ps1') -DevEcoHome $DevEcoHome -Quiet
$toolchain = $HarmonyToolchain
$ErrorActionPreference = 'Continue'

function Get-Context {
  $project = $null
  try { $project = Get-HarmonyProjectPath -ProjectPath $ProjectPath } catch { }
  $bundle = $BundleName
  if (-not $bundle -and $project) { $bundle = Get-HarmonyBundleName -ProjectPath $project }
  $deviceId = $Device
  if (-not $deviceId) {
    if ($DryRun) { $deviceId = '<device>' } else { $deviceId = Select-HarmonyDevice -Toolchain $toolchain }
  }
  return [pscustomobject]@{ Project = $project; BundleName = $bundle; Device = $deviceId }
}

function Invoke-DeviceHdc {
  param([string[]]$Arguments)

  if ($DryRun) {
    Write-Host ("  hdc " + ($Arguments -join ' ')) -ForegroundColor Yellow
    return [pscustomobject]@{ ExitCode = 0; Text = '' }
  }
  $output = & $toolchain.HdcExe @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
  return [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

if ($Command -eq 'help') {
  Get-Help $PSCommandPath -Detailed
  exit 0
}

if ($Command -eq 'list') {
  $targets = @(Get-HarmonyHdcTargets -Toolchain $toolchain)
  $raw = @(& $toolchain.HdcExe list targets -v 2>&1)
  if ($Json) {
    [pscustomobject]@{ Ready = $targets; Raw = $raw } | ConvertTo-Json -Depth 4
    exit 0
  }
  Write-Host ''
  Write-Host "hdc: $($toolchain.HdcExe)" -ForegroundColor Cyan
  if ($targets.Count -eq 0) {
    Write-Host '没有可用的 USB/TCP 设备。' -ForegroundColor Yellow
    Write-Host '真机准备：设置 > 系统 > 开发者选项 → 打开“开发者模式”“USB 调试” → USB 连接并允许调试。'
    Write-Host '提示：hdc 会把主板串口（COMx，UART）列为目标，本脚本默认忽略；排查时可用 -AllowUart。'
    if ($raw.Count -gt 0) {
      Write-Host '--- hdc list targets -v 原始输出 ---' -ForegroundColor DarkGray
      $raw | ForEach-Object { Write-Host $_ }
    }
  } else {
    $targets | Format-Table Id, Transport, Status -AutoSize | Out-String -Width 200 | Write-Host
  }
  Write-Host ''
  exit 0
}

$context = Get-Context
if (-not $context.BundleName -and $Command -in @('start', 'stop', 'clear-data', 'uninstall', 'log')) {
  throw '无法确定 bundleName：用 -BundleName 指定。'
}

switch ($Command) {
  'start' {
    $shell = "aa start -a $AbilityName -b $($context.BundleName) -m $ModuleName"
    if ($WantParams.Count -gt 0) { $shell += ' ' + ($WantParams -join ' ') }
    Write-Host "启动 $($context.BundleName) on $($context.Device)" -ForegroundColor Cyan
    $result = Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', $shell)
    if ($result.Text) { Write-Host $result.Text }
    if ($result.ExitCode -ne 0) { exit 1 }
    Start-Sleep -Seconds 2
    $pidResult = Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', "pidof $($context.BundleName)")
    if ($pidResult.Text) { Write-Host "[OK] pid: $($pidResult.Text)" -ForegroundColor Green }
  }
  'stop' {
    Write-Host "停止 $($context.BundleName)" -ForegroundColor Cyan
    $result = Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', "aa force-stop $($context.BundleName)")
    if ($result.Text) { Write-Host $result.Text }
    if ($result.ExitCode -ne 0) { exit 1 }
  }
  'clear-data' {
    Write-Host "清除 $($context.BundleName) 的数据与缓存" -ForegroundColor Cyan
    Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', "aa force-stop $($context.BundleName)") | Out-Null
    $data = Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', "bm clean -n $($context.BundleName) -d")
    $cache = Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', "bm clean -n $($context.BundleName) -c")
    if ($data.Text) { Write-Host $data.Text }
    if ($cache.Text) { Write-Host $cache.Text }
    if ($data.ExitCode -ne 0 -or $cache.ExitCode -ne 0) { exit 1 }
    Write-Host '[OK] 已清空应用数据' -ForegroundColor Green
  }
  'uninstall' {
    Write-Host "卸载 $($context.BundleName)" -ForegroundColor Cyan
    $result = Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'uninstall', $context.BundleName)
    if ($result.Text) { Write-Host $result.Text }
    if ($result.ExitCode -ne 0) { exit 1 }
  }
  'info' {
    $fields = [ordered]@{
      'const.product.model'      = '产品型号'
      'const.ohos.apiversion'    = 'API 版本'
      'const.product.devicetype' = '设备类型'
      'const.build.udid'         = 'UDID（敏感，勿提交）'
    }
    $rows = @()
    foreach ($key in $fields.Keys) {
      $result = Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', "param get $key")
      $rows += [pscustomobject]@{ Key = $key; Label = $fields[$key]; Value = $result.Text }
    }
    if ($Json) { $rows | ConvertTo-Json -Depth 3; exit 0 }
    Write-Host ''
    $rows | Format-Table Key, Label, Value -AutoSize | Out-String -Width 200 | Write-Host
    exit 0
  }
  'udid' {
    if ($DryRun) {
      Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', 'bm get --udid') | Out-Null
      exit 0
    }
    $udid = ''
    foreach ($arguments in @(@('shell', 'bm get --udid'), @('shell', 'bm get -u'))) {
      $result = Invoke-DeviceHdc -Arguments (@('-t', $context.Device) + $arguments)
      if ($result.ExitCode -eq 0 -and $result.Text) {
        $match = [regex]::Match($result.Text, '[0-9A-Fa-f]{32,64}')
        if ($match.Success) { $udid = $match.Value; break }
      }
    }
    if (-not $udid) {
      Write-Host '未能读取 UDID。可在手机“设置 > 关于手机”查看，或 DevEco Studio Device Manager 中查看。' -ForegroundColor Yellow
      exit 1
    }
    Write-Host ''
    Write-Host "UDID: $udid" -ForegroundColor Cyan
    Write-Host '用途：注册到 AGC 调试设备白名单 / DevEco 自动签名。' -ForegroundColor DarkGray
    Write-Host '注意：UDID 是设备标识，不要写入公开仓库文档或提交记录。' -ForegroundColor Yellow
    exit 0
  }
  'screenshot' {
    if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '.local\screenshots' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $fileName = "hghub-$stamp.jpeg"
    $localPath = Join-Path $OutDir $fileName
    $remotePath = "/data/local/tmp/$fileName"
    Write-Host "截图 $($context.Device) -> $localPath" -ForegroundColor Cyan
    $captured = $false
    if ($DryRun) {
      Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', "uitest screenCap -p $remotePath") | Out-Null
      Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'file', 'recv', $remotePath, $localPath) | Out-Null
      exit 0
    }
    $result = Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', "uitest screenCap -p $remotePath")
    if ($result.ExitCode -eq 0) {
      $recv = Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'file', 'recv', $remotePath, $localPath)
      $captured = ($recv.ExitCode -eq 0 -and (Test-Path -LiteralPath $localPath))
    }
    if (-not $captured) {
      Write-Host 'uitest screenCap 不可用，回退 snapshot_display ...' -ForegroundColor DarkYellow
      $result = Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', "snapshot_display -f $remotePath")
      if ($result.ExitCode -eq 0) {
        $recv = Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'file', 'recv', $remotePath, $localPath)
        $captured = ($recv.ExitCode -eq 0 -and (Test-Path -LiteralPath $localPath))
      }
    }
    Invoke-DeviceHdc -Arguments @('-t', $context.Device, 'shell', "rm -f $remotePath") | Out-Null
    if (-not $captured) {
      Write-Host '截图失败（两套命令均不可用）。' -ForegroundColor Red
      exit 1
    }
    Write-Host "[OK] 截图已保存: $localPath" -ForegroundColor Green
    if ($Json) { [pscustomobject]@{ Path = $localPath; Device = $context.Device } | ConvertTo-Json }
  }
  'log' {
    if ($OutFile) {
      $logFull = [IO.Path]::GetFullPath($OutFile)
      $logDir = Split-Path -Parent $logFull
      if ($logDir) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    }
    $filter = { param($line) if ($Tag) { $line -match $Tag } else { $true } }
    if ($DryRun) {
      Write-Host "  hdc -t $($context.Device) hilog" -ForegroundColor Yellow
      if ($Tag) { Write-Host "  (客户端过滤: $Tag)" }
      exit 0
    }
    if ($DurationSeconds -gt 0) {
      Write-Host "抓取 hilog $DurationSeconds 秒（Tag 过滤: $(if ($Tag) { $Tag } else { '无' }）)" -ForegroundColor Cyan
      $job = Start-Job -ScriptBlock {
        param($hdc, $dev)
        & $hdc -t $dev hilog 2>&1 | ForEach-Object { [string]$_ }
      } -ArgumentList $toolchain.HdcExe, $context.Device
      Wait-Job -Job $job -Timeout $DurationSeconds | Out-Null
      $lines = @(Receive-Job -Job $job -Keep)
      Stop-Job -Job $job -ErrorAction SilentlyContinue
      Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
      $filtered = @($lines | Where-Object { & $filter $_ })
      if ($OutFile) {
        Set-Content -LiteralPath $logFull -Value ($filtered -join [Environment]::NewLine) -Encoding UTF8
        Write-Host "[OK] 日志已写入: $logFull" -ForegroundColor Green
      }
      $tailLines = if ($Tail -gt 0) { $filtered | Select-Object -Last $Tail } else { $filtered }
      $tailLines | ForEach-Object { Write-Host $_ }
      Write-Host ("[OK] 共 {0} 行（显示 {1} 行）" -f $filtered.Count, @($tailLines).Count) -ForegroundColor Green
      exit 0
    }
    Write-Host '持续抓取 hilog（Ctrl+C 结束）...' -ForegroundColor Cyan
    $streamed = @()
    & $toolchain.HdcExe -t $context.Device hilog 2>&1 | ForEach-Object {
      $line = [string]$_
      if (& $filter $line) {
        Write-Host $line
        if ($OutFile) { $streamed += $line }
      }
    }
    if ($OutFile) {
      Set-Content -LiteralPath $logFull -Value ($streamed -join [Environment]::NewLine) -Encoding UTF8
      Write-Host "[OK] 日志已写入: $logFull" -ForegroundColor Green
    }
  }
}
