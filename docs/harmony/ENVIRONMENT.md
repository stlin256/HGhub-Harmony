# HarmonyOS CLI 开发环境、签名与真机调试

> 适用对象：HGhub 鸿蒙原生客户端（`harmony/` 工程，ArkTS/ArkUI，无 WebView）。
> 实测环境：Windows 11 本机、DevEco Studio 26.0.0（含 HarmonyOS SDK API 26）、无已连接真机。
> 本文命令均为本机实测；未能在本机验证的条目标注「未验证 / 需真机」。
> 配套脚本：[env.ps1](../../scripts/harmony/env.ps1)、[build.ps1](../../scripts/harmony/build.ps1)、
> [install.ps1](../../scripts/harmony/install.ps1)、[device.ps1](../../scripts/harmony/device.ps1)、
> [verify-signing.ps1](../../scripts/harmony/verify-signing.ps1)、[local-sign.ps1](../../scripts/harmony/local-sign.ps1)、
> [preflight.ps1](../../scripts/harmony/preflight.ps1)。

---

## 0. 快速开始（TL;DR）

```powershell
# 0) 真机就绪自检（工具链 / 构建产物 / 签名 profile / 设备连接，一条命令出矩阵）
.\scripts\harmony\preflight.ps1

# 1) 环境（设 NODE_HOME / JAVA_HOME / DEVECO_SDK_HOME / PATH）
. .\scripts\harmony\env.ps1

# 2) 构建（默认无 signingConfig 时产出 unsigned HAP，算构建成功）
.\scripts\harmony\build.ps1

# 3) 签名校验（签名 HAP 才有意义）
.\scripts\harmony\verify-signing.ps1 -Target hap

# 4) 装到真机并启动（需已插入真机 + 已生成签名配置）
.\scripts\harmony\install.ps1

# 5) 日志 / 截图 / 清数据
.\scripts\harmony\device.ps1 log -Tag HGHub -DurationSeconds 20
.\scripts\harmony\device.ps1 screenshot
.\scripts\harmony\device.ps1 clear-data
```

真机完整调试 Runbook、逐项验收清单与证据采集方式见 [DEVICE-DEBUG.md](DEVICE-DEBUG.md)。

**当前阻塞项（唯一必须用户介入）：** 本机 `~/.ohos/config` 里没有 `io.github.stlin256.hghub` 的签名 profile（`preflight.ps1` 会实时报告），
现有 profile 全部绑定到别的应用（详见 §4），直接配置签名会报 `00303074`。
需要用 DevEco Studio 登录华为账号点一次「自动签名」为 hghub 生成 debug 签名材料（§4.4），之后 CLI 全流程可长期复用。

---

## 1. 版本清单（本机实测）

| 组件 | 版本 / 路径 | 来源核对方式 |
| --- | --- | --- |
| DevEco Studio | **26.0.0.851**（build 261.23567.138.36.2600851） | `<DevEco>\product-info.json` |
| 安装目录 | `%LOCALAPPDATA%\Programs\Huawei\DevEcoStudio-26.0.0` | — |
| HarmonyOS SDK | **API 26 / HarmonyOS 26.0.0 / platformVersion 26.0.0 / 26.0.0.105（Release）** | `<DevEco>\sdk\default\sdk-pkg.json` |
| SDK 子包 | `ets` / `js` / `native` / `previewer` / `toolchains`（均 26.0.0.105）+ `hms` | 各目录 `oh-uni-package.json` |
| hvigor | **6.26.8**（@ohos/hvigor） | `<DevEco>\tools\hvigor\hvigor\package.json` |
| hvigor OHOS 插件 | **6.26.8**（@ohos/hvigor-ohos-plugin） | `<DevEco>\tools\hvigor\hvigor-ohos-plugin\package.json` |
| ohpm | **26.0.0.630** | `<DevEco>\tools\ohpm\package.json` / `ohpm -v` |
| Node.js | **v24.14.1**（自带 npm 11.11.0） | `<DevEco>\tools\node\node.exe --version` |
| JBR(JDK) | **OpenJDK 25.0.2**（JBR-25.0.2+1-329.117-nomod；`jbr\release` 中 JAVA_VERSION=25.0.2） | `<DevEco>\jbr\bin\java.exe -version` |
| hdc | **Ver: 3.2.0f**（client/server 同版本） | `<DevEco>\sdk\default\openharmony\toolchains\hdc.exe -v` |
| 签名工具 | `<DevEco>\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar` | `java -jar ... help` |
| ohpm registry | `https://ohpm.openharmony.cn/ohpm/` | `%USERPROFILE%\.ohpm\.ohpmrc` |
| 工程 SDK 配置 | `compatibleSdkVersion 6.1.0(23)` / `targetSdkVersion 26.0.0` / `runtimeOS HarmonyOS` | `harmony/build-profile.json5` |

> JBR 是 DevEco 自带 JDK，**必须用 JBR 里的 java** 执行 `hap-sign-tool.jar`（系统 java 版本可能不兼容）。
> `product-info.json` 还声明 `minRequiredJavaVersion: 21`。

---

## 2. 环境变量与初始化

### 2.1 推荐：dot-source env.ps1

