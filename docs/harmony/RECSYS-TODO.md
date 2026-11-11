# RECSYS-TODO：离线推荐实施清单

> SPEC：`docs/harmony/RECSYS-SPEC.md`；上游设计：`hghub-recsys-deliverable/docs/OFFLINE-RECSYS.md`
> 约束更新：**允许额外网络与客户端静默后台抓取**（限速/可关/失败静默）。
> 状态：`[ ]` 未开始 · `[~]` 进行中 · `[x]` 完成

## P0：本期实施（池优先 + 静默同步）

- [x] 编写 SPEC 与 TODO
- [x] 资源落包：`rawfile/recommend/catalog_pack.json`、`genre_dict.json`
- [ ] `recommend/RecTypes.ets`
- [ ] `recommend/RecDict.ets`：词典载入、标签名/别名、关键词最小打标
- [ ] `recommend/RecCatalog.ets`：预置包载入 + 增量目录合并、id→labels/pop/eps、by_tag、持久化
- [ ] `recommend/RecProfile.ets`：画像、指数衰减（τ=7d）、种子（收藏/点赞/历史）、防抖持久化
- [ ] `recommend/RecService.ets`：init / pick / record* / diagnostics / syncNow
- [ ] `recommend/RecSync.ets`：后台串行目录同步（feed 前 N 页 + 4 分类），限速、单次上限、冷却、可关
- [ ] HomePage：`shuffled(pool)` → `RecService.pick(pool, n)`（启动/换一批/刷新/触底/预挑）
- [ ] HomePage：点击事件
- [ ] PlayerPage：播放开始/完播/收藏事件
- [ ] EntryAbility：异步 init + 后台同步 kickoff
- [ ] SettingsPage：推荐开关 + 诊断（目录数/画像数/Top标签/同步状态）
- [ ] 编译通过 + 真机冒烟 + 分步提交

## P1：RDB 与事件（M0 + M2）

- [ ] `RecStore.ets`：relationalStore（items/events/profile/meta）+ preferences 迁移（幂等）
- [ ] `EventLog.ets`：曝光/点击/播放/完播/收藏/快划（去抖）
- [ ] 懒衰减 + 时段桶；最小样本阈值 + Wilson 下界
- [ ] 设置页：清除推荐数据

## P2：完整打标 + 池增长（M1 / M1.5）

- [ ] `LabelDict.ets`：AC 自动机 + 停用词 + 形式规则
- [ ] `Labeler.ets`：tags 直采/关键词/规则/n-gram 向量；TaskPool；meta_hash 去重
- [ ] `NgramVec.ets`：2/3-gram 哈希 64 维
- [ ] 接收池语义（整页入库）+ 详情补全
- [ ] 滚动预取 G3 / 冷启动预热 G5 / 曝光回流 G2
- [ ] 目录同步增强：榜单快照、分类轮换、增量封面预热

## P3：多路召回与排序（M3）

- [ ] `Recall.ets`：R1–R7 多路召回
- [ ] `Ranker.ets`：评分 + MMR + 同 L1 上限 + ε-greedy
- [ ] reason 生成
- [ ] 独立"为你推荐"入口与离线标识

## P4：统一缓存池（M0.2，可与 P0 并行）

- [ ] CacheManager：RDB 索引 + 文件分层（api/content/img/media）+ 原子写 + 分级配额（默认 2GB，自适应 ≤15%）
- [ ] `Api.edgeOnce` 写穿（排除 account/token/带签名 URL）
- [ ] ImageCache / 媒体缓存接入
- [ ] 播放会话 pin + 价值加权 LRU + 剧集完整性
- [ ] 设置页缓存明细/分命名空间清理

## P5：观测与评估（M4）

- [ ] 推荐诊断页（条目/覆盖率/画像/理由分布/耗时）
- [ ] 离线回放评估（HitRate@10 / NDCG@10 / Coverage / Diversity）
- [ ] 本地 A/B + 负向指标

## P6：可选

- [ ] MindSpore Lite ranker
- [ ] 封面分类（CoreVisionKit）
- [ ] 词典自动补充（本地词频候选）
