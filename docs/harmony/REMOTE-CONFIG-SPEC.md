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
| C7 | **远程通知** | 服务端下发通知，可设频率/呈现模式/内容/窗口按钮 |
| C8 | **设置页远程化** | 远程控制设置页任何文本、新增/隐藏选项、新增二级界面 |
| C9 | **UI 下发** | 颜色/尺寸/入口显隐/排序等 UI 参数可远程覆盖 |
| C10 | **配置应用回报** | 每个设置项收到下发策略后回报：生效时间/前值/新值/配置版本 |
| C11 | **配置唯一 ID** | 每次配置更新与下发都有全局唯一 `config_id` |

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

### 4.4 全量审计结果（158 个数值常量）

已扫描 `harmony/entry/src/main/ets/**`，共 **158 个 `const` 数值常量**，分三类：

| 类别 | 数量 | 处置 |
|---|---:|---|
| **业务可调**（应接入下发） | ~62 | 注册到 `ConfigRegistry` |
| **安全/协议常量**（保持硬编码） | ~34 | 标注 `@config-exempt` |
| **UI 尺寸/动效常量**（保持硬编码） | ~62 | 标注 `@config-exempt` |

#### 业务可调清单（按模块）

| 模块 | 常量 | 建议 key |
|---|---|---|
| `PlayerQuality` | `RETRY_DELAYS_MS` / `MAX_ATTEMPTS` | `retry_delay_1/2/3_ms` / `retry_max` |
| `PlayerSeekPolicy` | `END_RATIO` | `seek_end_ratio` |
| `PowerGuard` | `BATTERY_MIN_SOC` | `sr_battery_min` |
| `PlayerService` | `CONN_INACTIVITY_MS` / `POOL_MAX` / `PLAY_CACHE_TTL_MS` / `NEAR_END_MS` / `HISTORY_INTERVAL_MS` | `conn_inactivity_ms` / `conn_pool_max` / `play_cache_ttl_ms` / `near_end_ms` / `history_interval_ms` |
| `Net` | `API_RETRY_TIMES` / `DEFAULT_TIMEOUT` | `api_retry_times` / `net_timeout_ms` |
| `LineAuto` | `PROBE_TIMEOUT_MS` / `PROBE_BATCH` / `CANDIDATE_LIMIT` / `INIT_DELAY_MS` / `WATCH_INTERVAL_MS` / `WATCH_FAIL_THRESHOLD` / `PROBE_CACHE_TTL_MS` / `MANUAL_COOLDOWN_MS` | `line_probe_timeout_ms` / `line_probe_batch` / `line_candidate_limit` / `line_init_delay_ms` / `line_watch_interval_ms` / `line_fail_threshold` / `line_probe_ttl_ms` / `line_manual_cooldown_ms` |
| `Lines` | `MIRROR_MAX` / `MIRROR_CACHE_MAX` / `PROBE_TIMEOUT` / `PAGE_TIMEOUT` | `line_mirror_max` / `line_mirror_cache_max` / `line_probe_timeout` / `line_page_timeout` |
| `MediaCache` | `MEMORY_MAX_BYTES` / `MEMORY_MAX_ENTRIES` / `DISK_MAX_BYTES` / `DISK_MAX_FILES` / `*_TTL_MS` / `FETCH_MAX_CONCURRENCY` | `media_cache_mem_mb` / `media_cache_mem_entries` / `media_cache_disk_mb` / `media_cache_disk_files` / `media_cache_ttl_*` / `media_fetch_concurrency` |
| `MediaPrefetch` | `URL_TTL_MS` / `DONE_TTL_MS` / `STAGGER_*` / `SLOW_FETCH_MS` | `prefetch_url_ttl_ms` / `prefetch_done_ttl_ms` / `prefetch_stagger_*` / `prefetch_slow_ms` |
| `ImageCache` | `DEFAULT_DECODE_W/H` / `DISK_MAX_FILES` | `cover_decode_w` / `cover_decode_h` / `cover_cache_files` |
| `Analytics` | `REPORT_INTERVAL_MS` / `STARTUP_SAMPLES` | `analytics_interval_ms` / `startup_sample_max` |
| `DeviceMetrics` | `SAMPLE_INTERVAL_MS` | `device_sample_interval_ms` |
| `CrashGuard` | `MAX_RECORDS` / `MAX_FRAMES` / `MAX_STACK_LEN` | `crash_max_records` / `crash_max_frames` / `crash_max_stack_len` |
| `CrashReporter` | `BATCH` / `RETRY_INTERVAL_MS` | `crash_batch` / `crash_retry_interval_ms` |
| `UpdateChecker` | `LAUNCH_DELAY_MS` | `update_delay_ms` |
| `ClipboardLink` | `CHECK_INTERVAL_MS` | `clipboard_check_interval_ms` |
| `Ipv6Preference` | `CACHE_TTL_MS` | `ipv6_cache_ttl_ms` |
| `Api` | `DETAIL_TTL_MS` / `DETAIL_MAX_ENTRIES` / `WARM_HISTORY_CONCURRENCY` / `LINE_RETRY_COOLDOWN_MS` | `detail_cache_ttl_ms` / `detail_cache_entries` / `warm_history_concurrency` / `line_retry_cooldown_ms` |
| `CategoryCatalog` | `CACHE_TTL_MS` | `catalog_cache_ttl_ms` |
| `ScreenPrefetch` | `WARM_DELAY_MS` / `RANK_TTL_MS` / `LIST_TTL_MS` | `screen_warm_delay_ms` / `rank_cache_ttl_ms` / `list_cache_ttl_ms` |
| `UserListPrefetch` | `WARM_DELAY_MS` / `WARM_MAX_IDS` / `WARM_CONCURRENCY` | `userlist_warm_delay_ms` / `userlist_max_ids` / `userlist_concurrency` |
| `UserPrefs` | `HISTORY_MAX` / `SEARCH_HIST_MAX` | `history_max` / `search_hist_max` |
| `HomePage` | `PAGE_SIZE` / `HERO_COUNT` / `HERO_AUTO_PLAY_MS` / `LOAD_MORE_AHEAD` / `PREFETCH_PER_PAGE` / `POOL_MAX` / `POOL_INIT_PAGES` / `PREFETCH_AHEAD_ROWS` | `home_page_size` / `home_hero_count` / `home_hero_autoplay_ms` / `home_load_ahead` / `home_prefetch_per_page` / `home_pool_max` / `home_pool_init_pages` / `home_prefetch_rows` |
| 各列表页 | `PAGE_SIZE`（Channel/Follow/Posts/Profile/Search/Topic/Topics/User/Comments） | `page_size_*` |
| `SearchPage` | `HOT_RANK_SIZE` | `hot_rank_size` |
| `VideoDetailPage` | `PREVIEW_COUNT` | `episode_preview_count` |
| `CategoryPage` | `PREVIEW_SIZE` | `category_preview_size` |
| `PlayerPage` | `CHROME_HIDE_MS` / `LONG_PRESS_MS` / `SEEK_*` / `PIP_HINT_MS` | `chrome_hide_ms` / `long_press_ms` / `seek_*` / `pip_hint_ms` |
| `HgPosterFlow` | `PREFETCH_*` | `flow_prefetch_*` |
| `RecService` | 探索比例 / 池大小 | `recommend_explore_pct` / `recommend_pool_size` |