```powershell
# 自动探测 DevEco Studio（依次尝试 -DevEcoHome、DEVECO_STUDIO_HOME/DEVECO_HOME、
# %LOCALAPPDATA%\Programs\Huawei\DevEcoStudio-*、Program Files）
. .\scripts\harmony\env.ps1

# 或显式指定安装目录
. .\scripts\harmony\env.ps1 -DevEcoHome "$env:LOCALAPPDATA\Programs\Huawei\DevEcoStudio-26.0.0"

# 打印环境摘要（直接执行、非 dot-source 时自动打印）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\harmony\env.ps1
```

dot-source 后可用：

- 环境变量：`$env:NODE_HOME`、`$env:JAVA_HOME`、`$env:DEVECO_SDK_HOME`、`$env:DEVECO_CLI_STUDIO_PATH`，PATH 已前置 node/JBR/hvigor/hdc（dot-source 后可直接用 `hdc`）。
- 对象：`$HarmonyToolchain`（DevEcoHome、NodeExe、JavaExe、KeytoolExe、HvigorJs、OhpmBat、HdcExe、SignToolJar、SdkDir、RepoRoot、HarmonyProject 等）。
- 函数：`Get-HarmonyToolchain`、`Get-HarmonyProjectPath`、`Get-HarmonyBundleName`、`Get-HarmonyHdcTargets`、`Select-HarmonyDevice`、`Get-HarmonyHap`、`Show-HarmonyVersionReport` 等。

### 2.2 手动等价（不依赖脚本）

```powershell
$ide = "$env:LOCALAPPDATA\Programs\Huawei\DevEcoStudio-26.0.0"
$env:NODE_HOME       = "$ide\tools\node"
$env:JAVA_HOME       = "$ide\jbr"
$env:DEVECO_SDK_HOME = "$ide\sdk"
$env:Path = "$env:NODE_HOME;$env:JAVA_HOME\bin;$env:Path"
```

- `NODE_HOME` 指向 DevEco 自带 node 目录（不是 system node）。
- `DEVECO_SDK_HOME` 指向 **SDK 根目录**（即包含 `default/` 的那一层，`<DevEco>\sdk`）。
- 不需要设置 `OHOS_HOME` / `HOS_SDK_HOME`。

### 2.3 校验

```powershell
& "$env:NODE_HOME\node.exe" --version                       # v24.14.1
& "$env:JAVA_HOME\bin\java.exe" -version                   # openjdk 25.0.2 (JBR)
& "$env:DEVECO_SDK_HOME\default\openharmony\toolchains\hdc.exe" -v   # Ver: 3.2.0f
```

---

## 3. 工程与构建

### 3.1 工程结构（`harmony/`）

```
harmony/
  AppScope/app.json5                     # bundleName=io.github.stlin256.hghub, versionCode/versionName, 图标
  AppScope/resources/...                 # 应用级资源
  build-profile.json5                    # 产物/签名配置（本机私有，已被 .gitignore 忽略）
  build-profile.example.json5            # 无签名材料模板
  hvigor/hvigor-config.json5             # hvigor 配置（modelVersion 6.0.0）
  hvigorfile.ts                          # appTasks
  oh-package.json5                       # 工程依赖
  entry/                                 # entry HAP 模块
    build-profile.json5                  # 模块配置（apiType=stageMode）
    hvigorfile.ts                        # hapTasks
    oh-package.json5
    src/main/module.json5                # ability、权限、页面入口
    src/main/ets/...                     # EntryAbility / pages / services ...
    src/main/resources/...               # 资源（main_pages.json 等）
```

构建产物目录（gitignored）：

```
harmony/entry/build/<product>/outputs/<product>/
  entry-<product>-signed.hap      # 配置了 signingConfig 且签名成功
  entry-<product>-unsigned.hap    # 未签名
  pack.info / mapping/ ...
```

### 3.2 构建命令（实测可用）

最底层调用（`build.ps1` 内部就是它）：

```powershell
Push-Location harmony
& "$env:NODE_HOME\node.exe" "`<DevEco>\tools\hvigor\bin\hvigorw.js`" --mode module `
  -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
