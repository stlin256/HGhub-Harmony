<#
.SYNOPSIS
  【实验/模拟器路径】用 hap-sign-tool + OpenHarmony 公共测试 CA 离线自签名 HAP（Plan B）。

.DESCRIPTION
  不需要华为账号，也不需要 AGC，用 DevEco SDK 自带的 OpenHarmony 测试签名材料
  （toolchains/lib/OpenHarmony.p12，公开测试口令 123456）走完整签名链：
    generate-keypair → generate-csr → generate-app-cert → 生成本地 debug profile
    → sign-profile → sign-app → verify-app

  重要限制（务必阅读）：
    - 这条链的根证书是 OpenHarmony 公共测试 CA，**不在 HarmonyOS NEXT 零售手机的信任链里**，
      侧载大概率报 9568322 / signature not trusted；只在 OpenHarmony 设备、部分模拟器或
      “验证签名链路是否可用”的离线实验里有意义。
    - 正式真机调试必须用 DevEco 自动签名（需华为账号）或 AGC 签发的 debug profile（见 ENVIRONMENT.md Plan A）。
    - 生成的密钥/证书/profile/HAP 全部写在 scripts/harmony/.local/local-sign/（已被 .gitignore 忽略），
      绝不要把其中的私钥或口令提交到仓库。

.EXAMPLE
  # 先用 build.ps1 产出 unsigned HAP，然后：
  .\scripts\harmony\local-sign.ps1 -DeviceUdid <设备的64位UDID>
  .\scripts\harmony\local-sign.ps1 -HapPath harmony\entry\build\default\outputs\default\entry-default-unsigned.hap -DeviceUdid <udid> -Force
#>
param(
  [string]$DevEcoHome = '',
  [string]$ProjectPath = '',
  [string]$HapPath = '',
  [string]$BundleName = '',
  [string]$OutDir = '',
  [string]$DeviceUdid = '',
  [int]$CompatibleVersion = 23,
  [switch]$Force
)

. (Join-Path $PSScriptRoot 'env.ps1') -DevEcoHome $DevEcoHome -Quiet
$toolchain = $HarmonyToolchain
$ErrorActionPreference = 'Continue'

function Invoke-Tool {
  param([string]$Label, [string[]]$Arguments)
  $output = & $toolchain.JavaExe -jar $toolchain.SignToolJar @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
  if ($exitCode -ne 0) {
    Write-Host $text
    throw "$Label 失败（exit=$exitCode）"
  }
  return $text
}

$project = $null
try { $project = Get-HarmonyProjectPath -ProjectPath $ProjectPath } catch { }

if (-not $BundleName) {
  if ($project) { $BundleName = Get-HarmonyBundleName -ProjectPath $project }
  if (-not $BundleName) { throw '无法确定 bundleName：用 -BundleName 指定。' }
}

if (-not $HapPath) {
  if (-not $project) { throw '未指定 -HapPath，且未找到 harmony/ 工程。' }
  $hap = Get-HarmonyHap -ProjectPath $project -IncludeUnsigned
  if (-not $hap) { throw '没有找到 HAP 产物：先运行 .\scripts\harmony\build.ps1' }
  $HapPath = $hap.FullName
}
$HapPath = (Resolve-Path -LiteralPath $HapPath -ErrorAction Stop).Path
if ((Split-Path -Leaf $HapPath) -like '*-signed.hap') {
  Write-Warning "输入 HAP 已是签名产物，重复 sign-app 可能失败；建议用 *-unsigned.hap。"
}

if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot '.local\local-sign' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

if (-not $DeviceUdid) {
  $targets = @(Get-HarmonyHdcTargets -Toolchain $toolchain)
  if ($targets.Count -gt 0) {
    $device = $targets[0].Id
    $result = & $toolchain.HdcExe -t $device shell "bm get --udid" 2>&1
    $match = [regex]::Match((($result | ForEach-Object { [string]$_ }) -join ' '), '[0-9A-Fa-f]{32,64}')
    if ($match.Success) {
      $DeviceUdid = $match.Value
      Write-Host "已从设备读取 UDID（不显示明文）。" -ForegroundColor DarkGray
    }
  }
}
if (-not $DeviceUdid) {
  throw @'
需要设备 UDID 才能生成本地 debug profile。
  - 手机连接后重跑本脚本（会自动读取 bm get --udid），或
  - 显式传入：-DeviceUdid <64位十六进制>
UDID 属设备标识：不要写进仓库文档或提交记录，本脚本也不会把它打印出来。
'@
}

$libDir = $toolchain.SignLibDir
$ohKeystore = Join-Path $libDir 'OpenHarmony.p12'
$profileCert = Join-Path $libDir 'OpenHarmonyProfileDebug.pem'
$profileTemplate = Join-Path $libDir 'UnsgnedDebugProfileTemplate.json'
foreach ($required in @($ohKeystore, $profileCert, $profileTemplate)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "DevEco SDK 缺少签名材料：$required"
  }
}

