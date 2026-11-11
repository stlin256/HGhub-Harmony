# RECSYS-SPEC：离线推荐与端侧智能（实施 SPEC）

> 依据：上游交付包 `hghub-recsys-deliverable`（README + docs/OFFLINE-RECSYS.md v1.7，2,213 行）
> 适用工程：`harmony/`（API 26 / HarmonyOS 7）
> 状态：实施中（M0.5 + M1.5-lite 先行）
> 关联文档：`docs/harmony/RECSYS-TODO.md`（任务清单）、`docs/harmony/DESIGN.md`（UI 规范）

---

## 1. 目标

在**完全没有任何云端智能**的前提下，为 HGhub-Harmony 提供端侧个性化推荐：

1. **池优先**：以预置目录池（3,388 条）+ 增量池为候选，不再依赖"单页 14 条"随机打乱；
2. **零额外网络**：只消费正常浏览请求与本地数据，不新增抓取、不维护数据包流水线；
3. **可降级**：词典/预置包/画像任一缺失时，回退热门/随机，不影响可用性；
4. **隐私**：行为与画像只落本地（preferences/RDB），不上传任何用户数据。

## 2. 范围

| 本期（M0.5 + M1.5-lite） | 后续里程碑（见 TODO） |
|---|---|
| 预置目录包载入（3,388 条标签/热度） | 端上懒打标（AC 自动机 + n-gram 向量） |
| 本地画像（收藏/点赞/历史 + 点击/播放/收藏事件） | RDB 事件表 + 7 天衰减 + 时段画像 |
| 推荐采样：池内加权随机（保留"换一批"体感） | 多路召回 R1–R7 + MMR 多样性 + reason |
| 首页"为你推荐"接入 + Hero 维持"最新上线" | 负反馈（不感兴趣/不再推荐此类） |
| 推荐开关 + 诊断信息（设置页） | 统一缓存池（2GB）、离线首屏、榜单时间序列 |
| 事件接入：点击 / 播放开始 / 收藏 | 冷启动预热（G5）、曝光回流（G2）、本地评估页 |

**不包含**：云端训练、跨用户协同过滤、账号体系、商业化。

## 3. 数据资产（来自交付包）

| 资产 | 大小 | 处理 |
|---|---|---|
| `catalog_pack.json` | 183 KB | **随包**，放 `resources/rawfile/recommend/`；启动后异步载入 |
| `genre_dict.json` | 26 KB | **随包**，放 `resources/rawfile/recommend/`；静态词典（后续打标用） |
| `catalog_index.json` | 1.3 MB | 不随包（开发/分析用） |
| `corpus_full.jsonl` | 3.9 MB | **不提交**（含成人向文本） |
| `ranks.json` / `text_stats.json` / `cate_map.json` | 小 | 不随包；仅在后续实验中使用 |

`catalog_pack` 结构：

```jsonc
{
  "v": "2026.11.11",
  "cates": ["ai-duanju", "ai-manju", "ai-huanlian", "ai-mogai"],
  "items": [[12, [4098, 4100, 8203], 1.0, 0, 21], ...],  // id, labels[], pop, cateIdx, eps
  "by_tag": { "4098": [0, 5, 9, ...] }                    // 标签 -> items 下标
}
```

## 4. 架构（本期落地部分）

```text
pages/HomePage.ets          "为你推荐" 池内采样
pages/PlayerPage.ets        播放/收藏事件 → 画像
entryability/EntryAbility   启动后异步 RecService.init()
pages/SettingsPage.ets      推荐开关 + 诊断
        │
recommend/RecService.ets    门面：init / pick / record / diagnostics
        ├─ RecPack.ets      预置目录包载入、id→labels/pop/cate/eps、by_tag
        ├─ RecProfile.ets   画像权重（指数衰减）、事件更新、持久化
        └─ RecTypes.ets     类型定义
        │
resources/rawfile/recommend/{catalog_pack,genre_dict}.json
state/UserPrefs.ets         收藏/点赞/历史（种子画像 + 事件来源）
```

## 5. 关键设计决策

1. **保留"换一批"体感**：推荐不是固定 Top-N 排序，而是**按画像权重加权随机采样**（weighted sampling without replacement），
   既有偏好倾斜，又保证每次换一批有变化；Hero 仍按 `new_at/last_ep_at` 取"最新上线"，不受推荐影响。
2. **M0.5 不引入 RDB**：画像先用 preferences 一个 JSON key（`rec_profile_v1`），事件即时更新、防抖落盘；
   RDB（items/events/profile）放到 M2，避免首期迁移风险。
3. **种子画像**：启动时把既有收藏（+3.0）、点赞（+1.5）、观看历史（+1.0）映射到标签，保证"装完就有效果"。
4. **事件类型与权重（本期）**：click +1.0、play_start +0.4、complete +2.0、favorite +3.0、unfavorite −2.0、fast_skip −0.6；
   指数衰减 `τ = 7 天`，权重裁剪 `[-5, 10]`。
5. **降级**：预置包缺失/解析失败 → `RecService.ready=false`，首页回退随机池（现有逻辑）；画像为空 → 热度+随机。
6. **无额外请求**：本模块不发起网络请求，只读本地数据。

## 6. 排序公式（本期）

```text
score = 0.55·affNorm + 0.25·pop + 0.10·fresh + 0.10·jitter
affNorm  = min-max 归一化(Σ 画像权重[item.labels])
pop      = 目录包热度（已归一化 0..1）
fresh    = new_at/last_ep_at 7 天内为 1，线性衰减到 0（无时间戳记 0.5）
jitter   = Math.random()（探索 10%）
```

采样权重 `w = exp(score / T)`，默认 `T = 0.35`，无放回抽取。

## 7. 验收（本期）

| 编号 | 场景 | 预期 |
|---|---|---|
| R01 | 首次启动（无本地数据） | 不崩溃；推荐≈热度+随机，仍能出内容 |
| R02 | 有收藏/历史 | 推荐池中同标签内容占比高于随机（目测 + 诊断 Top 标签） |
| R03 | 连续点"换一批" | 每批内容/顺序不同，且整体向偏好标签倾斜 |
| R04 | 预置包缺失/损坏 | 自动回退随机，首页可用，无报错 |
| R05 | 播放/收藏后 | 诊断页画像权重大于 0，下次采样更偏向该标签 |
| R06 | 离线 | 推荐逻辑不依赖网络；首页已有池即可采样 |
| R07 | 性能 | 3,388 条采样 < 5 ms；启动载入不阻塞首帧 |
| R08 | 隐私 | 无任何新增网络请求；画像只写本地 |

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| 标签 ID 动态（0xF000 段）露骨行为类 | 不进静态词典；画像只存 ID，不展示原始词 |
| 单用户样本小、噪声大 | 权重衰减 + 裁剪 + 最小样本阈值（后续 M2） |
| 预置包体积/启动耗时 | 180 KB，首帧后异步载入；解析失败降级 |
| 推荐导致信息茧房 | 采样保留 10% jitter + 后续 MMR/探索 |
| 内容版权/隐私 | 仅本地计算，不导出不上传；随包数据为公开目录元数据 |

## 9. 实施顺序（详见 TODO）

1. 文档（本 SPEC + TODO）
2. 资源落包：`genre_dict.json` + `catalog_pack.json`
3. 推荐核心模块（RecTypes / RecPack / RecProfile / RecService）
4. 接入：EntryAbility（init）、HomePage（采样 + 点击事件）、PlayerPage（播放/收藏事件）
5. 设置页：推荐开关 + 诊断
6. 编译、真机冒烟、提交；后续按 TODO 里程碑推进
