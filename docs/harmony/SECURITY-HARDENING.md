# HarmonyOS 客户端安全加固说明（v2.1.0）

> **状态说明**：本文是 v2.1.0 阶段的安全加固记录，保留作历史参考。
> 当前代码已继续演进（v2.2.0：服务端更新检查、系统环境上报、AI 超分实际线路暂时屏蔽等），
> 与本文不一致处以后续 SPEC / 代码为准。

范围：`harmony/entry/src/main/ets` 下的网络层、业务接口、本地回环代理、媒体缓存、
播放列表改写、会话与线路、日志与外部输入处理。
原则：**能用系统/平台已验证的机制，就不自己写过滤策略**；改动保持上游协议与既有功能兼容。

## 1. 已实施的加固

### 1.1 统一的安全工具（新增）

`utils/Security.ets`：所有外部输入处理收敛到一处，页面/其他模块可直接复用。

| 能力 | 实现机制 |
| --- | --- |
| URL 判定（scheme/host） | `@ohos.url` 的 `url.URL.parseURL`，解析失败或非 http/https 一律拒绝；不手写协议前缀/正则 |
| 线路地址 | 同一解析器 + 仅 https、仅站点根、拒绝 IP 字面量/localhost |
| JSON 外部输入 | 标准 `JSON.parse` + 明确大小上限 + 异常兜底返回 null（不执行外部内容） |
| 会话 token / 本地代理 token | `@ohos.security.cryptoFramework` 的 CSPRNG（`createRandom().generateRandomSync`），失败时返回空串由调用方按失败处理（不退化弱随机） |
| 请求/响应头 | 头名按 RFC 7230 token 字符校验、头值去 CR/LF/NUL，防头注入 |
| 日志脱敏 | 查询串鉴权参数（auth_key/token/sign/...）与 Bearer 值打码（仅日志兜底，不承担鉴权） |

### 1.2 网络层 `services/Net.ets`

| 位置 | 问题 | 改法 / 采用的平台机制 |
| --- | --- | --- |
| Net.ets:95-101 | 原未声明 TLS 基线，容易被后续改动关校验 | 注释固化基线：使用 `@ohos.net.http` 系统默认证书校验，**不设置** caPath/remoteValidation/certificatePinning，也不关闭校验 |
| Net.ets:167-181 `request()` | 可传入任意 scheme（含明文 http） | 进入请求栈前用 `parseHttpsUrl` 校验，仅 https；并设 `maxLimit`（文本 4MB / 二进制 8MB） |
| Net.ets:196-206 | 响应体无上限 | `maxLimit` + 收到后再次校验长度，超限报“响应内容过大” |
| Net.ets:229-245 `getTextQuick()` | 同上（线路探测专用） | 同上（仅 https + maxLimit） |
| Net.ets:113-123 `errorText()` | 平台错误文本可能带 URL | 统一经 `redactSensitive` 后再给 UI/日志 |
| Net.ets:338-346 `edgeOnce()` | 信封 JSON 解析异常会外泄内部异常/原始内容 | `try/catch` 收敛为“响应解析失败”，不回显原始响应 |

说明：CDN 证书轮换会导致 pinning 不可行，因此**不做**证书 pinning（硬编码证书一旦轮换即全站不可用）。

### 1.3 业务接口 `services/Api.ets`

| 位置 | 问题 | 改法 |
| --- | --- | --- |
| Api.ets:583-598 `openUrl()` | 原用字符串前缀判断，开放重定向/伪协议（javascript:/file:/intent:）靠手写规则 | 改用 `parseWebUrl`（@ohos.url）：只放行 http/https 且 host 非空，用解析后的 `href` 打开；异常静默 |
| Api.ets:552-572 `checkUpdate()` | GitHub 响应直接 `JSON.parse`，无大小上限；`html_url` 外链未校验 | `parseBoundedJson`（1MB）+ 解析失败统一报错；`html_url` 经 `isSafeWebUrl` 校验后才放入 UpdateInfo |

### 1.4 本地回环代理 `player/LocalProxy.ets`（真实攻击面：127.0.0.1 对本机所有 App 可见）

| 位置 | 问题 | 改法 |
| --- | --- | --- |
| LocalProxy.ets:105-113, 216-221 | 无鉴权：本机任意 App 可把代理当 SSRF 跳板，并借注入的 CDN 鉴权头外带 | 每次 `start()` 用平台 CSPRNG 生成 16 字节会话 token；`/hls`、`/seg` 均要求 `?t=`，常量时间比较（LocalProxy.ets:750），无 token 一律 403 |
| LocalProxy.ets:128-137 / PlaylistRewrite.ets:495-513 | token 需随改写后的 m3u8 子请求传递 | 改写地址统一为 `<local>/seg?t=<token>&u=<percent-encoded>`；token 只在 query，不进 path、不写日志 |
| LocalProxy.ets:316-374 `dispatch()` | 上游 `?u=` 无 scheme/长度校验 | 长度 ≤8KB + `parseWebUrl` 仅 http/https；只允许 GET；未知路径 404，异常一律固定文案（不泄露内部路径/异常文本） |
| LocalProxy.ets:248-253 / 284-296 | 连接数、请求头无上限 | 同时连接 ≤32；请求头 ≤16KB（含已收全但超限的情况） |
| LocalProxy.ets:387-393 / 428-434 | 响应体无上限 | 播放列表 ≤2MB、分片 ≤8MB，超限 502 |
| LocalProxy.ets:536-538 `buildResponse()` | 上游 Content-Type 直接回写响应头，可 CRLF 注入 | `sanitizeResponseHeaderValue`：仅保留 ASCII 安全字符、截断长度 |
| MediaCache.ets:695-702 | CDN 鉴权头（服务端下发）直接放入上游请求头 | `sanitizeRequestHeaders`：非法头名丢弃、头值去 CRLF、数量/长度上限 |
| LocalProxy.ets:59-62（setUpstreamHeaders） | 同上 | 注入时即清洗（双重防线） |