#### 迁移状态（P3 已完成，2026-11-13）

| 批次 | 提交 | 覆盖 |
|---|---|---|
| P3-A | `6ec5476` | services 层 8 key + 3 开关检查（UserPrefs / Ipv6 / Analytics / CrashReporter / CrashGuard / DeviceMetrics / UpdateChecker / ClipboardLink / PowerGuard） |
| P3-B | `3c13f81` | 播放器与网络层 15 key（PlayerQuality / PlayerSeekPolicy / PlayerService / MediaCache / MediaPrefetch / Net / LineAuto） |
| P3-C | `f27db95` | UI 层功能入口 3 项（专题 / 关注 / 画中画 + 投播） |
| P3-C 第二批 | `0fd746c` | UI 功能开关 5 项（分享 / 评论 / 推荐 / 热搜 / 用户主页）+ 分页 4 key（comment_page_size / search_page_size / home_prefetch_rows / recommend_explore_pct） |
| P3-D | 本提交 | 覆盖率收口：新增 10 个阈值 key（analytics_interval_ms / clipboard_check_interval_ms / remote_assets_delay_ms / remote_config_delay_ms / long_press_ms / seek_full_width_seconds / pip_hint_ms / catalog_inject_delay_ms / catalog_inject_count / load_more_threshold）；23 个 UI/动效/内部调度/安全常量标注 `@config-exempt`；`config_coverage.py --strict` 已启用 |

