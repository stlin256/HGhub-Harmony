<#
.SYNOPSIS
  构建 HarmonyOS HAP（debug/release），可签名也可仅做未签名编译验证。

.DESCRIPTION
  1. dot-source env.ps1 准备 NODE_HOME / JAVA_HOME / DEVECO_SDK_HOME / PATH
  2. （默认）在工程内执行 ohpm install
  3. 调用 hvigor assembleHap（或 -AssembleApp 打整包 .app）
  4. 打印产物路径，并区分三种结果：
     - 已签名 HAP：*-signed.hap
     - 未配置 signingConfig：产出 *-unsigned.hap，**算构建成功**（仅编译验证用，无法安装）
     - 配了 signingConfig 但签名失败：给出对应错误码指引（00303074 等）

  服务器参数（-ServerIp / -ServerPort / -ServerKey）在编译前由 set-server.mjs 生成
  harmony/entry/src/main/ets/services/ServerEndpoint.local.ets（不入库，XOR 混淆）。
  不传时若已有生成物则复用；既没传也没有生成物则直接报错（避免打出连不上服务器的包）。

.EXAMPLE
  .\scripts\harmony\build.ps1
  .\scripts\harmony\build.ps1 -Product default -BuildMode release
  .\scripts\harmony\build.ps1 -AssembleApp -Product store -BuildMode release
  .\scripts\harmony\build.ps1 -DevEcoHome 'C:\...\DevEcoStudio-26.0.0' -SkipOhpmInstall
  .\scripts\harmony\build.ps1 -ServerIp 1.2.3.4 -ServerPort 8443 -ServerKey <32位hex>
#>
param(
  [string]$DevEcoHome = '',
  [string]$ProjectPath = '',
  [string[]]$Product = @('default'),
  [ValidateSet('debug', 'release')][string]$BuildMode = 'debug',
  [switch]$AssembleApp,
  [switch]$SkipOhpmInstall,
  [switch]$UseDaemon,
  [string]$LogDir = '',
  [string]$ServerIp = '',
  [int]$ServerPort = 0,
  [string]$ServerKey = '',
  # 分发渠道（编译期标识，如 github / sydxky / official）；不入库，写入 BuildChannel.local.ets。
  [string]$Channel = ''
)

. (Join-Path $PSScriptRoot 'env.ps1') -DevEcoHome $DevEcoHome -Quiet
$toolchain = $HarmonyToolchain
$project = Get-HarmonyProjectPath -ProjectPath $ProjectPath
$repoRoot = $toolchain.RepoRoot
if (-not $LogDir) {
  $LogDir = Join-Path $PSScriptRoot '.local\logs'
}
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# 编译期注入分发渠道：每次构建写入 BuildChannel.local.ets（不入库）。
$channelOut = Join-Path $repoRoot 'harmony\entry\src\main\ets\utils\BuildChannel.local.ets'
if ($Channel) {
  if ($Channel -notmatch '^[a-z0-9][a-z0-9_-]{0,31}$') {
    throw "非法 -Channel：$Channel（只允许小写字母/数字/_/-，长度 1-32）"
  }
  $channelOutput = & $toolchain.NodeExe (Join-Path $PSScriptRoot 'set-channel.mjs') $Channel 2>&1
  Write-Host (($channelOutput | Out-String).Trim())
  if ($LASTEXITCODE -ne 0) {
    throw "生成分发渠道失败（exit=$LASTEXITCODE）"
  }
} elseif (-not (Test-Path -LiteralPath $channelOut -PathType Leaf)) {
  $channelOutput = & $toolchain.NodeExe (Join-Path $PSScriptRoot 'set-channel.mjs') 'official' 2>&1
  Write-Host (($channelOutput | Out-String).Trim())
}
$buildChannel = 'official'
if ($Channel) {
  $buildChannel = $Channel
} elseif (Test-Path -LiteralPath $channelOut) {
  $m = Select-String -LiteralPath $channelOut -Pattern "BUILD_CHANNEL: string = '([^']+)'"
  if ($m) {
    $buildChannel = $m.Matches[0].Groups[1].Value
  }
}