Pop-Location
```

推荐用脚本（自动处理环境、ohpm install、日志、错误码指引）：

```powershell
.\scripts\harmony\build.ps1                                  # debug + default product
.\scripts\harmony\build.ps1 -Product default -BuildMode release
.\scripts\harmony\build.ps1 -AssembleApp -Product store -BuildMode release   # 打整包 .app（上架用）
.\scripts\harmony\build.ps1 -SkipOhpmInstall                 # 依赖未变时加速
```

实测记录（临时最小工程，`$env:TEMP\hghub-os-probe\project`，结构与 `harmony/` 同构）：
`ohpm install` 约 0.1s（无依赖）；`assembleHap` 首次 13.1s / 34 tasks；产物 `entry-default-signed.hap`；
`hap-sign-tool verify-app` 返回 success。HGhub `harmony/` 当前无 signingConfig，构建产出 `entry-default-unsigned.hap`（同样算成功）。

### 3.3 构建成功的三种语义（重要，build.ps1 会区分）

| 情况 | 现象 | 语义 |
| --- | --- | --- |
| 未配置 `signingConfigs` | 只有 `*-unsigned.hap` | **构建成功**（可用于编译/静态验证；无法安装真机） |
| 配置了签名且 bundle 匹配 | `*-signed.hap` 存在，`verify-app` success | 可安装（debug profile 还需设备 UDID 在白名单） |
| 配置了签名但 bundle 不匹配 | hvigor 报 `00303074`，构建失败 | 签名失败，需重新生成 profile（§4.4） |

`build.ps1` 会扫描日志：命中 `00303074` 时直接给出「bundleName 与 profile 不一致」处理指引；
命中 `00303116` 时提示口令必须是 DevEco 加密格式（§4.6）。

### 3.4 打包 `.app`（AppGallery 上传用）

```powershell
.\scripts\harmony\build.ps1 -AssembleApp -Product store -BuildMode release
# 产物：harmony/build/outputs/store/harmony-store-signed.app
```

上架不是本阶段目标，详见参考工程 `dsh-harmony/docs/RELEASE-PACKAGING.md`（含权限 7014 校验、签名验证、发布证书说明）。

---

## 4. 签名（本阶段重点）

### 4.1 HarmonyOS 签名是怎么工作的

一个签名的 HAP 里包含两部分：

1. **应用签名块**：HAP 内容摘要 + 应用证书链（三级：根 CA → 中间 CA → 开发者应用证书），用应用私钥签名。
2. **Profile（`.p7b`，Provision Profile）**：由华为 AGC 签发的授权清单，内含
   `bundle-name`、`type`（`debug` / `release`）、`device-ids`（debug 的设备 UDID 白名单）、
   `permissions/acls`、`validity`、`app-distribution-type` 等。profile 有自己的签名链（Profile 证书）。

设备安装时同时校验：HAP 签名链可信 + profile 签名可信 + **profile 的 bundle-name 与 HAP 一致** +
debug profile 的 device-ids 包含本机 UDID + 权限不超集。因此「证书/私钥」与「profile」必须成对，且 profile 绑定应用身份。

### 4.2 本机现有签名材料（实测解析）

目录：`%USERPROFILE%\.ohos\config\`（DevEco 自动签名/发布签名历史产物，**已 gitignore，不要提交**）。

用 `verify-signing.ps1 -Target list` 可随时重新列出（不会打印 UDID 明文）：

```powershell
.\scripts\harmony\verify-signing.ps1 -Target list
```

实测结果（2026-11-09）：

| profile | type | bundle-name | 有效期（本地时间） | device-ids | 备注 |
| --- | --- | --- | --- | --- | --- |
| `default_harmony_XCIyD….p7b` | debug | io.github.stlin256.**dshharmony** | 2026-10-28 ~ 2027-10-28 | 1 条（用户现有手机，已脱敏） | 1 年有效 |
| `store_harmony_XCIyD….p7b` | debug | io.github.stlin256.**dshharmony** | 2026-10-31 ~ 2027-10-31 | 1 条（同机） | 与上一份同 bundle |
| `dsh-harmony-release.p7b` | release | io.github.stlin256.**dshharmony** | 2026-10-31 ~ 2029-10-31 | 0 | distribution=app_gallery，只能上架 |
| `default_harmony_cxG9….p7b` | debug | io.github.stlin256.**harnesspocket** | 2026-10-25 ~ 2027-10-25 | 1 条（同机） | |
| `default_harmony_kB9g….p7b` | debug | io.github.stlin256.**cloudcli** | 2026-10-27 ~ 2027-10-27 | 1 条（同机） | |
| `cloudcli-harmony-push.p7b` | debug | io.github.stlin256.**cloudcli** | 2026-10-27 ~ **2026-11-01** | 1 条（同机） | 已过期；Push 场景专门 profile |

全部 profile 的 `issuer=app_gallery`（AGC 签发），签名链为
`Huawei CBG Root CA G2`（2020-07-09 ~ 2030-07-07）→ `Huawei CBG Developer Relations CA G2` → 开发者证书（约 1 年有效期）。
配套的 `*.cer / *.p12 / *.csr` 同名成对；`material/` 子目录保存 DevEco 的口令加密材料。

### 4.3 结论：现有材料**不能**复用到 hghub

实测证据（不是推测）：

1. 所有 p7b 的 `bundle-name` 都**不是** `io.github.stlin256.hghub`（见上表）。
2. hvigor 在 `SignHap` 阶段强制校验 app.json5 的 bundleName 与 signingConfig 中 profile 的 bundle-name：
   不一致直接构建失败，报 `00303074 Configuration Error: The bundleName in app.json5/hvigorfile.ts does not match the bundleName in the generated SigningConfigs`。
3. 反过来把工程 bundleName 临时改成 `io.github.stlin256.dshharmony` 可以签名成功（已在临时工程验证），
   但那是另一个应用身份，不能用于 HGhub。
4. debug profile 的 device-ids 只包含**那一台手机的 UDID**（已脱敏）；换设备需要重签 profile。
5. **没有纯 CLI 的绕过方式**：debug profile 必须由 AGC 签发（设备信任链只认华为 CA）；
   本地自签 profile 只能在 OpenHarmony/实验环境用（§4.5）。

**因此：要装到用户这台真机，必须先为 `io.github.stlin256.hghub` 生成一份 AGC 签发的 debug 签名材料。**

### 4.4 Plan A（推荐，唯一真机可用路径，需用户介入一次）

#### 4.4.1 在 DevEco Studio 里点一次「自动签名」

前置：手机已插入 USB 并开启开发者模式/USB 调试（可被 DevEco 识别），或账号下已有该设备；
需要能访问华为开发者网络；需要登录华为开发者账号。

1. 打开 DevEco Studio 26.0.0。
2. `File > Open` 打开 `%USERPROFILE%\Documents\projects\HGhub-Harmony\harmony`（注意：打开 `harmony` 子目录，不是仓库根）。
3. 确认 `AppScope/app.json5` 的 `bundleName` 为 `io.github.stlin256.hghub`。
4. 登录：IDE 右上角/欢迎页登录华为账号（若本机 DevEco 仍有登录态则自动复用；不确定时按提示登录）。
5. `File > Project Structure > Project > Signing Configs` → 勾选 **Automatically generate signature**
   （多 product 时对 `default` 勾选）→ `Apply/OK`。
   - DevEco 会按 bundleName 自动创建/登记 AGC 应用、登记当前设备 UDID，
     并在 `~/.ohos/config` 生成新的 `.cer/.p12/.p7b`，同时把 `signingConfigs`（含 DevEco 加密口令）写入 `harmony/build-profile.json5`。
6. 如果自动签名提示应用不存在/无权限：到 AppGallery Connect（AGC）→ 我的应用 → 新建应用（包名 `io.github.stlin256.hghub`）后重试；
   或在 DevEco 中改用「手动签名」并指向 AGC 下载的材料（手动签名也必须在 DevEco UI 里保存，因为口令必须是 DevEco 加密格式，见 §4.6）。

#### 4.4.2 签名材料就绪后的 CLI 流程（无需再开 IDE）

```powershell
.\scripts\harmony\verify-signing.ps1 -Target list     # 应看到 bundle-name=io.github.stlin256.hghub 的 profile
.\scripts\harmony\build.ps1                            # 产出 entry-default-signed.hap
.\scripts\harmony\verify-signing.ps1 -Target hap       # verify-app success
.\scripts\harmony\install.ps1                          # hdc install -r + aa start
```

`build-profile.json5` 被 `.gitignore` 忽略，请勿提交（内含本机加密口令与证书路径）。

#### 4.4.3 需要用户/AGC 介入的点

| 环节 | 是否必须介入 | 说明 |
| --- | --- | --- |
| 华为账号登录 | **必须**（一次） | 自动签名/AGC 签发 profile 都要求登录；本机凭据可能仍在（未验证） |
| 真机 UDID 登记 | **必须**（一次，自动） | 自动签名会把当前连接设备的 UDID 写入 debug profile；换手机需重做 |
| AGC 新建应用 | 视账号状态 | 自动签名通常自动创建；失败则手工创建包名 |
| 发布上架证书/profile | 本阶段不需要 | release 证书只能走 AppGallery，不能侧载（参考文档记录 9568322） |

### 4.5 Plan B（实验/模拟器路径）：本地离线自签（已实测跑通）

用途：在**没有华为账号**的场景验证「证书链 → profile → 签名 → verify」全链路；
或给 OpenHarmony 设备/部分模拟器做实验安装。**零售 HarmonyOS NEXT 手机大概率无法安装**（见限制）。

一条命令（需要设备 UDID 或已连接设备，脚本不会打印 UDID）：

```powershell
# 先用 build.ps1 得到 unsigned HAP
.\scripts\harmony\build.ps1
# 本地自签（材料写到 scripts/harmony/.local/local-sign/，已 gitignore）
.\scripts\harmony\local-sign.ps1 -DeviceUdid <设备的64位UDID>
```

脚本内部等价命令（比对/排错用，已实测全部成功）：

```powershell
$ide = "$env:LOCALAPPDATA\Programs\Huawei\DevEcoStudio-26.0.0"
$java = "$ide\jbr\bin\java.exe"
$tool = "$ide\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar"
$lib  = "$ide\sdk\default\openharmony\toolchains\lib"