**未迁移项**：剩余常量标注了 `// @config-exempt: 原因`，分三类：
1. 语义/默认值不匹配（如 `Ipv6Preference.CACHE_TTL_MS` 是 5min，`line_probe_ttl_ms` 是 60s；`HomePage.POOL_MAX` 是 120，`recommend_pool_size` 默认 200）
2. 协议/安全/平台常量（`MAX_*` / `*_TIMEOUT_MS` / 模型结构 / 卡片规格）
3. UI 尺寸/动效/内部调度常量（解码尺寸、手势窗口、动画闸门、滚动合并延迟等）

`config_coverage.py --strict` 已接入 CI：新增数值常量必须注册进 `ConfigRegistry`（默认值对齐）或标注 `@config-exempt` 说明原因，否则 CI 失败。

#### 保持硬编码（标注 `@config-exempt`）

| 模块 | 常量 | 原因 |
|---|---|---|
| `Security` | `MAX_HEADER_*` / `MAX_EXTERNAL_URL_LEN` / `MAX_RESPONSE_HEADER_LEN` | 安全上限，放宽有风险 |
| `Session` | `SESSION_MAX_*` | 同上 |
| `Net` | `RESPONSE_MAX_TEXT_BYTES` / `RESPONSE_MAX_BINARY_BYTES` / `CONN_TUNING_MIN_API` | 协议/平台常量 |
| `LocalProxy` | `MAX_HEADER_BYTES` / `MAX_PLAYLIST_BYTES` / `MAX_MEDIA_BYTES` / `MAX_CONNECTIONS` | 同上 |
| `RecModel` | `BUCKETS` / `ITEM_EXTRA` / `TEXT_DIM` / `BATCH` / `CATES` | 模型结构，改了模型就废了 |
| `EntryFormAbility` | `THUMB_W/H` / `COVER_JPEG_QUALITY` | 卡片规格 |
| `WatchCoverCache` | `THUMB_W/H` / `JPEG_QUALITY` | 同上 |
| UI 尺寸 | `COMMENT_PANEL_W` / `REC_STEP_DOT` / `HERO_DECODE_W` 等 | 设计 token，走 `HgTokens` 而非下发 |
| 动效 | `HgMotion.*` | 已有独立标准，不做远程下发 |

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
### 9.1 远程下发约束（强制）

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

## 12. 远程通知（C7）

### 12.1 数据结构

```json
"notices": [
  {
    "id": "notice_20261113_1",
    "title": "新版本已发布",
    "body": "v2.3.0 修复了播放失败问题。",
    "mode": "dialog",
    "frequency": "once",
    "priority": 10,
    "start_at": 1731600000,
    "end_at": 1732200000,
    "target": { "min_ver": "2.2.0", "max_ver": "2.3.9", "platform": "harmonyos" },
    "window": {
      "closable": true,
      "close_label": "知道了",
      "buttons": [
        { "type": "copy", "label": "复制链接", "value": "https://..." },
        { "type": "link", "label": "打开", "url": "https://..." }
      ]
    }
  }
]
```