保留：仅监听 127.0.0.1、端口由系统分配（port=0）、仅 GET、Connection: close、stop() 关闭监听与连接（原有正确实现未改）。

### 1.5 会话与线路

| 位置 | 问题 | 改法 |
| --- | --- | --- |
| Session.ets:22-33, 40-51 | preferences 里的 session JSON 无大小上限、origin/token 无校验 | 读取上限 64KB；origin 必须被系统 URL 解析器认定为 https；token 长度 1..4096；非法会话不加载 |
| Session.ets:68-75 `set()` | 异常会话信息会落盘 | 仅接受合法 https origin + 合理长度 token，否则抛错不落盘 |
| Lines.ets:188-225 `normalize()` | 手写协议前缀/host 字符/端口解析 | 改为 @ohos.url 解析，业务策略仅三项：仅 https、仅站点根（无 path/query/hash/账号信息）、拒绝 IP 字面量/localhost |

### 1.6 媒体缓存与列表改写

| 位置 | 问题 | 改法 |
| --- | --- | --- |
| MediaCache.ets:789-791 | 上游 URL 用手写前缀判断 | `parseWebUrl`（系统 URL 解析器）判定 scheme，超长/解析失败拒绝 |
| MediaCache.ets:703-716 | 上游 Content-Type 未清洗即进缓存/响应头 | `sanitizeResponseHeaderValue` |
| PlaylistRewrite.ets:495-513, 537-546 | 改写 URL 需携带会话 token，且防止 m3u8 内容注入 query/路径 | 统一 `proxySegmentUrl`：token 固定 hex 直拼，`?u=` 全部百分号编码（原有 encodeComponent 保持不变） |

磁盘缓存安全边界（核查结论）：缓存键经 `normalizeCacheKey` 去掉 auth_key/token 等易变参数，
磁盘文件名是键的 32 位散列 + 长度（`MediaCache.ets:458-468`），**不落盘 URL、不落盘 token**；
文件位于应用私有 `cacheDir/mediacache`，路径由散列生成，无路径穿越；单文件/总量/文件数均有上限。

## 2. 评估后未改（结论与原因）

| 点 | 结论 |
| --- | --- |
| `services/Crypto.ets` 纯 ArkTS AES-128-CBC | 当前实现是标准 AES（非自创加密），密钥是**上游协议固定常量**（公共混淆密钥，随客户端分发），不承担用户机密保护；迁移到 `cryptoFramework`（API 12+ 同步 `initSync/doFinalSync` + `IvParamsSpec` + `AES128_CBC` 默认 PKCS7 可保持同步签名）在技术上可行，但会改动 CoverCryptoWorker/TaskPool 链路，本次无法真机验证，且安全收益有限 → **建议后续单独迁移并做封面回归**。 |
| 密钥迁移 HUKS/asset | 封面密钥是协议常量，放 HUKS 不增加保密性；会话 token 目前存应用私有 preferences（非 root 设备其他应用不可读）。迁移 HUKS/asset 可行但改动大、需机型验证 → 本次只做长度/格式边界，**建议纳入后续迭代**（同时可加 token 过期与退出清理审计）。 |
| 证书 pinning | 不做：CDN 证书轮换导致不可维护，硬编码证书是反模式；系统默认校验由 @ohos.net.http 负责。 |
| MediaCache 32 位散列文件名的碰撞 | 碰撞只会导致“缓存的媒体内容区配错”，表现为播放异常而非越权；且 URL 由 TLS 保护的播放接口下发、本地代理还需会话 token → 接受，不做 SHA-256 迁移（磁盘路径同步 API 限制）。 |
| `Api.appVersion()` 仍为 `2.0.0`（发布版本 v2.1.0） | 非安全问题（更新检查版本比对），交由版本负责人统一处理，本次未改。 |
| `build-profile.json5` 内联签名口令 | 属构建配置（不在本次写作用域）；建议改用环境变量/本地未跟踪配置，避免仓库泄露签名材料。 |
| 页面外部输入（RecDataPage 剪贴板导入、PostContent 外链、VideoDetailPage 分享） | 属 pages/components（另一子代理负责）。已提供 `utils/Security.ets` 的 `parseBoundedJson` / `parseWebUrl` 供直接接入：导入前卡大小、解析失败兜底、外链只放行 http/https。 |
| `PlayerService.ets:527/533` 把 AVPlayer 原始错误文本直接进 PlaybackLog | 播放器服务不在本次写作用域；AVPlayer 错误文本可能包含媒体 URL（含 auth_key）。建议由播放器服务负责人套一层 `PlaybackLog.safeUrl`/脱敏或限制长度。**残余风险已记录**。 |

## 3. 静态自检

- 使用 DevEco 自带 TypeScript 编译器对改动文件做 `noEmit` 类型检查（SDK `@ohos.*` 类型 + kit 垫片），
  改动文件无类型错误（仅剩 `CoverCryptoWorker` 的 ArkTS `@Concurrent` 装饰器为 tsc 不识别的既有噪声）。
- `PlaylistRewrite.selfTestPlaylistRewrite()` 用 Node（type stripping）实际执行：全部用例通过
  （含新增的 token 改写用例：/seg?t=<token>&u=...，且 token 不出现在 path）。
- 未运行构建/安装/部署；未提交 git。