# 1) 从 SDK 自带 OpenHarmony 公共测试 keystore 导出根/中间 CA（公开测试口令 123456）
& "$ide\jbr\bin\keytool.exe" -exportcert -rfc -alias "openharmony application root ca" -keystore "$lib\OpenHarmony.p12" -storetype PKCS12 -storepass 123456 -file root-ca.cer
& "$ide\jbr\bin\keytool.exe" -exportcert -rfc -alias "openharmony application ca"      -keystore "$lib\OpenHarmony.p12" -storetype PKCS12 -storepass 123456 -file sub-ca.cer

# 2) 生成应用密钥/CSR
& $java -jar $tool generate-keypair -keyAlias hghub-local-debug-key -keyPwd 123456 -keyAlg ECC -keySize NIST-P-256 -keystoreFile app-keypair.p12 -keystorePwd 123456
& $java -jar $tool generate-csr -keyAlias hghub-local-debug-key -keyPwd 123456 -subject "C=CN,O=HGhub,OU=HGhub Local,CN=HGhub Local Debug" -signAlg SHA256withECDSA -keystoreFile app-keypair.p12 -keystorePwd 123456 -outFile hghub.csr

# 3) 用 OpenHarmony 测试 CA 签发三级证书链
& $java -jar $tool generate-app-cert -keyAlias hghub-local-debug-key -keyPwd 123456 `
  -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" `
  -issuerKeyAlias "openharmony application ca" -issuerKeyPwd 123456 `
  -subject "C=CN,O=HGhub,OU=HGhub Local,CN=HGhub Local Debug" -validity 365 -signAlg SHA256withECDSA `
  -rootCaCertFile root-ca.cer -subCaCertFile sub-ca.cer -outForm certChain `
  -keystoreFile app-keypair.p12 -keystorePwd 123456 `
  -issuerKeystoreFile "$lib\OpenHarmony.p12" -issuerKeystorePwd 123456 -outFile app-debug-cert.cer

