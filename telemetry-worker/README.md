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
> **注意**：当前客户端（`services/InstallReporter.ets`）**未实现 HMAC 签名**。
> 因此 `SHARED_SECRET` 必须保持未配置（默认状态），否则所有上报会被 401 拒绝。
> 若要启用，需先在客户端补上 HMAC-SHA256 计算并重新发版。

## 部署（5 步）

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

| 指标 | 含义 |
|---|---|
| `devices_total` | **累积去重设备数**（徽章显示的就是这个） |
| `devices_active_7d` | 最近 7 天有上报的设备数 |
| `devices_active_30d` | 最近 30 天有上报的设备数 |
| `devices_new_7d` | 最近 7 天首次出现的设备数 |
| `by_version` | 版本分布 |
| `by_model` | 机型分布 |

## 本地测试

```bash
npm test          # 12 个用例：去重、限流、校验、签名、徽章格式
npx wrangler dev  # 本地起服务
```

## 国内可达性

`*.workers.dev` 域名在国内可能不可达。如果目标用户主要在国内：

1. 绑定自定义域名（需要在 Cloudflare 托管 DNS）
2. 或改用国内云函数（阿里云 FC / 腾讯云 SCF），代码逻辑可直接移植