### 12.2 字段约束

| 字段 | 取值 | 默认 |
|---|---|---|
| `mode` | `dialog` / `banner` / `fullscreen` / `toast` | `dialog` |
| `frequency` | `once` / `once_per_day` / `once_per_week` / `every_launch` | `once` |
| `priority` | 0-100，越大越优先 | `0` |
| `start_at` / `end_at` | epoch 秒，`0` 表示不限 | `0` |
| `window.closable` | 是否显示关闭按钮 | `true` |
| `window.buttons[].type` | `copy` / `link` / `dismiss` | — |

### 12.3 展示规则

1. 过滤：时间窗内 + 版本匹配 + 平台匹配
2. 频率检查：查本地 `notice_shown_<id>` 记录
3. 排序：`priority` 降序，同优先级按 `id` 字典序
4. 每次冷启动最多展示 **1 条**（避免轰炸）
5. 展示后写本地记录（`id` → 时间戳）
6. 无 `notices` 或不匹配 → **默认不展示任何东西**

### 12.4 安全

- `body` 纯文本，**不渲染 HTML/Markdown**（防注入）
- `url` 必须 https 且通过 `isSafeWebUrl` 校验
- 单条通知上限 2 KB，总数上限 20 条
- 未知 `mode`/`frequency` 回落默认值

---

## 13. 设置页远程化（C8）

### 13.1 目标

远程可以：
1. 改任何 section / item 的**标题、副标题**
2. **隐藏/显示**任何 section / item
3. **调整顺序**
4. **新增** item（switch / link / text / slider）
5. **新增二级界面**（声明式描述，不含代码）

### 13.2 Schema

```json
"settings": {
  "sections": [
    {
      "id": "play",
      "title": "播放",
      "visible": true,
      "order": 1,
      "items": [
        { "id": "prefer_hevc", "visible": true, "order": 1,
          "title": "优先高清（HEVC）", "subtitle": "有高清源时优先播放" },
        { "id": "custom_1", "type": "switch", "key": "flag_experimental",
          "title": "实验功能", "subtitle": "可能不稳定", "order": 99 }
      ]
    }
  ],
  "pages": [
    {
      "id": "page_about_plus",
      "title": "更多信息",
      "blocks": [
        { "type": "text", "content": "这是一段远程下发的说明。" },
        { "type": "link", "title": "项目主页", "url": "https://github.com/..." },
        { "type": "divider" }
      ]
    }
  ]
}
```

### 13.3 渲染规则

- **默认 schema 编译进包**（`SettingsSchema.default()`），远程只做增量覆盖
- 未在远程出现的 section/item → 用默认值
- 远程新增的 item → 追加到指定 section
- 远程新增的 page → 注册为 `ROUTE_DYNAMIC_PAGE`，参数为 `page_id`
- `blocks` 只支持 4 种：`text` / `link` / `divider` / `image`（**无代码执行**）

### 13.4 安全

- 远程只能**新增** item，不能删除编译期 item（只能 `visible: false`）
- 新增 item 的 `key` 必须是 `ConfigRegistry` 已注册的 key，否则忽略
- `blocks` 类型白名单，未知类型忽略
- 单页 blocks 上限 50，文本上限 2 KB

---

## 14. UI 下发（C9）

### 14.1 可覆盖范围

| 类别 | 示例 | 约束 |
|---|---|---|
| 颜色 | `accent` / `surface1` / `textPrimary` | 必须是合法 hex |
| 尺寸 | `pageInset` / `radiusGroup` | 范围 0-64 |
| 入口显隐 | `home.hero` / `category.topics` / `profile.follow` | 布尔 |
| 入口排序 | `tab.order` | 数组，元素为已知 tab id |
| 文案 | `home.empty_text` | 纯文本，≤200 字 |

### 14.2 实现