# 4) 生成本地 debug profile JSON：从模板 $lib\UnsgnedDebugProfileTemplate.json 派生，
#    development-certificate = 上面证书链的叶子证书，debug-info.device-ids = [设备 UDID]，
#    其余字段见 §4.7；local-sign.ps1 已自动完成这一步（含 LF 换行处理）。
#    （手工做法：改模板字段后用 UTF-8 无 BOM 写 local-debug-profile.json）
#    模板：$lib\UnsgnedDebugProfileTemplate.json；注意 PEM 用 LF 换行（见 §4.6）
# 5) 签 profile（OpenHarmony profile 调试证书）
& $java -jar $tool sign-profile -mode localSign -keyAlias "openharmony application profile debug" -keyPwd 123456 `
  -profileCertFile "$lib\OpenHarmonyProfileDebug.pem" -inFile local-debug-profile.json -signAlg SHA256withECDSA `
  -keystoreFile "$lib\OpenHarmony.p12" -keystorePwd 123456 -outFile local-debug-profile.p7b

# 6) 签 HAP
& $java -jar $tool sign-app -mode localSign -keyAlias hghub-local-debug-key -keyPwd 123456 `
  -appCertFile app-debug-cert.cer -profileFile local-debug-profile.p7b `
  -inFile entry-default-unsigned.hap -signAlg SHA256withECDSA `
  -keystoreFile app-keypair.p12 -keystorePwd 123456 -outFile entry-local-signed.hap -compatibleVersion 23

# 7) 校验
& $java -jar $tool verify-app -inFile entry-local-signed.hap -outCertChain chain.cer -outProfile profile.p7b
```

实测结果：`generate-keypair/CSR/app-cert/sign-profile/sign-app/verify-app` 全部 success；
本地生成 HAP 的 `verify-signing.ps1 -Target hap` 输出 `签名校验: PASS`，bundleName=`io.github.stlin256.hghub`，
profile type=debug、有效期 1 年、device-ids 1 条。
HAP sha256 示例：`2A46BEB56936ABDE25894F09FAE0AC26B3D87205B3D4E521DC53CB5B7FAF287D`。

**限制与不确定性（务必知悉）：**

- 根证书是 OpenHarmony 公共测试 CA，**不在 HarmonyOS NEXT 零售手机的信任链里**；侧载预计失败
  （参考工程文档记录发布证书侧载报 `9568322`「签名不受信任」，本地自签同理，**未在本机真机验证**）。
- 只在 OpenHarmony 标准设备、部分模拟器、或纯离线验证签名链路时有意义。
- 生成的 `.p12/.cer/.p7b/.hap` 全部落在 `scripts/harmony/.local/local-sign/`（已 gitignore），
  **含私钥，禁止提交/禁止用于发布**；测试口令是 OpenHarmony 公共测试口令 `123456`，不是秘密，但也仅限本地实验。

### 4.6 两个实测到的签名硬约束（容易踩坑）

1. **hvigor 只接受 DevEco 加密后的口令**：`build-profile.json5` 里 `storePassword/keyPassword` 若写明文，
   构建直接报 `00303116 Configuration Error: The length of the storePassword or keyPassword field in the signature configuration is less than 32`。
   解决：用 DevEco 自动/手动签名保存配置（生成加密口令），或走 Plan B 的 `hap-sign-tool sign-app`（脚本内传明文，不落盘到仓库）。
2. **本地 profile JSON 里的 PEM 必须用 LF 换行**：`development-certificate` 字符串若带 CRLF（Windows 默认），
   `sign-app` 会报 `11010001 Unknown error / Illegal base64 character`。`local-sign.ps1` 已内置转换。
3. hvigor 校验 bundleName 与 profile 的 `bundle-name`（`00303074`），不能靠改 build-profile 的 product 名称绕过。

### 4.7 profile 关键字段速查

| 字段 | 含义 | 本机示例 |
| --- | --- | --- |
| `bundle-info.bundle-name` | 绑定应用包名，必须与 app.json5 一致 | `io.github.stlin256.hghub`（待生成） |
| `type` | `debug`（可侧载、有设备白名单）/`release`（仅上架） | debug |
| `debug-info.device-ids` + `device-id-type: udid` | debug 安装的设备白名单 | 1 条（已脱敏） |
| `validity.not-before/not-after` | Unix 秒；debug 通常 1 年，release 3 年 | — |
| `app-distribution-type` | release profile 为 `app_gallery` | — |
| `issuer` | `app_gallery`（AGC）/`pki_internal`（本地实验） | — |
| `acls.allowed-acls` | 受限权限 ACL 授权（如 FIDO2） | 视应用 |

---

## 5. 真机调试流程

> 当前状态：`hdc list targets` = `[Empty]`（没有连接手机）。
> 注意 `hdc list targets -v` 会把主板串口列成 `COM3/COM4  UART  Ready` —— 那不是手机，脚本已默认过滤 UART。

### 5.1 真机准备（用户操作）

1. 手机：设置 → 关于手机 → 连续点击「版本号」开启**开发者模式**。
2. 设置 → 系统 → **开发者选项** → 打开「**USB 调试**」（HarmonyOS NEXT 还需打开「USB 调试（安全设置）」相关项，按系统提示）。
3. USB 连接电脑（建议原装数据线、直连主板 USB 口），手机弹窗选择「传输文件/允许调试」并允许本机指纹。
4. 验证：

