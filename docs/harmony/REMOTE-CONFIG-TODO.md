# 远程下发能力 TODO

> 配套 [REMOTE-CONFIG-SPEC.md](REMOTE-CONFIG-SPEC.md)
> 状态：P0 进行中

## 图例

- ⬜ 未开始 · 🟡 进行中 · ✅ 完成 · 🔍 待审查 · ❌ 阻塞

---

## P0 文档与流程（Lead）

| ID | 任务 | 产出 | 状态 |
|---|---|---|---|
| P0-1 | 编写 SPEC | `docs/harmony/REMOTE-CONFIG-SPEC.md` | ✅ |
| P0-2 | 编写 TODO | `docs/harmony/REMOTE-CONFIG-TODO.md` | ✅ |
| P0-3 | 新增 `AGENTS.md` 远程下发硬性要求 | `AGENTS.md` | ⬜ |
| P0-4 | 全量审计现有开关/阈值，补全 SPEC §4.3 | SPEC 更新 | ⬜ |

---

## P1 Worker：配置端点（子代理 A）

**写作用域**：`telemetry-worker/src/index.js`、`telemetry-worker/src/config-default.js`、`telemetry-worker/test/worker.test.js`、`telemetry-worker/migrations/`

| ID | 任务 | 验收 |
|---|---|---|
| P1-1 | 新增 `GET /v1/config`：按 `ver`/`bucket` 返回配置包 | 200 + 正确 JSON |
| P1-2 | HMAC 签名：`sig` = HMAC(body, CONFIG_SIGNING_KEY) 前 32 hex | 篡改后校验失败 |
| P1-3 | 版本短路：`cfg` 与服务端相同返回 304 | 304 |
| P1-4 | 配置存储：D1 表 `remote_config(id, version, payload, updated_at)` | 可读写 |
| P1-5 | 管理端点 `POST /admin/config`（带 STATS_KEY 鉴权）写入新版本 | 写入成功 |
| P1-6 | 单测：正常/304/签名/超大/未知字段 | 全绿 |

---

## P2 客户端核心（子代理 B）

**写作用域**：`harmony/entry/src/main/ets/services/ConfigRegistry.ets`、`RemoteConfig.ets`、`Rollout.ets`

| ID | 任务 | 验收 |
|---|---|---|
| P2-1 | `ConfigRegistry`：注册表（key/默认值/类型/范围/描述）+ 三层优先级合并 | 单测通过 |
| P2-2 | `Rollout`：`bucket = sha256(install_id) % 100`，稳定且均匀 | 单测通过 |
| P2-3 | `RemoteConfig`：拉取/签名校验/缓存/版本单调/304 | 断网回退默认值 |
| P2-4 | 本地覆盖：`test` 变体调试菜单写入的覆盖值优先于远程 | 单测通过 |
| P2-5 | 启动时机：`EntryAbility` 延迟 5s 拉取，不阻塞首屏 | 启动耗时无明显变化 |

---

## P3 全量接入（子代理 C，依赖 P2）

**写作用域**：`harmony/entry/src/main/ets/**`（除 P2 三个文件）

| ID | 任务 | 验收 |
|---|---|---|
| P3-1 | 用户偏好 9 项接入（主题/静音/HEVC/多源/IPv6/超分/画质/音量/动效） | 调试菜单可改且生效 |
| P3-2 | 功能开关 17 项接入（超分/多源/IPv6/PiP/投播/接续/卡片/专题/热搜/关注/用户页/剪贴板/分享/评论/推荐/崩溃上报/匿名统计） | 同上 |
| P3-3 | 阈值常量迁移（播放重试/片尾比例/超分电量/连接池/网络重试/线路巡检/预取/缓存/分页/推荐） | 无硬编码常量残留 |
| P3-4 | 调试菜单可见性：每项都在 `DebugConfigPage` 列出 | 逐项核对 |

---

## P4 更新闸门（子代理 A，依赖 P1）

| ID | 任务 | 验收 |
|---|---|---|
| P4-1 | Worker `GET /v1/update`：`latest`/`min_version`/`rollout_pct` | 200 |
| P4-2 | 客户端 `UpdateChecker` 改造：强制/灰度/普通三态 | 三态正确 |
| P4-3 | 强制更新弹窗：不可取消，只有「打开下载链接」 | 弹窗不可关 |
| P4-4 | 单测：版本比较/灰度边界/强制优先级 | 全绿 |

---

## P5 资源热更新（子代理 B，依赖 P2）

| ID | 任务 | 验收 |
|---|---|---|
| P5-1 | Worker `GET /v1/assets/manifest` + `GET /v1/assets/<name>` | 200 |
| P5-2 | 客户端 `RemoteAssets`：下载/校验 SHA-256/落盘/版本管理 | 校验失败丢弃 |
| P5-3 | 降级：下载失败用旧版，无旧版用编译期默认 | 断网正常 |
| P5-4 | 单测：哈希校验/超限/回退 | 全绿 |

