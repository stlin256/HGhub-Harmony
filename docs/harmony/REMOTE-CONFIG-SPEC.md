# 远程下发能力 SPEC（配置 / 开关 / 灰度 / A-B / 资源 / 更新闸门 / 测试变体）

> 版本 v1.0 · 2026-11-13
> 状态：设计定稿，待实施
> 关联：[SPEC.md](SPEC.md)（总体规格）；开发流程约束见仓库根目录 `AGENTS.md`（本地文件，不入库）

---

## 1. 目标

用现有 Cloudflare Worker（`hghub-telemetry`）作为下发通道，为 App 建立六项能力：

| # | 能力 | 一句话 |
|---|---|---|
| C1 | **远程配置** | 服务端下发结构化配置，客户端合并到本地默认值 |
| C2 | **功能开关** | 每个功能一个 flag，可远程开/关（含 kill switch） |
| C3 | **灰度发布** | 按设备哈希分桶，功能/版本按比例放量 |
| C4 | **A/B 测试** | 同一功能多组参数，按桶分配，指标按桶对比 |
| C5 | **资源热更新** | 下发图片/文案等数据资源，校验哈希后本地缓存 |
| C6 | **强制更新闸门** | 低于最低版本强制提示；新版本按灰度比例提示 |

附加要求：

- **覆盖全部现有功能/配置/开关**：不允许有"代码里写死、下发不了"的开关（见 §4）。
- **流程硬约束**：`AGENTS.md` 规定新增任何可配置项必须同时接入下发（见 §9）。
- **测试变体**：编译期区分 `release` / `test`；`test` 变体摇一摇进调试配置菜单，可改一切下发项（见 §8）。
- **README 只简单提及**，不展开。

## 2. 非目标（明确不做）