```powershell
.\scripts\harmony\device.ps1 list
# 或：& "<DevEco>\sdk\default\openharmony\toolchains\hdc.exe" list targets -v
```

期望出现形如 `<serial>  USB  Ready  ...` 的行。

### 5.2 安装 / 启动 / 停止 / 卸载 / 清数据

```powershell
# 安装（-r 覆盖安装，保留数据）+ 启动 + 打印 pid
.\scripts\harmony\install.ps1
.\scripts\harmony\install.ps1 -ClearData        # 安装后先清数据再启动
.\scripts\harmony\install.ps1 -NoLaunch         # 只装不启动
.\scripts\harmony\install.ps1 -DryRun           # 只打印命令

# 等价的原始 hdc 命令（<dev> 为序列号，<hap> 为 HAP 路径）
hdc -t <dev> install -r <hap>
hdc -t <dev> shell "aa start -a EntryAbility -b io.github.stlin256.hghub -m entry"
hdc -t <dev> shell "aa force-stop io.github.stlin256.hghub"
hdc -t <dev> uninstall io.github.stlin256.hghub
hdc -t <dev> shell "bm clean -n io.github.stlin256.hghub -d"   # 清数据
hdc -t <dev> shell "bm clean -n io.github.stlin256.hghub -c"   # 清缓存
hdc -t <dev> shell "pidof io.github.stlin256.hghub"            # 查看进程
```

`hdc` 命令在 dot-source `env.ps1` 后可直接使用；否则用完整路径 `<DevEco>\sdk\default\openharmony\toolchains\hdc.exe`。`aa start` 支持传 Want 参数：`--ps key value`（参考工程的截图脚本用它注入 showcase 参数）。

### 5.3 日志（hilog）

```powershell
# 抓 20 秒，客户端按 tag 过滤
.\scripts\harmony\device.ps1 log -Tag HGHub -DurationSeconds 20
# 持续抓取（Ctrl+C 结束），写入文件
.\scripts\harmony\device.ps1 log -Follow -OutFile .\scripts\harmony\.local\logs\hilog.txt

# 原始命令
hdc -t <dev> hilog                                  # 流式输出设备日志
hdc -t <dev> shell "hilog -h"                        # 查看设备端 hilog 参数（版本差异大）
```

应用侧建议用 `@kit.PerformanceAnalysisKit` 的 `hilog`，按 domain/tag 打印，便于过滤（ArkTS 侧见开发指南）。

### 5.4 截图

```powershell
.\scripts\harmony\device.ps1 screenshot
# 默认保存到 scripts/harmony/.local/screenshots/<时间戳>.jpeg（已 gitignore），-OutDir 可改

# 原始命令（脚本优先用第一种，失败回退第二种）
hdc -t <dev> shell "uitest screenCap -p /data/local/tmp/shot.jpeg"
hdc -t <dev> file recv /data/local/tmp/shot.jpeg .\shot.jpeg
hdc -t <dev> shell "snapshot_display -f /data/local/tmp/shot.jpeg"
```

### 5.5 UI 自动化（uitest，参考工程真机验证过的命令）

```powershell
hdc -t <dev> shell "uitest dumpLayout -p /data/local/tmp/layout.json -i -b io.github.stlin256.hghub"
hdc -t <dev> file recv /data/local/tmp/layout.json .\layout.json      # 控件树（含坐标）
hdc -t <dev> shell "uitest uiInput click 540 1200"
hdc -t <dev> shell "uitest uiInput swipe 1100 1500 180 1500 600"
hdc -t <dev> shell "uitest uiInput inputText 540 1200 hello"
hdc -t <dev> shell "uitest uiInput keyEvent Back"
```

这些命令来自已真机验证的参考工程 `dsh-harmony/scripts/device-ui-*.ps1`（**本机因无设备未复测**）。

### 5.6 文件 / 端口 / 无线调试

```powershell
hdc file send .\x.txt /data/local/tmp/x.txt
hdc file recv /data/local/tmp/x.txt .\x.txt
hdc -t <dev> fport tcp:9222 tcp:9222          # 端口转发（如 ArkWeb 调试；本项目禁用 WebView）
hdc -t <dev> rport tcp:8080 tcp:8080

# 无线调试（手机与电脑同网段）
hdc tconn 192.168.x.x:10178                   # 手机“无线调试”里显示的 IP:端口
hdc tconn 192.168.x.x:10178 -remove           # 断开
# 或用 USB 先切 TCP 监听：hdc -t <dev> tmode port 10178
```

### 5.7 设备观测

```powershell
.\scripts\harmony\device.ps1 info            # 型号 / API / 设备类型（param get）
.\scripts\harmony\device.ps1 udid            # UDID（敏感，勿提交）

hdc -t <dev> shell "aa dump -a"                # 当前 Ability/Mission 状态
hdc -t <dev> shell "bm dump -n io.github.stlin256.hghub"  # 包信息
hdc bugreport .\bugreport.zip                 # 全量设备信息（体积大）
```

CPU/内存观测：设备端 `top` / `hidumper` 的参数随版本差异较大（未验证），
建议优先用 DevEco Profiler 或 `hdc shell hidumper -h` 现场确认。

### 5.8 模拟器现状（本机不可用）

- DevEco 自带模拟器程序存在：`<DevEco>\tools\emulator\Emulator.exe`。
- 但**没有下载系统镜像**：`%LOCALAPPDATA%\Huawei\Sdk` 为空；
  `%LOCALAPPDATA%\Huawei\Emulator26.0\.emu_config` 中两项协议均为 `disagree`。
