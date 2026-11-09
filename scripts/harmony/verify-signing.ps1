<#
.SYNOPSIS
  校验 HAP 签名 / 解析 p7b profile / 汇总本机签名材料。

.DESCRIPTION
  使用 DevEco SDK 自带 hap-sign-tool.jar（配合 JBR java）做离线校验：
    -Target hap      校验 HAP 签名（verify-app），打印 bundleName、profile 类型、有效期、HAP SHA256
    -Target profile  解析单个 p7b profile（verify-profile），打印内容摘要
    -Target list     扫描 %USERPROFILE%\.ohos\config 下全部 p7b，列成表格并与当前工程 bundleName 对比
                     （只打印 device-ids 数量，不打印 UDID 明文）

.EXAMPLE
  .\scripts\harmony\verify-signing.ps1
  .\scripts\harmony\verify-signing.ps1 -Target list
  .\scripts\harmony\verify-signing.ps1 -Target hap -HapPath harmony\entry\build\default\outputs\default\entry-default-signed.hap
  .\scripts\harmony\verify-signing.ps1 -Target profile -ProfilePath "$env:USERPROFILE\.ohos\config\xxx.p7b" -Json
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet('hap', 'profile', 'list')]
  [string]$Target = 'hap',
  [string]$DevEcoHome = '',
  [string]$ProjectPath = '',
  [string]$HapPath = '',
  [string]$ProfilePath = '',
  [switch]$Json
)

. (Join-Path $PSScriptRoot 'env.ps1') -DevEcoHome $DevEcoHome -Quiet
$toolchain = $HarmonyToolchain
# 原生工具（java/hdc）会往 stderr 打 WARN，Windows PowerShell 5.1 在 Stop 模式下会当成异常；
# 本脚本以退出码为准，故统一用 Continue。
$ErrorActionPreference = 'Continue'