- `HgColor` / `HgSpace` 等 token 从 `ConfigRegistry` 读（带默认值）
- 入口显隐用 `ConfigRegistry.getBool('entry_xxx')`
- 文案用 `ConfigRegistry.getString('copy_xxx')`

### 14.3 约束

- **不做布局结构下发**（不能改组件树），只做参数覆盖
- 颜色/尺寸改动立即生效（下次渲染），不需要重启
- 无下发时行为与现在**完全一致**

---

## 15. 配置应用回报（C10）

### 15.1 目标

每个设置项收到下发策略后，回报：
- 生效时间
- 前值 / 新值
- 配置版本号 + `config_id`
- 来源（remote / local_override / default）

### 15.2 上报结构

随 `/v1/report` 的日聚合一起上报：

```json
"config_apply": [
  {
    "config_id": "01JABCDEF...",
    "config_version": 13,
    "key": "super_resolution",
    "old": "true",
    "new": "false",
    "source": "remote",
    "applied_at": 1731600123
  }
]
```

### 15.3 服务端存储

```sql
CREATE TABLE IF NOT EXISTS config_applies (
  config_id      TEXT NOT NULL,
  config_version INTEGER NOT NULL,
  key            TEXT NOT NULL,
  old_value      TEXT,
  new_value      TEXT,
  source         TEXT,
  count          INTEGER NOT NULL DEFAULT 1,
  first_at       INTEGER NOT NULL,
  last_at        INTEGER NOT NULL,
  PRIMARY KEY (config_id, key, old_value, new_value, source)
);
```

按 `(config_id, key, old, new, source)` 聚合计数，不存设备标识。

### 15.4 上报节流

- 只在**值发生变化**时记录（不是每次启动都记）
- 单次上报最多 20 条，超出丢弃最旧的
- 上报成功后清空本地队列

---

## 16. 配置唯一 ID（C11）

### 16.1 规则

- 每次 `POST /admin/config` 发布时，服务端生成 **`config_id`**（`crypto.randomUUID()`）
- `config_id` 全局唯一，**永不复用**
- `config_version` 单调递增（用于客户端版本比较与 304）
- 响应同时带两者

### 16.2 客户端用途

- 缓存 `config_id` 用于回报
- 回报时带上 `config_id` + `config_version`，服务端可精确关联"哪一次下发"被应用

### 16.3 不可变

- 同一 `config_version` 的 `config_id` 不可变
- 重新发布同 version 会被拒绝（409）

---

## 17. 验收标准

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
| A13 | 无 `notices` 下发时，启动不弹任何通知 |
| A14 | 通知频率控制正确：`once` 只弹一次，`once_per_day` 每天最多一次 |
| A15 | 通知窗口的关闭/复制/链接按钮按配置呈现，链接过 https 白名单 |
| A16 | 远程可隐藏设置页 section/item，可新增 switch item 并生效 |
| A17 | 远程新增的二级页可打开，blocks 按白名单渲染 |
| A18 | UI 颜色/尺寸覆盖立即生效，无下发时与默认完全一致 |
| A19 | 每个设置项变化都产生一条 `config_apply` 记录，含 old/new/config_id |
| A20 | 每次发布生成的 `config_id` 全局唯一，同 version 重发被拒 |

## 18. 实施分期

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
| P10 | 远程通知：Worker `/v1/config` 的 notices 段 + 客户端 `RemoteNotice` + 展示组件 | 服务端 + 客户端 |
| P11 | 设置页远程化：`SettingsSchema` + `SettingsPage` 数据驱动改造 + `DynamicPage` | 客户端 |
| P12 | UI 下发：`HgColor`/`HgSpace` 接 `ConfigRegistry` + 入口显隐/排序 | 客户端 |
| P13 | 配置应用回报：`ConfigApplyLog` + `/v1/report` 扩展 + 服务端表 + 面板 | 服务端 + 客户端 |
| P14 | 配置唯一 ID：`/admin/config` 生成 `config_id` + 客户端缓存与回报 | 服务端 + 客户端 |