- 因此**当前无法用 CLI/脚本启动模拟器**；需要用户打开 DevEco Studio → Device Manager → 同意协议 → 下载系统镜像（GB 级，需账号/网络）→ 创建并启动模拟器。
- 模拟器启动后 `hdc list targets` 一般会出现 TCP/本机目标，可用同一套脚本安装调试（未验证）。
- 结论：本阶段以**真机**为验收环境。

---

## 6. 脚本清单

| 脚本 | 作用 | 关键参数 / 示例 |
| --- | --- | --- |
| [env.ps1](../../scripts/harmony/env.ps1) | 探测 DevEco、设置环境变量、导出共享函数与 `$HarmonyToolchain` | dot-source 使用；直接执行打印版本摘要 |
| [build.ps1](../../scripts/harmony/build.ps1) | ohpm install + hvigor assembleHap/assembleApp；区分未签名成功与签名失败 | `-Product default` `-BuildMode debug/release` `-AssembleApp` `-SkipOhpmInstall` `-DevEcoHome` |
| [install.ps1](../../scripts/harmony/install.ps1) | 找最新签名 HAP → hdc install -r → aa start | `-Device` `-HapPath` `-DryRun` `-ClearData` `-NoLaunch` |
| [device.ps1](../../scripts/harmony/device.ps1) | list/start/stop/log/screenshot/clear-data/uninstall/info/udid | `-Tag` `-DurationSeconds` `-Follow` `-Json` `-DryRun` |
| [verify-signing.ps1](../../scripts/harmony/verify-signing.ps1) | verify-app 校验 + 签名摘要；verify-profile；列出本机 profile 并与工程 bundle 对比 | `-Target hap/profile/list` `-Json` `-HapPath` `-ProfilePath` |
| [local-sign.ps1](../../scripts/harmony/local-sign.ps1) | Plan B 本地离线自签（实验） | `-DeviceUdid` `-HapPath` `-Force` |

共同约定：

- 脚本文件为 **UTF-8 with BOM + CRLF**（Windows PowerShell 5.1 兼容；BOM 缺失会导致中文解析失败）。
- 统一用 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 调用。
- 失败用非 0 退出码；`-DryRun` 只打印命令不碰设备。
- 日志/截图/本地签名材料默认写 `scripts/harmony/.local/`（`.gitignore` 已覆盖）。
- 绝不硬编码 UDID；需要时通过 `device.ps1 udid` 或 hdc 动态读取。

---

## 7. 故障排查表

| 现象 / 错误 | 原因 | 处理 |
| --- | --- | --- |
| `Cannot find build config file build-profile.json5 at 'entry'` | 缺 `harmony/entry/build-profile.json5` | 补文件（模板：`{"apiType":"stageMode","buildOption":{},"targets":[{"name":"default"}]}`）；本机实测踩过 |
| `00303074` bundleName 与 SigningConfigs 不一致 | 当前 bundle 没有对应 profile（本机现状） | §4.4 Plan A 生成 hghub 的 debug 签名；`verify-signing.ps1 -Target list` 确认 |
| `00303116` storePassword/keyPassword 长度 < 32 | build-profile.json5 里写了明文口令 | 用 DevEco 保存签名配置；或 Plan B 手工 sign-app |
| `11010001 Illegal base64 character`（sign-app） | 本地 profile JSON 的 PEM 用了 CRLF | 用 LF（`local-sign.ps1` 已处理） |
| `ArkTS:ERROR 10903329 Unknown resource name 'x'` | `$r('app.media.x')` 资源不存在/未编译进资源表 | 补 `resources/base/media/x.png` 等，或改引用 |
| `ArkTS:ERROR ... Function may throw exceptions` | 警告（非错误） | 可不处理，或按 ArkTS 规范 try/catch |
| `hvigor ... 00304056 Not Found` | `-p module=entry@<product>` 的 product/module 名与工程不匹配 | 对照 build-profile.json5 的 product/target 名 |
| `ohpm install` 失败（网络/证书） | registry 不可达或代理 | 检查 `https://ohpm.openharmony.cn/ohpm/`；本工程当前无三方依赖，可 `-SkipOhpmInstall` |
| `hdc list targets` 为 `[Empty]` | 未连接/未授权/线缆/驱动；或只有 UART 误报 | 换线换口；手机重新授权；`hdc kill -r` 重启服务；用 `device.ps1 list` 看原始输出 |
| 安装报 `9568322` / signature not trusted | release 证书或本地自签侧载到零售机 | 用 AGC debug 签名（Plan A）；release 包只能上架 |
| 安装报 device not in profile / udid 不匹配 | debug profile 白名单不含本机 UDID | DevEco 自动签名（连接本机）或 AGC 添加设备后重签 profile |
| `aa start` 失败 | bundle/ability/module 名写错、未安装、被停止 | 用 `bm dump -n <bundle>` 确认包；`aa dump -a` 看状态 |
| 截图命令失败 | 设备不支持 `uitest screenCap` | 脚本自动回退 `snapshot_display -f`；再不行用 DevEco 截图 |
| DevEco 启动/构建报 SDK 缺失 | `DEVECO_SDK_HOME` 未设或错误 | 用 `env.ps1`；确认 `<DevEco>\sdk\default\sdk-pkg.json` 存在 |
| 脚本中文乱码/解析错误 | .ps1 被存成无 BOM UTF-8 | 保持 UTF-8 BOM + CRLF；不要用记事本另存 ANSI |
| 构建成功但无 signed HAP | 没有 signingConfig 或 product 未引用 signingConfig | 检查 build-profile.json5 的 product.signingConfig |