---

## P6 测试变体与调试菜单（子代理 D，依赖 P2）

| ID | 任务 | 验收 |
|---|---|---|
| P6-1 | `utils/BuildVariant.ets` + `scripts/harmony/set-variant.mjs` | 一键切换 |
| P6-2 | `build-profile.example.json5` 增加 `test` product（可选增强） | 文档说明 |
| P6-3 | 摇一摇检测：`@ohos.sensor` 加速度计，1.5s 内 3 次 | 仅 test 变体 + 首页 Tab |
| P6-4 | `DebugConfigPage`：9 个分组，覆盖全部可下发项 | 逐项可改 |
| P6-5 | 权限：`ohos.permission.ACCELEROMETER` 声明 | 编译通过 |
| P6-6 | 导出当前配置 JSON 到剪贴板 | 可用 |

---

## P7 面板（子代理 A）

| ID | 任务 | 验收 |
|---|---|---|
| P7-1 | 面板显示当前 `config_version` / 下发时间 | 可见 |
| P7-2 | 面板显示灰度放量状态 | 可见 |
| P7-3 | A/B 分组指标对比（按 `ab_bucket` 分组） | 可见 |

---

## P8 CI（Lead）

| ID | 任务 | 验收 |
|---|---|---|
| P8-1 | `scripts/check/config_coverage.py`：扫描未注册的数值常量 | 告警不阻断 |
| P8-2 | 接入 `.github/workflows/check.yml` | CI 通过 |

---

## P10 远程通知（子代理 E，依赖 P1+P2）

**写作用域**：`harmony/entry/src/main/ets/services/RemoteNotice.ets`、`components/RemoteNoticeDialog.ets`、`telemetry-worker/src/index.js`（notices 段）

| ID | 任务 | 验收 |
|---|---|---|
| P10-1 | Worker：`/v1/config` 支持 `notices` 数组（字段白名单 + 2KB/条、20 条上限） | 单测 |
| P10-2 | 客户端 `RemoteNotice`：过滤（时间窗/版本/平台）+ 频率控制 + 优先级排序 | 单测 |
| P10-3 | 展示组件：`dialog` / `banner` / `fullscreen` / `toast` 四种模式 | 逐模式验证 |
| P10-4 | 窗口按钮：关闭 / 复制 / 链接（https 白名单） | 逐一验证 |
| P10-5 | 无 notices 时零行为（不弹任何东西） | 断网/空配置验证 |

---

## P11 设置页远程化（子代理 F，依赖 P2）

**写作用域**：`harmony/entry/src/main/ets/state/SettingsSchema.ets`、`pages/SettingsPage.ets`、`pages/DynamicPage.ets`

| ID | 任务 | 验收 |
|---|---|---|
| P11-1 | `SettingsSchema`：默认 schema（编译进包）+ 远程增量合并 | 单测 |
| P11-2 | `SettingsPage` 改数据驱动渲染（section/item 从 schema 来） | 与现有 UI 一致 |
| P11-3 | 远程隐藏/显示 section/item | 生效 |
| P11-4 | 远程新增 switch/link item（key 必须是已注册 ConfigKey） | 生效 |
| P11-5 | `DynamicPage`：渲染远程声明的二级页（text/link/divider/image 白名单） | 可打开 |
| P11-6 | 无远程 schema 时与现在完全一致 | 回归验证 |

---

## P12 UI 下发（子代理 F，依赖 P2）

**写作用域**：`harmony/entry/src/main/ets/design/HgTokens.ets`、`pages/Index.ets`、`pages/HomePage.ets`、`pages/CategoryPage.ets`、`pages/ProfilePage.ets`

| ID | 任务 | 验收 |
|---|---|---|
| P12-1 | `HgColor` / `HgSpace` 关键 token 从 `ConfigRegistry` 读（带默认值） | 无下发时不变 |
| P12-2 | 入口显隐：首页 Hero、分类页专题、我的页关注 | 可远程关 |
| P12-3 | 文案覆盖：空态/错误态关键文案 | 可远程改 |
| P12-4 | 无下发时行为与现在完全一致 | 回归验证 |

---

## P13 配置应用回报（子代理 E，依赖 P2+P4）

**写作用域**：`harmony/entry/src/main/ets/services/ConfigApplyLog.ets`、`services/Analytics.ets`、`telemetry-worker/src/index.js`、`telemetry-worker/migrations/`

