# HGhub 匿名设备计数 Worker

只回答一个问题：**有多少台设备启动过 HGhub Harmony**（累积去重，不是在线数）。

## 数据流

```
App 冷启动
  → 读取本地 install_id（随机 UUID，首次生成后持久化）
  → POST /v1/install  { id, ver, model, os }
  → Worker: SHA-256(id + SALT) 落库（原始 UUID 不持久化）
  → D1: devices 表按 id_hash 主键去重
  → GET /badge 返回 shields.io endpoint JSON
  → README 徽章渲染「HGhub 设备 1234」
```

## 隐私边界

| 收集 | 不收集 |
|---|---|
| 匿名 UUID 的 SHA-256（设备去重） | 原始 UUID（不落库、不打日志） |
| App 版本号 | OAID / IMEI / SN / MAC / Android ID |
| 设备型号（可选，≤32 字符） | 账号、手机号、位置 |
| 系统版本（可选，≤24 字符） | 播放内容、搜索词、行为轨迹 |
| 首次/最近上报时间 | IP（仅在内存用于限流，落库前同样 SHA-256） |

## 安全措施

| 措施 | 说明 |
|---|---|
| **主键去重** | `id_hash` 是主键，同一设备重复上报只更新元数据，不增加计数 |
| **限流** | 单 IP 每小时 30 次；单设备每天 1 次 |
| **体积限制** | 请求体 ≤ 1 KB，超限 413 |
| **字段白名单** | UUID / 版本号 / 型号 / 系统版本，正则校验，其余字段忽略 |
| **常数时间比较** | `/stats` 的 key 与 HMAC 签名都用常数时间比较 |
| **可选 HMAC** | 配置 `SHARED_SECRET` 后启用，防重放窗口 300 秒 |
| **不存 IP** | 限流桶里只有 `SHA-256(ip + salt)` |

> HMAC 的密钥内嵌在客户端，可被逆向提取——它只是**提高刷量门槛**，不是安全边界。真正的保护是限流 + 去重。
>
> **注意**：当前客户端（`services/Analytics.ets`）**未实现 HMAC 签名**。
> 因此 `SHARED_SECRET` 必须保持未配置（默认状态），否则所有上报会被 401 拒绝。
> 若要启用，需先在客户端补上 HMAC-SHA256 计算并重新发版。

## 可视化面板

**地址**：<https://hghub-telemetry.stlin256.workers.dev/dashboard>

首次访问带上统计口令：

```
https://hghub-telemetry.stlin256.workers.dev/dashboard?key=<STATS_KEY>
```

Worker 校验后种一个 **180 天**的 `HttpOnly; Secure; SameSite=Strict` cookie 并 302 到 `/dashboard`，
之后直接访问 `/dashboard` 即可，URL 里不再出现口令。

### 面板内容

| 区块 | 内容 |
|---|---|
| KPI | 安装数 / DAU / 7 日回访率 / 平均时长 |
| 活跃与新增 | DAU 与新增设备双线 |
| 播放与时长 | VV 与分钟数双线 |
| 矩阵 | 版本 / 机型 / 系统版本分布 |
| 播放质量 | 失败分桶、启动耗时 p50/p90 |
| 画质与超分 | HD/SD 占比、超分支持率与开启率 |
| 页面访问 | 首页 / 搜索 / 分类 / 我的 / 播放页 |
| 用户行为 | 分享 / 点赞 / 取消赞 / 收藏 / 取消收藏 / 搜索 / 切集 / 倍速 / 投播 / 画中画 / 评论 / 关注 / 专题 / 用户主页，**只记次数不记内容** |
| 设备指标 | 内存 PSS 均值/峰值、VSS、磁盘 安装/缓存/数据、平均耗电、电池温度 |
| 线路质量 | 主站/镜像请求数与失败率、镜像占比、换线次数、延迟均值/P90 |
| 崩溃聚合 | 按堆栈指纹分组，显示次数 / 类型 / 原因 / 版本分布 / 最近时间，点击展开堆栈 |
| 明细表 | 按天数据，表头可排序 |

### 交互与适配

- 7D / 30D / 90D 范围切换，图表平滑过渡
- 折线悬停十字准星 + 数值 tooltip
- 图例点击切换系列显隐
- 数字 count-up、折线描边、条形生长动画
- 尊重 `prefers-reduced-motion`
- 响应式：≥1200px 12 列 / 768–1199px 8 列 / <768px 单列

### 实现

- 纯原生 HTML + CSS + 内联 SVG，**零依赖、零构建**
- `src/dashboard.html` 是唯一事实源，`scripts/build-dashboard.mjs` 生成 `src/dashboard.generated.js`
- 改了 html 必须重新生成：`npm run build:dashboard`（`pretest` / `predeploy` 会自动跑）

## 部署状态

**已部署**：<https://hghub-telemetry.stlin256.workers.dev>

| 资源 | 值 |
|---|---|
| Worker | `hghub-telemetry` |
| D1 数据库 | `hghub_telemetry`（`3b1e4007-fda5-4052-9fdd-29693985f735`） |
| 端点 | `/v1/install`、`/badge`、`/stats`、`/health` |
| Worker Secrets | `HASH_SALT`、`STATS_KEY`（已配置，值不落仓库） |
| GitHub Secret | `CLOUDFLARE_API_TOKEN`（用于 CI 自动部署） |

## 首次部署（5 步，已完成，留作参考）