# 编译期注入服务器端点：IP / 端口 / 128 位接入密钥都不入库，由参数传入。
$serverOut = Join-Path $repoRoot 'harmony\entry\src\main\ets\services\ServerEndpoint.local.ets'
if ($ServerIp -or $ServerPort -gt 0 -or $ServerKey) {
  if (-not $ServerIp -or $ServerPort -le 0 -or -not $ServerKey) {
    throw '必须同时提供 -ServerIp、-ServerPort、-ServerKey（128 位密钥，32 位十六进制）'
  }
  Write-Host '[0/2] 生成编译期服务器端点（set-server.mjs）' -ForegroundColor Yellow
  $genOutput = & $toolchain.NodeExe (Join-Path $PSScriptRoot 'set-server.mjs') `
    --ip $ServerIp --port $ServerPort --key $ServerKey 2>&1
  $genExit = $LASTEXITCODE
  Write-Host (($genOutput | Out-String).Trim())
  if ($genExit -ne 0) {
    throw "生成 ServerEndpoint.local.ets 失败（exit=$genExit）"
  }
} elseif (-not (Test-Path -LiteralPath $serverOut -PathType Leaf)) {
  throw '缺少 ServerEndpoint.local.ets：请用 -ServerIp/-ServerPort/-ServerKey 传入服务器参数'
} else {
  Write-Host '[0/2] 复用已有 ServerEndpoint.local.ets（未传服务器参数）' -ForegroundColor DarkGray
}

$profilePath = Join-Path $project 'build-profile.json5'
$examplePath = Join-Path $project 'build-profile.example.json5'
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
  if (Test-Path -LiteralPath $examplePath -PathType Leaf) {
    Copy-Item -LiteralPath $examplePath -Destination $profilePath
    Write-Warning "build-profile.json5 不存在，已从 build-profile.example.json5 复制（无签名材料）。"
  } else {
    throw "缺少 build-profile.json5：$profilePath"
  }
}

# JSON5 不能直接 ConvertFrom-Json；用正则判断是否真的配置了签名材料（含 material 块）。
$profileText = [IO.File]::ReadAllText($profilePath)
$hasSigningMaterial = $profileText -match '"signingConfigs"\s*:\s*\[[\s\S]*?"material"\s*:\s*\{'
$bundleName = Get-HarmonyBundleName -ProjectPath $project
$daemonFlag = if ($UseDaemon) { @() } else { @('--no-daemon') }
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$results = [Collections.Generic.List[object]]::new()

Write-Host ''
Write-Host "HarmonyOS build: project=$project product=$($Product -join ',') mode=$BuildMode channel=$buildChannel bundle=$bundleName signingMaterial=$hasSigningMaterial" -ForegroundColor Cyan
Write-Host ('-' * 78)

# test 变体版本号：构建期间临时追加 .9999，构建结束无论成功失败都恢复原值。
$appJsonPath = Join-Path $repoRoot 'harmony\AppScope\app.json5'
$appJsonOriginal = $null
$testVersionName = ''
$variantFile = Join-Path $repoRoot 'harmony\entry\src\main\ets\utils\BuildVariant.ets'
$isTestVariant = (Test-Path -LiteralPath $variantFile) -and
  ((Get-Content -LiteralPath $variantFile -Raw) -match 'IS_TEST_VARIANT:\s*boolean\s*=\s*true')
if ($isTestVariant -and (Test-Path -LiteralPath $appJsonPath)) {
  $appJsonOriginal = [IO.File]::ReadAllText($appJsonPath)
  $patched = [regex]::Replace($appJsonOriginal, '("versionName"\s*:\s*")([^"]+)(")', {
    param($m)
    $base = $m.Groups[2].Value
    if ($base.EndsWith('.9999')) { return $m.Value }
    return $m.Groups[1].Value + $base + '.9999' + $m.Groups[3].Value
  })
  if ($patched -ne $appJsonOriginal) {
    [IO.File]::WriteAllText($appJsonPath, $patched, [Text.UTF8Encoding]::new($false))
    $testVersionName = (([regex]::Match($patched, '"versionName"\s*:\s*"([^"]+)"')).Groups[1].Value)
    Write-Host ('[test] 版本号临时设为 ' + $testVersionName + '（构建后恢复）') -ForegroundColor Yellow
  }
}

Push-Location -LiteralPath $project
$nativeErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
  if (-not $SkipOhpmInstall) {
    Write-Host '[1/2] ohpm install' -ForegroundColor Yellow
    $ohpmOutput = & $toolchain.OhpmBat install 2>&1
    $ohpmExit = $LASTEXITCODE
    $ohpmText = ($ohpmOutput | Out-String)
    Write-Host $ohpmText.Trim()
    if ($ohpmExit -ne 0) {
      throw "ohpm install 失败（exit=$ohpmExit）。检查网络/镜像或 oh-package.json5。"
    }
  } else {
    Write-Host '[1/2] ohpm install（-SkipOhpmInstall 已跳过）' -ForegroundColor DarkGray
  }

  foreach ($singleProduct in $Product) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile = Join-Path $LogDir ("build-{0}-{1}-{2}.log" -f $singleProduct, $BuildMode, $timestamp)
    $hvigorCliArgs = if ($AssembleApp) {
      @('-p', "product=$singleProduct", '-p', "buildMode=$BuildMode", 'assembleApp') + $daemonFlag
    } else {
      @('--mode', 'module', '-p', "product=$singleProduct", '-p', "module=entry@$singleProduct", '-p', "buildMode=$BuildMode", 'assembleHap') + $daemonFlag
    }

    Write-Host ("[2/2] hvigor {0}  (product={1}, mode={2})" -f $(if ($AssembleApp) { 'assembleApp' } else { 'assembleHap' }), $singleProduct, $BuildMode) -ForegroundColor Yellow
    Write-Host ('      node ' + $toolchain.HvigorJs + ' ' + ($hvigorCliArgs -join ' ')) -ForegroundColor DarkGray
    $buildOutput = & $toolchain.NodeExe $toolchain.HvigorJs @hvigorCliArgs 2>&1
    $buildExit = $LASTEXITCODE
    $buildText = ($buildOutput | Out-String)
    Set-Content -LiteralPath $logFile -Value $buildText -Encoding UTF8
    Write-Host $buildText.Trim()
    Write-Host "      log: $logFile" -ForegroundColor DarkGray

    if ($buildExit -ne 0) {
      if ($buildText -match '00303074' -or $buildText -match 'bundleName in the generated SigningConfigs') {
        throw @"
签名失败：app.json5 的 bundleName（$bundleName）与签名 profile 里的 bundle-name 不一致（hvigor 错误 00303074）。
现有 ~/.ohos/config 下的 profile 都绑定到别的应用（cloudcli / harnesspocket / dshharmony），不能复用到 $bundleName。
处理：打开 DevEco Studio → Project Structure → Signing Configs → 勾选 Automatically generate signature（需华为账号登录），
为新 bundleName 生成 cert/p12/p7b 后重跑本脚本。详见 docs/harmony/ENVIRONMENT.md 的「签名方案」。
"@
      }
      if ($buildText -match '00303116' -or $buildText -match 'length of the storePassword or keyPassword') {
        throw @"
签名失败：build-profile.json5 里的 storePassword / keyPassword 不是 DevEco 加密格式（长度 < 32）。
hvigor 只接受 DevEco 生成的加密口令，不能手写明文密码；请用 DevEco 自动签名生成配置，或用
scripts/harmony/local-sign.ps1（Plan B，仅实验）先产出 unsigned HAP 再手工 sign-app。
"@
      }
      if ($buildText -match 'Failed :.*SignHap') {
        throw "签名（SignHap）失败（exit=$buildExit）。日志：$logFile"
      }
      throw "hvigor 构建失败（exit=$buildExit）。日志：$logFile"
    }

    $outputDir = Join-Path $project ("entry\build\{0}\outputs\{1}" -f $singleProduct, $singleProduct)
    $signedHaps = @(Get-ChildItem -Path (Join-Path $outputDir '*-signed.hap') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    $unsignedHaps = @(Get-ChildItem -Path (Join-Path $outputDir '*-unsigned.hap') -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)

    if ($signedHaps.Count -gt 0) {
      Write-Host ("[OK] 已签名 HAP: " + $signedHaps[0].FullName + "  (" + $signedHaps[0].Length + " bytes)") -ForegroundColor Green
    } elseif ($hasSigningMaterial) {
      Write-Warning "构建成功但没有 *-signed.hap：签名配置可能未生效（检查 signingConfig 是否被 product 引用）。"
    } else {
      Write-Host '[OK] 构建成功（未配置 signingConfig）' -ForegroundColor Green
      Write-Host '     产物是 unsigned HAP，可用于编译/静态验证；安装到真机前必须完成签名（见 ENVIRONMENT.md Plan A）。' -ForegroundColor Yellow
    }
    foreach ($hap in $unsignedHaps) {
      Write-Host ("     unsigned: " + $hap.FullName) -ForegroundColor DarkGray
    }

    $results.Add([pscustomobject]@{
        Product      = $singleProduct
        BuildMode    = $BuildMode
        SignedHap    = $(if ($signedHaps.Count -gt 0) { $signedHaps[0].FullName } else { $null })
        UnsignedHap  = $(if ($unsignedHaps.Count -gt 0) { $unsignedHaps[0].FullName } else { $null })
        LogFile      = $logFile
        ExitCode     = $buildExit
        SigningReady = ($signedHaps.Count -gt 0)
      })
  }
} finally {
  $ErrorActionPreference = $nativeErrorAction
  Pop-Location
  if ($null -ne $appJsonOriginal) {
    [IO.File]::WriteAllText($appJsonPath, $appJsonOriginal, [Text.UTF8Encoding]::new($false))
    Write-Host '[test] 已恢复 app.json5 原始版本号' -ForegroundColor DarkGray
  }
  $stopwatch.Stop()
}

Write-Host ('-' * 78)
Write-Host ("BUILD FINISHED in {0:N1}s" -f $stopwatch.Elapsed.TotalSeconds) -ForegroundColor Cyan
return $results