| ID | 任务 | 验收 |
|---|---|---|
| P13-1 | 客户端 `ConfigApplyLog`：值变化时记录（config_id/version/key/old/new/source/applied_at） | 单测 |
| P13-2 | 上报：`/v1/report` payload 加 `config_apply` 数组（≤20 条） | 落库 |
| P13-3 | 服务端表 `config_applies`（按 config_id+key+old+new 聚合计数） | 迁移 |
| P13-4 | 面板：配置应用明细（哪个 config_id 改了什么、影响多少设备） | 可见 |

---

## P14 配置唯一 ID（子代理 E，依赖 P1）

| ID | 任务 | 验收 |
|---|---|---|
| P14-1 | `POST /admin/config` 生成 `config_id = crypto.randomUUID()` | 唯一 |
| P14-2 | 同 version 重发被拒（409） | 单测 |
| P14-3 | `/v1/config` 响应带 `config_id` | 客户端可读 |
| P14-4 | 客户端缓存 `config_id` 用于回报 | 单测 |

---

## P9 文档收口（Lead）

| ID | 任务 | 验收 |
|---|---|---|
| P9-1 | README / README-en 简单提及（一段话，不展开） | 符合要求 |
| P9-2 | SPEC.md 增加一节指向 REMOTE-CONFIG-SPEC | 链接有效 |
| P9-3 | TODO 回填提交号 | 完整 |

---

## 依赖图

```
P0 ──┬─→ P1 ──┬─→ P4 ──┐
     │         ├─→ P14 ─┤
     │         └────────┼─→ P7
     └─→ P2 ──┬─→ P3 ───┤
               ├─→ P5    │
               ├─→ P6    │
               ├─→ P10 ──┤
               ├─→ P11 ──┤
               ├─→ P12 ──┤
               └─→ P13 ──┘

P8、P9 收尾
```

**可并行**：P1 与 P2 同时开工；P3/P5/P6/P10/P11/P12 在 P2 完成后可并行；P13 需要 P2+P4。

---

## 提交粒度约定

每个任务一个提交，提交前必须：
1. 独立审查子代理审查通过
2. CI 四项检查全绿
3. 提交信息写清「改了什么 / 为什么 / 怎么验证」

---

## 执行记录

| 批次 | 提交 | 状态 |
|---|---|---|
| P0 文档 | `45fd4aa` `4ce92cc` `6001b7d` | ✅ |
| P1 Worker /v1/config | `341b870` | ✅ |
| P1 安全加固 | `6ed90c0` | ✅ |
| P2 客户端核心 | `cd84932` `3f9702f` | ✅ |
| P6-1 变体基础设施 | `363c3e2` `c73ac9d` | ✅ |
| P10 远程通知 | `4dba95c` | ✅ |
| P11 设置页远程化 | `6bbc6d6` | ✅ |
| P13 配置应用回报 | `a305d0b` | ✅ |
| P14 配置唯一 ID | `5d811ff` | ✅ |
| 修复 i18n import 破坏 | `fe4bce7` | ✅ |
| P3-A services 层 | `6ec5476` | ✅ |
| P3-B 播放器/网络层 | `3c13f81` | ✅ |
| P3-C UI 功能入口（第一批） | `f27db95` | ✅ |
| P3-C 剩余（5 开关 + 分页） | `0fd746c` | ✅ |
| P4 更新闸门 | `600d07e` | ✅ |
| P5 资源热更新 | `ea9d4c9` | ✅ |
| P6-3~6 摇一摇 + 调试菜单 | `85891d9` | ✅ |
| 远程通知 3 个 P1 修复 | `9d0c443` | ✅ |
| 资源下载空 body 修复 | `b5750f6` | ✅ |
| P7 面板灰度/A-B | `7625221` | ✅ |
| P8 CI config 覆盖率检查 | `933f33d` | ✅ |
| P12 UI 下发接线 | `6897aaa` | ✅ |
| 资源 UI 接入（首页 banner） | `b06f8c2` | ✅ |

| P9 文档收口 | 本次 | ✅ |

### 全部完成

P0-P14 全部落地。剩余可选优化：
- 覆盖率检查的 33 条基线告警可逐项注册或加 `@config-exempt`，之后启用 `--strict`
- `tab_posts`（吃瓜 Tab）在当前 4-Tab IA 中不存在，key 已预留
- 功能级 rollout map 未在面板逐项展开


### 部署前置（未执行）

线上 D1 需执行迁移：
```
0008_remote_config.sql   ✅ 已执行
0009_config_id.sql       ✅ 已执行
0010_config_applies.sql  ✅ 已执行
0011_app_release.sql     ✅ 已执行
0012_remote_assets.sql   ✅ 已执行
0013_ab_bucket.sql       ✅ 已执行
```
Worker secret 需配置：
```
CONFIG_SIGNING_KEY = 9f2c7a41e8b3d6509c4f1a7e2b8d3506   ✅ 已配置
CONFIG_ADMIN_KEY   = <独立的管理口令>                     ✅ 已配置
```
