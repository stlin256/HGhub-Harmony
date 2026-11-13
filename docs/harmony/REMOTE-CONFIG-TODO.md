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

## P9 文档收口（Lead）

| ID | 任务 | 验收 |
|---|---|---|
| P9-1 | README / README-en 简单提及（一段话，不展开） | 符合要求 |
| P9-2 | SPEC.md 增加一节指向 REMOTE-CONFIG-SPEC | 链接有效 |
| P9-3 | TODO 回填提交号 | 完整 |

---

## 依赖图

```
P0 ──┬─→ P1 ──→ P4 ──┐
     │                ├─→ P7
     └─→ P2 ──┬─→ P3 ─┘
              ├─→ P5
              └─→ P6

P8、P9 收尾
```

**可并行**：P1 与 P2 同时开工；P3/P5/P6 在 P2 完成后可并行。

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
| P0 | 待填 | 🟡 |
| P1 | 待填 | ⬜ |
| P2 | 待填 | ⬜ |
| P3 | 待填 | ⬜ |
| P4 | 待填 | ⬜ |
| P5 | 待填 | ⬜ |
| P6 | 待填 | ⬜ |
| P7 | 待填 | ⬜ |
| P8 | 待填 | ⬜ |
| P9 | 待填 | ⬜ |