| 不做 | 原因 |
|---|---|
| **代码热更新** | HarmonyOS 无合法动态加载路径：`eval`/`new Function` 被 ArkTS 禁用；`pluginBundleManager.installLocalPlugin` 需 `ohos.permission.kernel.SUPPORT_LOCAL_PLUGIN`（**system_basic**，且**仅 PC/2in1**）。详见 [§10](#10-平台约束说明) |
| 替换编译进包的资源 | `$r('app.media.*')` / `$r('app.string.*')` 在构建期固化，运行期不可替换 |
| 下发可执行脚本 / DSL 解释器 | 等于变相热更代码，且引入注入面 |
| 服务端下发用户隐私数据 | 下发通道只做"服务端 → 客户端"，不回传用户数据 |

## 3. 架构总览

```
                    ┌──────────────────────────────┐
                    │  Cloudflare Worker           │
                    │  hghub-telemetry             │
                    ├──────────────────────────────┤
                    │ GET /v1/config   → 配置包     │
                    │ GET /v1/update   → 更新闸门   │
                    │ GET /v1/assets/manifest       │
                    │ GET /v1/assets/<name>         │
                    │ (已有) /v1/report /v1/crash   │
                    │ (已有) /dashboard /api/stats  │
                    └──────────────┬───────────────┘
                                   │ HTTPS + HMAC 签名
                                   ▼
        ┌──────────────────────────────────────────────────┐
        │  App（HarmonyOS）                                 │
        │                                                  │
        │  RemoteConfig ──┐                                │
        │  Rollout      ──┼─→ ConfigRegistry（唯一事实源） │
        │  RemoteAssets ──┘         │                      │
        │                           ├→ UserPrefs（用户偏好）│
        │                           ├→ 功能开关            │
        │                           └→ 阈值常量            │
        └──────────────────────────────────────────────────┘
```

**关键设计**：`ConfigRegistry` 是**唯一事实源**。所有功能/开关/阈值都必须从这里读，不允许代码里直接写常量。

## 4. 配置模型（必须覆盖全部现有项）

### 4.1 三层优先级

```
编译期默认值（DEFAULT_CONFIG，写在代码里）
  ↑ 被覆盖
本地用户偏好（UserPrefs，用户手动设置）
  ↑ 被覆盖（仅当 flag 允许远程覆盖时）
远程配置（RemoteConfig，服务端下发）
```

**规则**：
- 用户显式设置过的项，远程**不覆盖**（避免"我关了又被打开"）
- 远程只能**收紧**不能**放宽**安全相关项（如遥测开关）
- 远程配置缺失/校验失败 → 回落本地默认值，功能不受影响

### 4.2 配置分组

| 组 | 内容 | 示例 |
|---|---|---|
| `flags` | 功能开关（布尔） | `super_resolution` / `pip` / `cast` / `topics` / `inplace_search` |
| `thresholds` | 数值阈值 | `retry_max` / `sr_battery_min` / `cache_days` |
| `rollout` | 灰度比例（0-100） | `inplace_search: 20` |
| `ab` | A/B 分组参数 | `search_page_size: {A:20, B:30}` |
| `copy` | 文案覆盖 | `home_empty_text` |
| `assets` | 资源清单 | `home_banner` |

### 4.3 必须纳管的现有项（Phase 2 逐项接入）

**用户偏好（已有）**：主题、启动静音、优先高清、多源加速、IPv6 优先、AI 超分、画面比例、音量、减少动态效果。

**功能开关（当前硬编码）**：AI 超分、多源聚合、IPv6 优先、画中画、投播、应用接续、服务卡片、专题、热搜、关注流、用户主页、剪贴板拉起、系统分享、评论、个性化推荐、崩溃上报、匿名统计。

**阈值常量（当前散落在代码里）**：

| 位置 | 常量 | 说明 |
|---|---|---|
| `PlayerQuality` | `RETRY_DELAYS_MS` / `MAX_ATTEMPTS` | 播放重试退避 |
| `PlayerSeekPolicy` | `END_RATIO` | 片尾判定比例 |
| `PowerGuard` | `BATTERY_MIN_SOC` | 超分电量阈值 |
| `PlayerService` | `CONN_INACTIVITY_MS` / `POOL_MAX` | 连接池 |
| `Net` | `API_RETRY_TIMES` / `DEFAULT_TIMEOUT` | 网络重试 |
| `LineAuto` | `PROBE_CACHE_TTL_MS` / 巡检间隔 / 失败阈值 | 线路自愈 |
| `MediaPrefetch` | 预取分片数 / 预取条数 | HLS 预加载 |
| `MediaCache` | 容量上限 | 媒体缓存 |
| `ImageCache` | 内存 LRU / 磁盘上限 | 封面缓存 |
| `Analytics` | `STARTUP_SAMPLES` / 上报节流 | 统计 |
| `DeviceMetrics` | `SAMPLE_INTERVAL_MS` | 设备指标采样 |
| `CrashGuard` | `MAX_RECORDS` | 崩溃记录 |
| `CrashReporter` | `BATCH` / `RETRY_INTERVAL_MS` | 崩溃上报 |
| `UpdateChecker` | `LAUNCH_DELAY_MS` | 更新检查延迟 |
| `HomePage` | 预取行数 / 分页大小 | 首页 |
| `SearchPage` / `CommentsSheet` | 分页大小 | 列表 |
| `RecService` | 探索比例 / 池大小 | 推荐 |

> Phase 2 会做一次**全量审计**，把上表补全到逐项清单，确保没有遗漏。

## 5. Worker 端点设计

### 5.1 `GET /v1/config`

```
GET /v1/config?ver=2.3.0&bucket=37&platform=harmonyos&cfg=11
```

| 参数 | 说明 |
|---|---|
| `ver` | 客户端版本 |
| `bucket` | 设备分桶（0-99，客户端用 `hash(install_id) % 100` 算好） |
| `platform` | 固定 `harmonyos` |
| `cfg` | 客户端当前配置版本（用于 304 短路） |

响应（200）：

```json
{
  "config_version": 12,
  "issued_at": 1731600000,
  "min_client_ver": "2.0.0",
  "flags": { "super_resolution": true, "inplace_search": false },
  "thresholds": { "retry_max": 4, "sr_battery_min": 20 },
  "rollout": { "inplace_search": 20 },
  "ab": { "search_page_size": { "A": 20, "B": 30 } },
  "copy": {},
  "assets": {},
  "sig": "<hex HMAC-SHA256>"
}
```

- `cfg` 与服务端当前版本相同 → **304 Not Modified**，省流量
- 响应体上限 16 KB
- `cache-control: public, max-age=300`

### 5.2 `GET /v1/update`

```
GET /v1/update?ver=2.2.0&bucket=37
```

响应：

```json
{
  "latest": "2.3.0",
  "min_version": "2.1.0",
  "rollout_pct": 20,
  "notes": "...",
  "url": "https://github.com/.../releases/tag/v2.3.0",
  "sig": "..."
}
```

客户端判定：

```
force  = current < min_version
soft   = current < latest && bucket < rollout_pct
提示   = force || soft
```

### 5.3 `GET /v1/assets/manifest` + `GET /v1/assets/<name>`

```json
{
  "version": 3,
  "assets": [
    { "name": "home_banner", "sha256": "…", "size": 12345, "url": "/v1/assets/home_banner" }
  ],
  "sig": "..."
}
```

- 单文件上限 512 KB，总量上限 4 MB
- 客户端校验 SHA-256 后才落盘
- 落盘目录：`filesDir/remote-assets/`

### 5.4 签名

- 所有下发响应带 `sig` = `HMAC-SHA256(body_without_sig, CONFIG_SIGNING_KEY)` 前 32 hex
- 客户端用内置公钥/密钥校验；校验失败**整包丢弃**
- `CONFIG_SIGNING_KEY` 通过 `wrangler secret put` 配置
- 客户端密钥编译进包（可被逆向，仅作防篡改门槛，非安全边界）

## 6. 灰度与 A/B

### 6.1 分桶

```ts
bucket = parseInt(sha256(install_id).slice(0, 8), 16) % 100
```

- 稳定：同一设备永远同一桶
- 均匀：SHA-256 保证分布
- 隐私：只用已有匿名 ID 的哈希，不上报原始 ID

### 6.2 灰度放量

`rollout: { "feature_x": 20 }` → `bucket < 20` 的设备开启该功能。

放量节奏建议：1% → 5% → 20% → 50% → 100%，每档观察 24h。

### 6.3 A/B

`ab: { "search_page_size": { "A": 20, "B": 30 } }` → 按 `bucket % 2` 分组。

上报时带 `ab_bucket`（0/1），面板按桶对比指标。

## 7. 资源热更新

### 7.1 可替换范围

| 可替换 | 不可替换 |
|---|---|
| 运行时 `Image(url)` 加载的图 | `$r('app.media.*')` |
| 服务端下发的文案（`copy`） | `$r('app.string.*')` 静态文案 |
| 推荐目录、字典（已有） | 代码逻辑 |

### 7.2 流程

```
启动 → 读本地 manifest 版本
     → 拉 /v1/assets/manifest（带 cfg 版本，304 短路）
     → 有更新 → 逐个下载 → 校验 SHA-256 → 落盘 → 更新本地 manifest
     → 校验失败 → 丢弃该文件，保留旧版本
```

### 7.3 降级

- 下载失败：用旧版本
- 无旧版本：用编译期默认资源
- 磁盘不足：跳过，下次再试

## 8. 测试变体与调试菜单

### 8.1 变体

| 变体 | 标识 | 调试菜单 | 用途 |
|---|---|---|---|
| `release` | `IS_TEST_VARIANT = false` | 不可达 | 正式发布 |
| `test` | `IS_TEST_VARIANT = true` | 摇一摇可达 | 下发联调 |

实现：`utils/BuildVariant.ets` 导出常量，`scripts/harmony/set-variant.mjs` 一键切换。

> 也可用 DevEco 的 `buildProfileFields` 做真正的编译期变体，见 §8.4。

### 8.2 摇一摇入口

- 监听 `@ohos.sensor` 加速度计（需 `ohos.permission.ACCELEROMETER`）
- 仅 `IS_TEST_VARIANT` 且当前在首页 Tab 时启用
- 判定：1.5s 内检测到 3 次加速度突变（阈值 18 m/s²）
- 触发 → `pushPathByName(ROUTE_DEBUG_CONFIG)`

### 8.3 调试配置菜单（`pages/DebugConfigPage.ets`）

分组展示**全部**可下发项，每项可编辑：

| 分组 | 可操作 |
|---|---|
| 当前配置 | 显示 `config_version` / 来源（远程/缓存/默认）/ 签名校验结果 |
| 功能开关 | 逐项 Switch，改动立即生效并持久化到本地覆盖 |
| 阈值 | 数值输入（带范围校验） |
| 灰度 | 手动指定 bucket（0-99），模拟不同灰度 |
| A/B | 手动指定 A/B 组 |
| 资源 | 显示已缓存资源、强制刷新、清空 |
| 更新闸门 | 模拟版本、模拟 min_version、触发更新弹窗 |
| 网络 | 强制走某条线路、清空配置缓存 |
| 导出 | 当前生效配置 JSON 复制到剪贴板 |

### 8.4 编译期变体（可选增强）

`harmony/build-profile.example.json5` 增加两个 product：

```json5
"products": [
  { "name": "default", "compatibleSdkVersion": "6.1.0(23)", "targetSdkVersion": "26.0.0",
    "buildOption": { "arkOptions": { "buildProfileFields": { "BUILD_VARIANT": "release" } } } },
  { "name": "test", "compatibleSdkVersion": "6.1.0(23)", "targetSdkVersion": "26.0.0",
    "buildOption": { "arkOptions": { "buildProfileFields": { "BUILD_VARIANT": "test" } } } }
]
```

代码优先读 `BuildProfile.BUILD_VARIANT`，读不到回落 `BuildVariant.IS_TEST_VARIANT`。

## 9. 开发流程硬性要求（AGENTS.md）

仓库根目录 `AGENTS.md`（本地文件，不入库）新增一节：

```markdown
## 远程下发约束（强制）

新增以下任意内容时，**必须同时**接入 `ConfigRegistry` 下发，否则 PR 不予合并：

1. 用户可见的功能（新页面/新入口/新交互）
2. 布尔开关
3. 数值阈值/上限/超时/重试次数/分页大小
4. 文案（可被远程覆盖的部分）
5. 图片资源（运行时加载的）

接入清单：
- [ ] 在 `ConfigRegistry` 注册（key + 默认值 + 类型 + 范围）
- [ ] 代码从 `ConfigRegistry` 读，不写死常量
- [ ] 在调试菜单可见可改
- [ ] 在 SPEC §4.3 表格登记
```

CI 增加检查：`scripts/check/config_coverage.py` —— 扫描新增的 `const XXX = <数字>` 常量，若未在 `ConfigRegistry` 注册则告警（白名单除外）。

## 10. 平台约束说明

**为什么不能热更代码**（调查结论）：

| 路径 | 结论 |
|---|---|
| `pluginBundleManager.installLocalPlugin`（API 26） | 需 `ohos.permission.kernel.SUPPORT_LOCAL_PLUGIN`，**system_basic**，**仅 PC/2in1** |
| `eval` / `new Function` | ArkTS 严格模式禁用 |
| 动态 `import()` 任意模块 | 只支持编译期已知模块 |
| 替换 HAP 内 `.abc` | 安装时签名校验，运行期不可替换 |

**结论**：代码不可热更；数据/配置/资源可以。

## 11. 安全与降级

| 风险 | 措施 |
|---|---|
| 配置被篡改 | HMAC 签名，校验失败整包丢弃 |
| MITM | 全 HTTPS + 系统证书校验 |
| 下发恶意内容 | 字段白名单 + 类型/范围校验，未知字段忽略 |
| 配置回滚攻击 | `config_version` 单调递增，只接受更高版本 |
| 配置过大 | 16 KB 上限，超限丢弃 |
| 拉取失败 | 本地缓存 → 编译期默认值，两级兜底 |
| 调试菜单泄漏到正式包 | `IS_TEST_VARIANT` 门禁 + 摇一摇仅在首页 Tab |
| 签名密钥泄漏 | 可轮换；密钥仅作防篡改门槛 |

## 12. 验收标准

| # | 标准 |
|---|---|
| A1 | 断网启动，全部功能按编译期默认值正常工作 |
| A2 | 远程关闭某功能后，重启 App 该功能入口消失 |
| A3 | 用户手动关闭的开关，远程不会重新打开 |
| A4 | 灰度 20% 时，bucket<20 的设备看到新功能，其余看不到 |
| A5 | A/B 两组参数不同，上报 `ab_bucket` 正确 |
| A6 | 资源下载后校验失败的文件被丢弃，回退旧版本 |
| A7 | 强制更新：低于 `min_version` 必弹窗；灰度内才提示新版本 |
| A8 | `test` 变体摇一摇可进调试菜单；`release` 变体摇不出来 |
| A9 | 调试菜单改的每一项都立即生效且持久化 |
| A10 | 签名校验失败时整包丢弃，不影响启动 |
| A11 | 全部现有开关/阈值都能在调试菜单里看到并修改 |
| A12 | CI 的 config 覆盖率检查通过 |

## 13. 实施分期

| 期 | 内容 | 产出 |
|---|---|---|
| P0 | SPEC + TODO + AGENTS.md | 文档 |
| P1 | Worker：`/v1/config` + 签名 + 单测 | 服务端 |
| P2 | 客户端：`ConfigRegistry` + `RemoteConfig` + `Rollout` | 客户端核心 |
| P3 | 全量接入：现有开关/阈值迁移到 `ConfigRegistry` | 客户端改造 |
| P4 | 更新闸门：`/v1/update` + `UpdateChecker` 改造 | 服务端 + 客户端 |
| P5 | 资源热更新：`/v1/assets` + `RemoteAssets` | 服务端 + 客户端 |
| P6 | 测试变体：`BuildVariant` + 摇一摇 + 调试菜单 | 客户端 |
| P7 | 面板：配置版本、灰度、A/B 展示 | Worker |
| P8 | CI：config 覆盖率检查 | 工程 |
| P9 | 文档：README 简单提及 + SPEC 收口 | 文档 |