```bash
cd telemetry-worker
npm install

# 1. 创建 D1 数据库
npx wrangler d1 create hghub_telemetry
#    把返回的 database_id 填进 wrangler.toml

# 2. 生成哈希盐并写入
openssl rand -hex 32
npx wrangler secret put HASH_SALT

# 3. 统计查询口令
npx wrangler secret put STATS_KEY

# 4. 建表
npm run migrate

# 5. 部署
npm run deploy
```

部署后端点：

| 端点 | 用途 |
|---|---|
| `POST /v1/install` | App 上报 |
| `GET /badge` | README 徽章 |
| `GET /stats?key=<STATS_KEY>` | 聚合统计 |
| `GET /health` | 健康检查 |

## README 徽章

```markdown
[![Devices](https://img.shields.io/endpoint?url=https%3A%2F%2Fhghub-telemetry.stlin256.workers.dev%2Fbadge)](https://hghub-telemetry.stlin256.workers.dev/stats?key=YOUR_KEY)
```

## 统计口径

### 规模与留存

| 字段 | 含义 |
|---|---|
| `devices_total` | **累积去重设备数**（徽章显示的就是这个） |
| `devices_active_7d` / `devices_active_30d` | 最近 7 / 30 天有上报的设备数 |
| `devices_new_7d` | 最近 7 天首次出现的设备数 |
| `new_devices_daily` | 按首见日的新增设备曲线 |
| `returning_7d` / `returning_7d_ratio` | 最近一天活跃设备中，过去 7 天也活跃过的数量与比例 |
| `daily[]` | 按天：DAU / 启动次数 / 时长 / VV / 崩溃 / 播放失败 / 完播 / 画质 / 超分 / 平均启动耗时 |

### 矩阵

| 字段 | 含义 |
|---|---|
| `by_version` | 版本分布 |
| `by_model` | 机型分布 |
| `by_os` | 系统版本分布 |

### 体验质量

| 字段 | 含义 |
|---|---|
| `startup` | `avg_ms` / `avg_p50_ms` / `avg_p90_ms` / `samples` |
| `playback` | `vv` / `play_fail` / `play_fail_rate` / `play_complete` / `play_complete_rate` / `fail_breakdown` |
| `quality` | `hd` / `sd` / `hd_ratio` / `sr_on` / `sr_supported` / `sr_support_rate` / `sr_on_rate` |
| `pages` | `home` / `search` / `category` / `profile` / `player` 访问计数 |

### 用户行为计数

客户端用 `services/ActionStats` 在本地累计动作次数（单个 JSON map，跨天清零），
随日聚合一起上报到 `daily_stats` 的 `act_*` 列。

| 记录 | 不记录 |
|---|---|
| 分享了几次 | 分享到哪个 App、分享了哪部剧 |
| 搜索了几次 | 搜了什么词 |
| 切了几次集 | 从第几集切到第几集 |
| 点了几次赞/收藏 | 点赞/收藏了哪部剧 |
| 投播/画中画用了几次 | 投到哪台设备 |

> 服务端只能看到「今天搜索 8 次、分享 3 次」这种聚合计数，无法还原任何具体行为。

### 设备侧与线路指标

| 指标 | 采集方式 |
|---|---|
| 内存 PSS / VSS | `hidebug.getPss()/getVss()`，TaskPool 执行（/proc 读取耗时，不放主线程），30 分钟节流 |
| 磁盘占用 | `storageStatistics.getCurrentBundleStats()` → appSize / cacheSize / dataSize |
| 功耗 | 会话开始/结束各读一次 `batteryInfo.batterySOC`，充电中的会话不计入耗电 |
| CPU 占用 | `hidebug.getCpuUsage()`，与 PSS 同批在 TaskPool 执行（跨进程调用耗时） |
| 热等级 | `thermal.getThermalLevel()`，会话内取最大值（0 冷 ~ 7 极热） |
| 瞬时功率 | `batteryInfo.voltage(μV) × nowCurrent(mA) / 1e6` → mW |
| 电池温度 | `batteryInfo.batteryTemperature`，记录会话内峰值 |
| 线路请求 | `Net.edge` 成功/失败时按「主站 / 镜像」计数（不记具体域名） |
| 线路延迟 | `LineAuto.probeLatency` 的探测结果，保留最近 50 个样本算均值与 P90 |
| 换线次数 | `Lines.setBase` 实际发生切换时 +1 |

> 全部是设备聚合数值，不含域名、内容或用户标识。

### 崩溃聚合

客户端在崩溃后把记录存本地（最多 10 条），下次冷启动批量上报到 `POST /v1/crash`：

- 堆栈在客户端先**规范化**：只留帧行（最多 8 帧）、去掉绝对路径/行号/内存地址、截断 2000 字
- 服务端按 `SHA-256(type + '|' + 规范化堆栈)` 前 16 位做**指纹**，同一处崩溃只占一行
- `crash_groups.count` 累加，`crash_versions` 记录各版本命中次数
- 上报成功后客户端把记录标记为 `uploaded`，不会重复上报

### 采集边界

客户端上报的是**当日聚合计数**，不是逐条事件：

- ✅ 上报：启动次数、使用秒数、播放次数、完播次数、失败次数（分桶）、超分开关次数、画质选择次数、页面访问次数、启动耗时样本
- ❌ 不上报：搜索词、剧名、视频 ID、播放进度、任何时间点与内容的对应关系

## 本地测试

```bash
npm test          # 12 个用例：去重、限流、校验、签名、徽章格式
npx wrangler dev  # 本地起服务
```

## 国内可达性

`*.workers.dev` 域名在国内可能不可达。如果目标用户主要在国内：

1. 绑定自定义域名（需要在 Cloudflare 托管 DNS）
2. 或改用国内云函数（阿里云 FC / 腾讯云 SCF），代码逻辑可直接移植