---

## 8. 待用户介入项（按优先级）

1. **【必须，一次】生成 hghub 的 debug 签名材料**：DevEco Studio 登录华为账号 → 打开 `harmony/` →
   Project Structure → Signing Configs → Automatically generate signature（需手机连接/账号有设备记录）。
   影响：没有这一步，构建只能得到 unsigned HAP，无法安装到真机；而且现有其它应用的 profile 不可复用（§4.3）。
2. **【必须】插入真机并开启开发者模式 + USB 调试**，首次连接在手机上允许调试授权。
   影响：没有设备时 `install.ps1`/`device.ps1` 只能 dry-run；截图/日志/UI 自动化全部依赖真机。
3. **【可能需要】AGC 手工建应用**：若自动签名提示应用不存在或账号权限不足，到 AGC 用包名
   `io.github.stlin256.hghub` 新建应用后重试（或改用手动签名，材料从 AGC 下载）。
4. **【可选】模拟器**：DevEco Device Manager 同意协议并下载系统镜像（需登录、网络、数 GB 磁盘）。本机当前没有镜像。
5. **【发布阶段才需要】** AppGallery 上架用的 release 证书/发布 profile、隐私政策、应用图标/截图等；本阶段不做。
6. **【安全】不要提交** `build-profile.json5`、`~/.ohos/config` 下的证书/私钥/profile、任何 UDID 明文；
   仓库 `.gitignore` 已覆盖 `*.p7b/*.cer/*.csr/*.p12/*.pem`、`scripts/harmony/.local/`、`harmony/build-profile.json5`。

---

## 9. 本机实测记录（2026-11-09）

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| 版本探测 | `env.ps1` 直接执行 | DevEco 26.0.0.851 / API 26 / hvigor 6.26.8 / ohpm 26.0.0.630 / node v24.14.1 / JBR 25.0.2 / hdc 3.2.0f |
| 临时最小工程构建 | `ohpm install` + `hvigorw ... assembleHap` | BUILD SUCCESSFUL 13.1s / 34 tasks；产出 signed + unsigned HAP |
| 签名校验（DevEco 调试材料） | `hap-sign-tool verify-app` | success；证书链 Huawei CBG Root CA G2 → Developer Relations CA G2 → 开发者证书 |
| bundle/profile 不匹配 | 同上工程改 bundleName=hghub | hvigor 报 `00303074`（预期）；证明不能复用 dshharmony profile |
| 明文口令 | build-profile 写 `123456` | hvigor 报 `00303116`（预期）；证明必须 DevEco 加密口令 |
| 本地离线自签 | `local-sign.ps1` 全链 | generate-keypair/CSR/app-cert/sign-profile/sign-app/verify-app 全部 success；`verify-signing.ps1` PASS |
| 工程构建（HGhub） | `build.ps1`（无 signingConfig） | 构建流程跑通；产物 unsigned（符合 §3.3 语义） |
| 脚本 dry-run | `install.ps1 -DryRun`、`device.ps1 list/log/screenshot/udid -DryRun` | 全部正常，不依赖设备 |
| 设备探测 | `hdc list targets -v` | `[Empty]`；仅 COM3/COM4 UART 误报 |
| 模拟器 | 检查 `%LOCALAPPDATA%\Huawei\Sdk`、`.emu_config` | 无镜像、协议未同意 → 不可用 |

---

## 10. 安全与隐私

- **私钥/口令**：`~/.ohos/config/*.p12` 与 DevEco 加密口令只在本机使用；`harmony/build-profile.json5` 已被 gitignore。
- **UDID**：属设备唯一标识，本仓库是公开 fork —— 不要写进文档、脚本、提交信息；脚本一律从 `hdc` 动态读取。
- **profile/证书**：`*.p7b/*.cer/*.csr` 已在 `.gitignore`；profile 内含 UDID 与 bundle 绑定信息，不要外传。
- **本地实验材料**：`scripts/harmony/.local/` 全部 gitignore（`local-sign.ps1` 生成物在此）。
- **不要**把 `~/.ohos/config/material/`（DevEco 口令加密材料）复制进仓库或共享。

---

## 11. 参考资料

- 本机参考工程（只读，已真机验证）：`%USERPROFILE%\Documents\projects\dsh-harmony`
  - `scripts/build-harmony.ps1`：hvigor 调用方式、环境变量、变体替换
  - `scripts/resolve-deveco-home.ps1`：DevEco 安装目录探测（本项目 env.ps1 参考其思路）
  - `scripts/device-ui-*.ps1`：hdc 安装/启动/截图/uitest/log 自动化
  - `docs/RELEASE-PACKAGING.md`：发布打包与签名验证、7014/9568322 说明
  - `docs/DEPLOYMENT.md`：构建部署与 devecocli 说明（本机 DevEco 26 未提供 devecocli，改用 hvigor 直调）
- hap-sign-tool 帮助：`& "<DevEco>\jbr\bin\java.exe" -jar "<DevEco>\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar"`
- 签名材料模板：`<DevEco>\sdk\default\openharmony\toolchains\lib\{UnsgnedDebugProfileTemplate.json, OpenHarmonyProfileDebug.pem, OpenHarmony.p12}`
