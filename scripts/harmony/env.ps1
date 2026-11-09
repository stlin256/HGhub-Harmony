<#
.SYNOPSIS
  HarmonyOS CLI 环境初始化（可 dot-source 复用）。

.DESCRIPTION
  探测 DevEco Studio 26.0.0 安装目录，设置 hvigor/ohpm/hdc 所需的
  NODE_HOME、JAVA_HOME、DEVECO_SDK_HOME 与 PATH，并导出 HarmonyToolchain
  以及一组共享函数，供 scripts/harmony 下的其它脚本复用。

  用法：
    # 作为模块复用（推荐给其它脚本 / 交互式会话）
    . .\scripts\harmony\env.ps1
    . .\scripts\harmony\env.ps1 -DevEcoHome 'C:\...\DevEcoStudio-26.0.0'

    # 直接执行：打印本机环境摘要
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\harmony\env.ps1

  探测顺序：
    1. -DevEcoHome 显式参数
    2. 环境变量 DEVECO_STUDIO_HOME / DEVECO_HOME
    3. %LOCALAPPDATA%\Programs\Huawei\DevEcoStudio-*（取版本号最高者）
    4. %ProgramFiles% / %ProgramFiles(x86)%\Huawei\DevEcoStudio-*

  本脚本只读探测，不修改仓库内任何文件。
#>
param(
  [string]$DevEcoHome = '',
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Test-HarmonyDevEcoHome {
  param([AllowEmptyString()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $required = @(
    'tools\node\node.exe',
    'tools\ohpm\bin\ohpm.bat',
    'tools\hvigor\bin\hvigorw.js',
    'jbr\bin\java.exe',
    'sdk\default\openharmony\toolchains\hdc.exe'
  )
  foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $Path $relative) -PathType Leaf)) {
      return $false
    }
  }
  return $true
}

function Resolve-HarmonyDevEcoHome {
  param([AllowEmptyString()][string]$ExplicitHome = '')

  if (-not [string]::IsNullOrWhiteSpace($ExplicitHome)) {
    if (-not (Test-HarmonyDevEcoHome $ExplicitHome)) {
      throw "DevEco Studio home is incomplete (missing node/ohpm/hvigor/jbr/hdc): $ExplicitHome"
    }
    return (Resolve-Path -LiteralPath $ExplicitHome).Path
  }

  foreach ($candidate in @($env:DEVECO_STUDIO_HOME, $env:DEVECO_HOME)) {
    if (Test-HarmonyDevEcoHome $candidate) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  $localAppData = [Environment]::GetFolderPath('LocalApplicationData')
  $programFiles = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  $searchParents = [Collections.Generic.List[string]]::new()
  if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
    $searchParents.Add((Join-Path $localAppData 'Programs\Huawei'))
    $searchParents.Add((Join-Path $localAppData 'Programs'))
    $searchParents.Add((Join-Path $localAppData 'Huawei'))
  }
  foreach ($root in $programFiles) {
    $searchParents.Add($root)
    $searchParents.Add((Join-Path $root 'Huawei'))
    $searchParents.Add((Join-Path $root 'DevEco Studio'))
  }

  $discovered = [Collections.Generic.List[object]]::new()
  foreach ($parent in ($searchParents | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
    if (Test-HarmonyDevEcoHome $parent) {
      $discovered.Add([pscustomobject]@{ Path = (Resolve-Path -LiteralPath $parent).Path; Version = '0' })
    }
    foreach ($child in Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue) {
      if ($child.Name -notlike 'DevEcoStudio*' -and $child.Name -notlike 'DevEco Studio*') { continue }
      if (-not (Test-HarmonyDevEcoHome $child.FullName)) { continue }
      $version = '0'
      $info = Join-Path $child.FullName 'product-info.json'
      if (Test-Path -LiteralPath $info -PathType Leaf) {
        try {
          $version = (Get-Content -LiteralPath $info -Raw -Encoding UTF8 | ConvertFrom-Json).version
        } catch {
          $version = '0'
        }
      }
      $discovered.Add([pscustomobject]@{ Path = $child.FullName; Version = [string]$version })
    }
  }

  $match = $discovered |
    Sort-Object -Property @{ Expression = { $_.Version }; Descending = $true }, @{ Expression = { $_.Path }; Descending = $true } |
    Select-Object -First 1
  if (-not $match) {
    throw @'
DevEco Studio (HarmonyOS SDK) was not found.
Set DEVECO_STUDIO_HOME or pass -DevEcoHome explicitly, for example:
  . .\scripts\harmony\env.ps1 -DevEcoHome "$env:LOCALAPPDATA\Programs\Huawei\DevEcoStudio-26.0.0"
'@
  }
  return $match.Path
}

function Get-HarmonyFileVersion {
  param([string]$JsonPath, [string]$Property = 'version')

  if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) { return '' }
  try {
    $json = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return [string]$json.$Property
  } catch {
    return ''
  }
}