$files = [pscustomobject]@{
  RootCa          = Join-Path $OutDir 'root-ca.cer'
  SubCa           = Join-Path $OutDir 'sub-ca.cer'
  AppKeystore     = Join-Path $OutDir 'app-keypair.p12'
  AppCsr          = Join-Path $OutDir 'hghub-local.csr'
  AppCertChain    = Join-Path $OutDir 'app-debug-cert.cer'
  ProfileJson     = Join-Path $OutDir 'local-debug-profile.json'
  ProfileP7b      = Join-Path $OutDir 'local-debug-profile.p7b'
  SignedHap       = Join-Path $OutDir ((Split-Path -Leaf $HapPath) -replace '-unsigned\.hap$', '-local-signed.hap')
  Readme          = Join-Path $OutDir 'README.txt'
}

Write-Host ''
Write-Host '=== Plan B: 本地离线自签名（实验路径，零售机大概率不可安装）===' -ForegroundColor Yellow
Write-Host "输入 HAP : $HapPath"
Write-Host "bundleName: $BundleName   output: $OutDir"
Write-Host ('-' * 78)

$keyAlias = 'hghub-local-debug-key'
$keyPassword = '123456'
$keyPasswordOh = '123456'
$subject = 'C=CN,O=HGhub,OU=HGhub Local,CN=HGhub Local Debug'
$issuer = 'C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA'