function Get-ProfileSummary {
  param([Parameter(Mandatory = $true)][string]$SignedProfilePath)

  $verifyJson = Join-Path ([IO.Path]::GetTempPath()) ('hghub-profile-' + [guid]::NewGuid().ToString('N') + '.json')
  try {
    & $toolchain.JavaExe -jar $toolchain.SignToolJar verify-profile -inFile $SignedProfilePath -outFile $verifyJson *> $null
    $verifyExit = $LASTEXITCODE
    if ($verifyExit -ne 0 -or -not (Test-Path -LiteralPath $verifyJson)) {
      return [pscustomobject]@{
        File = (Split-Path -Leaf $SignedProfilePath); Verified = $false; Error = "verify-profile exit=$verifyExit"
        Type = ''; BundleName = ''; ValidFrom = ''; ValidTo = ''; DeviceIdCount = 0; Issuer = ''; Distribution = ''
      }
    }
    $parsed = Get-Content -LiteralPath $verifyJson -Raw -Encoding UTF8 | ConvertFrom-Json
    $content = $parsed.content
    $validity = $content.validity
    $from = if ($validity.'not-before') { [DateTimeOffset]::FromUnixTimeSeconds([int64]$validity.'not-before').ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' }
    $to = if ($validity.'not-after') { [DateTimeOffset]::FromUnixTimeSeconds([int64]$validity.'not-after').ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { '' }
    $deviceIds = @()
    if ($content.'debug-info' -and $content.'debug-info'.'device-ids') { $deviceIds = @($content.'debug-info'.'device-ids') }
    return [pscustomobject]@{
      File          = (Split-Path -Leaf $SignedProfilePath)
      Verified      = $parsed.verifiedPassed -eq $true
      Error         = ''
      Type          = [string]$content.type
      BundleName    = [string]$content.'bundle-info'.'bundle-name'
      ValidFrom     = $from
      ValidTo       = $to
      DeviceIdCount = $deviceIds.Count
      Issuer        = [string]$content.issuer
      Distribution  = [string]$content.'app-distribution-type'
      ProfilePath   = $SignedProfilePath
    }
  } finally {
    Remove-Item -LiteralPath $verifyJson -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-VerifyApp {
  param([Parameter(Mandatory = $true)][string]$HapFile)

  $workDir = Join-Path ([IO.Path]::GetTempPath()) ('hghub-verify-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $workDir | Out-Null
  $chainPath = Join-Path $workDir 'chain.cer'
  $profilePath = Join-Path $workDir 'profile.p7b'
  try {
    $output = & $toolchain.JavaExe -jar $toolchain.SignToolJar verify-app -inFile $HapFile -outCertChain $chainPath -outProfile $profilePath 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String)
    $summary = $null
    if (Test-Path -LiteralPath $profilePath) {
      $summary = Get-ProfileSummary -SignedProfilePath $profilePath
    }
    $certSubject = ''
    if (Test-Path -LiteralPath $chainPath -PathType Leaf) {
      $certOutput = & $toolchain.KeytoolExe -printcert -file $chainPath 2>&1 | Out-String
      $match = [regex]::Match($certOutput, '(?m)^.*?CN=([^,\r\n]+).*?$')
      if ($match.Success) { $certSubject = $match.Groups[1].Value.Trim() }
    }
    return [pscustomobject]@{
      Hap        = $HapFile
      Verified   = ($exitCode -eq 0)
      ExitCode   = $exitCode
      Output     = $text
      ChainFile  = $chainPath
      Profile    = $summary
      Sha256     = (Get-FileHash -LiteralPath $HapFile -Algorithm SHA256).Hash
    }
  } finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

switch ($Target) {
  'hap' {
    $hapFile = $HapPath
    if (-not $hapFile) {
      $project = Get-HarmonyProjectPath -ProjectPath $ProjectPath
      $hap = Get-HarmonyHap -ProjectPath $project -IncludeUnsigned
      if (-not $hap) { throw '未找到 HAP 产物。先运行 build.ps1，或用 -HapPath 指定。' }
      $hapFile = $hap.FullName
    }
    $hapFile = (Resolve-Path -LiteralPath $hapFile -ErrorAction Stop).Path
    $result = Invoke-VerifyApp -HapFile $hapFile
    if ($Json) {
      $result | ConvertTo-Json -Depth 6
      break
    }
    Write-Host ''
    Write-Host "HAP: $($result.Hap)" -ForegroundColor Cyan
    Write-Host "SHA256: $($result.Sha256)"
    if ($result.Verified) {
      Write-Host '签名校验: PASS (verify-app success)' -ForegroundColor Green
    } else {
      Write-Host "签名校验: FAIL (exit=$($result.ExitCode))" -ForegroundColor Red
      Write-Host $result.Output
    }
    if ($result.Profile) {
      $p = $result.Profile
      Write-Host ("bundleName: {0}" -f $p.BundleName)
      Write-Host ("profile 类型: {0}   签发者: {1}   分发类型: {2}" -f $p.Type, $p.Issuer, $(if ($p.Distribution) { $p.Distribution } else { '-' }))
      Write-Host ("有效期: {0} ~ {1}" -f $p.ValidFrom, $p.ValidTo)
      Write-Host ("debug device-ids: {0} 个（不打印明文）" -f $p.DeviceIdCount)
    }
    Write-Host ''
    if (-not $result.Verified) { exit 1 }
  }
  'profile' {
    if (-not $ProfilePath) { throw '用法：verify-signing.ps1 -Target profile -ProfilePath <xxx.p7b>' }
    $ProfilePath = (Resolve-Path -LiteralPath $ProfilePath -ErrorAction Stop).Path
    $summary = Get-ProfileSummary -SignedProfilePath $ProfilePath
    if ($Json) {
      $summary | ConvertTo-Json -Depth 4
      break
    }
    Write-Host ''
    Write-Host "Profile: $($summary.File)" -ForegroundColor Cyan
    Write-Host ("校验: {0}" -f $(if ($summary.Verified) { 'PASS' } else { "FAIL ($($summary.Error))" }))
    Write-Host ("type={0} bundle-name={1} issuer={2} distribution={3}" -f $summary.Type, $summary.BundleName, $summary.Issuer, $(if ($summary.Distribution) { $summary.Distribution } else { '-' }))
    Write-Host ("有效期: {0} ~ {1}" -f $summary.ValidFrom, $summary.ValidTo)
    Write-Host ("debug device-ids: {0} 个（不打印明文）" -f $summary.DeviceIdCount)
    Write-Host ''
    if (-not $summary.Verified) { exit 1 }
  }
  'list' {
    $configDir = Join-Path $env:USERPROFILE '.ohos\config'
    $projectBundle = ''
    try {
      $project = Get-HarmonyProjectPath -ProjectPath $ProjectPath
      $projectBundle = Get-HarmonyBundleName -ProjectPath $project
    } catch { }

    $profiles = @()
    if (Test-Path -LiteralPath $configDir -PathType Container) {
      foreach ($p7b in Get-ChildItem -LiteralPath $configDir -Filter '*.p7b' -File | Sort-Object Name) {
        $profiles += Get-ProfileSummary -SignedProfilePath $p7b.FullName
      }
    }
    $rows = @($profiles | ForEach-Object {
        [pscustomobject]@{
          'Profile'          = $_.File
          'Type'             = $_.Type
          'BundleName'       = $_.BundleName
          'ValidTo'          = $_.ValidTo
          'DeviceIds'        = $_.DeviceIdCount
          'Verified'         = $_.Verified
          'MatchesProject'   = ($projectBundle -and $_.BundleName -eq $projectBundle)
        }
      })
    if ($Json) {
      [pscustomobject]@{ ProjectBundleName = $projectBundle; ConfigDir = $configDir; Profiles = $rows } | ConvertTo-Json -Depth 5
      break
    }
    Write-Host ''
    Write-Host "签名材料目录: $configDir" -ForegroundColor Cyan
    Write-Host ("当前工程 bundleName: " + $(if ($projectBundle) { $projectBundle } else { '(未找到 harmony/ 工程)' }))
    if ($rows.Count -eq 0) {
      Write-Host '未找到任何 p7b profile。' -ForegroundColor Yellow
    } else {
      $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
      $matching = @($rows | Where-Object { $_.MatchesProject })
      if ($projectBundle -and $matching.Count -eq 0) {
        Write-Host "结论: 没有 bundle-name=$projectBundle 的 profile —— 直接构建会报 00303074。" -ForegroundColor Yellow
        Write-Host '处理: DevEco Studio → Project Structure → Signing Configs → Automatically generate signature（需华为账号登录）。' -ForegroundColor Yellow
      } elseif ($matching.Count -gt 0) {
        Write-Host "结论: 找到 bundle-name=$projectBundle 的 profile，可用于签名（debug profile 还需设备 UDID 在 device-ids 白名单内）。" -ForegroundColor Green
      }
    }
    Write-Host ''
  }
}