function Add-HarmonyPathEntry {
  param([string]$Entry)

  if ([string]::IsNullOrWhiteSpace($Entry)) { return }
  foreach ($existing in ($env:PATH -split ';')) {
    if ($existing.TrimEnd('\') -ieq $Entry.TrimEnd('\')) { return }
  }
  $env:PATH = $Entry + ';' + $env:PATH
}

function Get-HarmonyToolchain {
  param([string]$DevEcoHome = '')

  $ideHome = Resolve-HarmonyDevEcoHome -ExplicitHome $DevEcoHome
  $sdkDir = Join-Path $ideHome 'sdk'
  $toolchain = [pscustomobject]@{
    DevEcoHome       = $ideHome
    DevEcoVersion    = (Get-HarmonyFileVersion (Join-Path $ideHome 'product-info.json'))
    SdkDir           = $sdkDir
    SdkApiVersion    = ''
    SdkPlatform      = ''
    SdkVersion       = ''
    NodeHome         = (Join-Path $ideHome 'tools\node')
    NodeExe          = (Join-Path $ideHome 'tools\node\node.exe')
    NpmCmd           = (Join-Path $ideHome 'tools\node\npm.cmd')
    JavaHome         = (Join-Path $ideHome 'jbr')
    JavaExe          = (Join-Path $ideHome 'jbr\bin\java.exe')
    KeytoolExe       = (Join-Path $ideHome 'jbr\bin\keytool.exe')
    OhpmBat          = (Join-Path $ideHome 'tools\ohpm\bin\ohpm.bat')
    OhpmVersion      = (Get-HarmonyFileVersion (Join-Path $ideHome 'tools\ohpm\package.json'))
    HvigorJs         = (Join-Path $ideHome 'tools\hvigor\bin\hvigorw.js')
    HvigorVersion    = (Get-HarmonyFileVersion (Join-Path $ideHome 'tools\hvigor\hvigor\package.json'))
    HvigorPluginVer  = (Get-HarmonyFileVersion (Join-Path $ideHome 'tools\hvigor\hvigor-ohos-plugin\package.json'))
    HdcExe           = (Join-Path $ideHome 'sdk\default\openharmony\toolchains\hdc.exe')
    SignToolJar      = (Join-Path $ideHome 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar')
    SignLibDir       = (Join-Path $ideHome 'sdk\default\openharmony\toolchains\lib')
    RepoRoot         = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
  }
  $toolchain | Add-Member -NotePropertyName HarmonyProject -NotePropertyValue (Join-Path $toolchain.RepoRoot 'harmony')

  $sdkPkg = Join-Path $sdkDir 'default\sdk-pkg.json'
  if (Test-Path -LiteralPath $sdkPkg -PathType Leaf) {
    try {
      $data = (Get-Content -LiteralPath $sdkPkg -Raw -Encoding UTF8 | ConvertFrom-Json).data
      $toolchain.SdkApiVersion = [string]$data.apiVersion
      $toolchain.SdkPlatform = [string]$data.platformVersion
      $toolchain.SdkVersion = [string]$data.version
    } catch { }
  }

  if (-not (Test-Path -LiteralPath (Join-Path $toolchain.HarmonyProject 'AppScope\app.json5') -PathType Leaf)) {
    $toolchain.HarmonyProject = ''
  }
  return $toolchain
}

function Initialize-HarmonyEnvironment {
  param([Parameter(Mandatory = $true)]$Toolchain)

  $env:NODE_HOME = $Toolchain.NodeHome
  $env:JAVA_HOME = $Toolchain.JavaHome
  $env:DEVECO_SDK_HOME = $Toolchain.SdkDir
  $env:DEVECO_CLI_STUDIO_PATH = $Toolchain.DevEcoHome
  Add-HarmonyPathEntry $Toolchain.NodeHome
  Add-HarmonyPathEntry (Join-Path $Toolchain.JavaHome 'bin')
  Add-HarmonyPathEntry (Join-Path $Toolchain.DevEcoHome 'tools\hvigor\bin')
  Add-HarmonyPathEntry (Join-Path $Toolchain.DevEcoHome 'sdk\default\openharmony\toolchains')
  return $Toolchain
}

function Get-HarmonyVersionReport {
  param([Parameter(Mandatory = $true)]$Toolchain)

  $nodeVersion = (& $Toolchain.NodeExe --version 2>&1 | Select-Object -First 1)
  $hdcVersion = (& $Toolchain.HdcExe -v 2>&1 | Select-Object -Last 1)
  $javaRelease = Join-Path $Toolchain.JavaHome 'release'
  $javaVersion = ''
  if (Test-Path -LiteralPath $javaRelease -PathType Leaf) {
    $match = [regex]::Match((Get-Content -LiteralPath $javaRelease -Raw), 'JAVA_VERSION="([^"]+)"')
    if ($match.Success) { $javaVersion = $match.Groups[1].Value }
  }
  $ohpmVersion = ''
  try { $ohpmVersion = (& $Toolchain.OhpmBat -v 2>&1 | Where-Object { $_ -match '^\d' } | Select-Object -First 1) } catch { }

  return [pscustomobject]@{
    DevEcoStudio    = "$($Toolchain.DevEcoVersion)  ($($Toolchain.DevEcoHome))"
    HarmonyOSSDK    = "API $($Toolchain.SdkApiVersion) / platform $($Toolchain.SdkPlatform) / $($Toolchain.SdkVersion)"
    Hvigor          = "$($Toolchain.HvigorVersion)  (plugin $($Toolchain.HvigorPluginVer))"
    Ohpm            = $ohpmVersion
    Node            = [string]$nodeVersion
    Java            = "$javaVersion  (JBR)"
    Hdc             = [string]$hdcVersion
    SignTool        = $(if (Test-Path -LiteralPath $Toolchain.SignToolJar -PathType Leaf) { 'hap-sign-tool.jar present' } else { 'MISSING' })
  }
}

function Show-HarmonyVersionReport {
  param([Parameter(Mandatory = $true)]$Toolchain)

  $report = Get-HarmonyVersionReport -Toolchain $Toolchain
  Write-Host ''
  Write-Host 'HarmonyOS CLI toolchain (DevEco Studio)' -ForegroundColor Cyan
  Write-Host ('-' * 72)
  foreach ($property in $report.PSObject.Properties) {
    Write-Host ('{0,-15} {1}' -f ($property.Name + ':'), $property.Value)
  }
  Write-Host ('-' * 72)
  Write-Host ('NODE_HOME      = ' + $env:NODE_HOME)
  Write-Host ('JAVA_HOME      = ' + $env:JAVA_HOME)
  Write-Host ('DEVECO_SDK_HOME= ' + $env:DEVECO_SDK_HOME)
  Write-Host ''
}

function Get-HarmonyProjectPath {
  param([AllowEmptyString()][string]$ProjectPath = '')

  $toolchain = Get-HarmonyToolchain -DevEcoHome $script:HarmonyDevEcoHome
  if ([string]::IsNullOrWhiteSpace($ProjectPath)) {
    if ([string]::IsNullOrWhiteSpace($toolchain.HarmonyProject)) {
      throw "harmony/ project not found under $($toolchain.RepoRoot)"
    }
    return $toolchain.HarmonyProject
  }
  $resolved = (Resolve-Path -LiteralPath $ProjectPath -ErrorAction Stop).Path
  if (-not (Test-Path -LiteralPath (Join-Path $resolved 'build-profile.json5') -PathType Leaf)) {
    throw "Not a HarmonyOS hvigor project (build-profile.json5 missing): $resolved"
  }
  return $resolved
}

function Get-HarmonyBundleName {
  param([Parameter(Mandatory = $true)][string]$ProjectPath)

  $appJson = Join-Path $ProjectPath 'AppScope\app.json5'
  if (-not (Test-Path -LiteralPath $appJson -PathType Leaf)) { return '' }
  $match = [regex]::Match((Get-Content -LiteralPath $appJson -Raw -Encoding UTF8), '"bundleName"\s*:\s*"([^"]+)"')
  if ($match.Success) { return $match.Groups[1].Value }
  return ''
}

function Get-HarmonyHdcTargets {
  param(
    [Parameter(Mandatory = $true)]$Toolchain,
    [switch]$AllowUart
  )

  $lines = @(& $Toolchain.HdcExe list targets -v 2>&1)
  $targets = [Collections.Generic.List[object]]::new()
  foreach ($line in $lines) {
    $text = ([string]$line).Trim()
    if (-not $text -or $text -eq '[Empty]') { continue }
    $parts = $text -split "\t+" | Where-Object { $_ -ne '' }
    if ($parts.Count -lt 3) { continue }
    $id = $parts[0]
    $transport = $parts[1]
    $status = $parts[2]
    if ($status -notmatch '^(Ready|Connected)$') { continue }
    if ($transport -eq 'UART' -and -not $AllowUart) { continue }
    $targets.Add([pscustomobject]@{
        Id        = $id
        Transport = $transport
        Status    = $status
        Raw       = $text
      })
  }
  return $targets
}

function Select-HarmonyDevice {
  param(
    [Parameter(Mandatory = $true)]$Toolchain,
    [AllowEmptyString()][string]$Device = '',
    [switch]$AllowUart
  )

  if (-not [string]::IsNullOrWhiteSpace($Device)) { return $Device }
  $targets = @(Get-HarmonyHdcTargets -Toolchain $Toolchain -AllowUart:$AllowUart)
  if ($targets.Count -eq 0) {
    throw @'
No ready HarmonyOS device found.
  1. 手机开启“开发者模式”与“USB 调试”（设置 > 系统 > 开发者选项）。
  2. USB 连接电脑，手机上允许调试授权。
  3. 验证：<DevEco>\sdk\default\openharmony\toolchains\hdc.exe list targets -v
注意：hdc 会把主板串口（UART/COMx）误报为目标，本脚本默认忽略 UART，只认 USB/TCP。
'@
  }
  if ($targets.Count -gt 1) {
    Write-Warning ("Multiple devices found, using first: " + $targets[0].Id)
  }
  return $targets[0].Id
}

function Invoke-HarmonyHdc {
  param(
    [Parameter(Mandatory = $true)]$Toolchain,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $output = & $Toolchain.HdcExe @Arguments 2>&1
  return [pscustomobject]@{
    ExitCode = $LASTEXITCODE
    Output   = ($output | Out-String).Trim()
  }
}

function Get-HarmonyHap {
  param(
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [string]$Product = '',
    [switch]$IncludeUnsigned
  )

  $pattern = if ($Product) { "entry\build\$Product\outputs\$Product\*.hap" } else { 'entry\build\*\outputs\*\*.hap' }
  $haps = @(Get-ChildItem -Path (Join-Path $ProjectPath $pattern) -File -ErrorAction SilentlyContinue)
  if (-not $IncludeUnsigned) {
    $signed = @($haps | Where-Object { $_.Name -like '*-signed.hap' })
    if ($signed.Count -gt 0) { $haps = $signed }
  }
  if ($haps.Count -eq 0) { return $null }
  return ($haps | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

# 兼容旧脚本：允许通过 -DevEcoHome 参数覆盖自动探测。
$script:HarmonyDevEcoHome = $DevEcoHome

$HarmonyToolchain = Get-HarmonyToolchain -DevEcoHome $DevEcoHome
Initialize-HarmonyEnvironment -Toolchain $HarmonyToolchain | Out-Null

# dot-source 调用时 $MyInvocation.InvocationName 为 '.'；直接执行时打印摘要。
$dotSourced = $MyInvocation.InvocationName -eq '.'
if (-not $dotSourced) {
  Show-HarmonyVersionReport -Toolchain $HarmonyToolchain
} elseif (-not $Quiet) {
  Write-Verbose "HarmonyOS toolchain ready: $($HarmonyToolchain.DevEcoHome)"
}