if ($Force -or -not ((Test-Path $files.AppKeystore) -and (Test-Path $files.AppCertChain) -and (Test-Path $files.ProfileP7b))) {
  Write-Host '[1/6] 导出 OpenHarmony 测试 CA 证书' -ForegroundColor Cyan
  & $toolchain.KeytoolExe -exportcert -rfc -alias 'openharmony application root ca' -keystore $ohKeystore -storetype PKCS12 -storepass $keyPasswordOh -file $files.RootCa *> $null
  if ($LASTEXITCODE -ne 0) { throw '导出 root CA 失败' }
  & $toolchain.KeytoolExe -exportcert -rfc -alias 'openharmony application ca' -keystore $ohKeystore -storetype PKCS12 -storepass $keyPasswordOh -file $files.SubCa *> $null
  if ($LASTEXITCODE -ne 0) { throw '导出 sub CA 失败' }

  Write-Host '[2/6] generate-keypair（ECC NIST-P-256）' -ForegroundColor Cyan
  Invoke-Tool 'generate-keypair' @('generate-keypair', '-keyAlias', $keyAlias, '-keyPwd', $keyPassword, '-keyAlg', 'ECC', '-keySize', 'NIST-P-256', '-keystoreFile', $files.AppKeystore, '-keystorePwd', $keyPassword) | Out-Null

  Write-Host '[3/6] generate-csr' -ForegroundColor Cyan
  Invoke-Tool 'generate-csr' @('generate-csr', '-keyAlias', $keyAlias, '-keyPwd', $keyPassword, '-subject', $subject, '-signAlg', 'SHA256withECDSA', '-keystoreFile', $files.AppKeystore, '-keystorePwd', $keyPassword, '-outFile', $files.AppCsr) | Out-Null

  Write-Host '[4/6] generate-app-cert（用 OpenHarmony 测试 CA 签发三级证书链）' -ForegroundColor Cyan
  Invoke-Tool 'generate-app-cert' @(
    'generate-app-cert', '-keyAlias', $keyAlias, '-keyPwd', $keyPassword,
    '-issuer', $issuer, '-issuerKeyAlias', 'openharmony application ca', '-issuerKeyPwd', $keyPasswordOh,
    '-subject', $subject, '-validity', '365', '-signAlg', 'SHA256withECDSA',
    '-rootCaCertFile', $files.RootCa, '-subCaCertFile', $files.SubCa, '-outForm', 'certChain',
    '-keystoreFile', $files.AppKeystore, '-keystorePwd', $keyPassword,
    '-issuerKeystoreFile', $ohKeystore, '-issuerKeystorePwd', $keyPasswordOh,
    '-outFile', $files.AppCertChain
  ) | Out-Null

  Write-Host '[5/6] 生成本地 debug profile 并 sign-profile' -ForegroundColor Cyan
  $chainText = [IO.File]::ReadAllText($files.AppCertChain)
  $leafMatch = [regex]::Match($chainText, '-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----')
  if (-not $leafMatch.Success) { throw '无法从 app 证书链中提取叶子证书' }
  # hap-sign-tool 解析 profile 里的 PEM 时只接受 LF 换行；Windows 的 CRLF 会导致
  # "Illegal base64 character" 错误，这里统一转成 LF。
  $lf = [string][char]10
  $leafCert = ($leafMatch.Value -replace "\r\n", $lf) + $lf
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $profileObject = [ordered]@{
    'version-name' = '2.0.0'
    'version-code' = 2
    'uuid'         = [guid]::NewGuid().ToString()
    'validity'     = [ordered]@{ 'not-before' = $now; 'not-after' = $now + 365 * 86400 }
    'type'         = 'debug'
    'bundle-info'  = [ordered]@{
      'developer-id'            = 'local-debug'
      'development-certificate' = $leafCert
      'bundle-name'             = $BundleName
      'apl'                     = 'normal'
      'app-feature'             = 'hos_normal_app'
    }
    'acls'         = [ordered]@{ 'allowed-acls' = @() }
    'permissions'  = [ordered]@{ 'restricted-permissions' = @() }
    'debug-info'   = [ordered]@{ 'device-ids' = @($DeviceUdid); 'device-id-type' = 'udid' }
    'issuer'       = 'pki_internal'
  }
  [IO.File]::WriteAllText($files.ProfileJson, ($profileObject | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  Invoke-Tool 'sign-profile' @(
    'sign-profile', '-mode', 'localSign', '-keyAlias', 'openharmony application profile debug', '-keyPwd', $keyPasswordOh,
    '-profileCertFile', $profileCert, '-inFile', $files.ProfileJson, '-signAlg', 'SHA256withECDSA',
    '-keystoreFile', $ohKeystore, '-keystorePwd', $keyPasswordOh, '-outFile', $files.ProfileP7b
  ) | Out-Null
} else {
  Write-Host '[1-5/6] 复用已有本地签名材料（-Force 可重新生成）' -ForegroundColor DarkGray
}

Write-Host '[6/6] sign-app' -ForegroundColor Cyan
Invoke-Tool 'sign-app' @(
  'sign-app', '-mode', 'localSign', '-keyAlias', $keyAlias, '-keyPwd', $keyPassword,
  '-appCertFile', $files.AppCertChain, '-profileFile', $files.ProfileP7b,
  '-inFile', $HapPath, '-signAlg', 'SHA256withECDSA',
  '-keystoreFile', $files.AppKeystore, '-keystorePwd', $keyPassword,
  '-outFile', $files.SignedHap, '-compatibleVersion', "$CompatibleVersion"
) | Out-Null
Write-Host "      产物: $($files.SignedHap)" -ForegroundColor DarkGray

$verifyDir = Join-Path $OutDir 'verify'
New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
$verifyOutput = & $toolchain.JavaExe -jar $toolchain.SignToolJar verify-app -inFile $files.SignedHap -outCertChain (Join-Path $verifyDir 'chain.cer') -outProfile (Join-Path $verifyDir 'profile.p7b') 2>&1
$verifyExit = $LASTEXITCODE
if ($verifyExit -ne 0) {
  Write-Host (($verifyOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
  throw "verify-app 失败（exit=$verifyExit）"
}
Write-Host '[OK] verify-app success' -ForegroundColor Green

$readme = @'
HGhub 本地自签名材料（Plan B，实验路径）
========================================

由 scripts/harmony/local-sign.ps1 生成，使用 DevEco SDK 自带的 OpenHarmony
公共测试 CA（toolchains/lib/OpenHarmony.p12，公开测试口令 123456）。

限制与警告：
- 根证书是 OpenHarmony 公共测试 CA，不在 HarmonyOS NEXT 零售手机信任链内，
  安装大概率失败（9568322 / signature not trusted）。
- 仅用于 OpenHarmony 设备、部分模拟器，或离线验证“证书链/profile/签名”链路。
- 正式真机调试请用 DevEco 自动签名（需华为账号）或 AGC 签发的 debug profile。
- 本目录包含私钥（app-keypair.p12），已在 .gitignore 中（scripts/harmony/.local/），
  禁止提交、禁止用于发布。
'@
[IO.File]::WriteAllText($files.Readme, $readme, [Text.UTF8Encoding]::new($false))

Write-Host ''
Write-Host '=== 结果 ===' -ForegroundColor Cyan
Write-Host "签名 HAP : $($files.SignedHap)"
Write-Host "profile  : $($files.ProfileP7b)"
Write-Host "证书链   : $($files.AppCertChain)"
Write-Host ''
Write-Host '⚠ 注意：OpenHarmony 测试 CA 不被零售 HarmonyOS NEXT 手机信任，此 HAP 大概率无法侧载。' -ForegroundColor Yellow
Write-Host '  正式真机请走 DevEco 自动签名（ENVIRONMENT.md Plan A）。' -ForegroundColor Yellow
Write-Host ''
exit 0
