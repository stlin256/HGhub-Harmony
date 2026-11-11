# RECSYS-TODO：离线推荐实施清单

> SPEC：`docs/harmony/RECSYS-SPEC.md`；上游设计：`hghub-recsys-deliverable/docs/OFFLINE-RECSYS.md`
> 约束更新：**允许额外网络与客户端静默后台抓取**（限速/可关/失败静默）。
> 状态：`[ ]` 未开始 · `[~]` 进行中 · `[x]` 完成

## P0：本期实施（池优先 + 静默同步）

- [x] 编写 SPEC 与 TODO
- [x] 资源落包：`rawfile/recommend/catalog_full.json`（602KB，随包全量目录）、`genre_dict.json`
- [x] `scripts/harmony/build-catalog.py`：从 catalog_index 生成随包目录（可复现）
- [x] `recommend/RecTypes.ets`
- [x] `recommend/RecDict.ets`：词典载入、标签名/别名、关键词最小打标
- [x] `recommend/RecCatalog.ets`：随包全量目录 + 增量合并、id→labels/pop/eps、VideoCard 候选、持久化
- [x] `recommend/RecProfile.ets`：画像、指数衰减（τ=7d）、种子（收藏/点赞/历史）、防抖持久化
- [x] `recommend/RecService.ets`：init / pick（加权采样）/ record* / diagnostics / syncNow
- [x] `recommend/RecSync.ets`：后台串行目录同步（feed 前 3 页 + 4 分类），1.2s 限速、单次 ≤60、6h 冷却、可关
- [x] HomePage：`shuffled(pool)` → `RecService.pick(pool, n)`（启动/换一批/刷新/触底/预挑）+ 随包目录注入
- [x] HomePage：点击事件 → `RecService.recordClick`
- [x] PlayerPage：播放开始/完播/收藏事件 → 画像
- [x] EntryAbility：异步 `RecService.init()` + 后台同步 kickoff
- [x] SettingsPage：推荐开关 + 诊断（目录数/画像数/Top标签/同步状态/手动同步）
- [~] 编译通过（BUILD SUCCESSFUL）；真机冒烟待设备恢复连接

## P0.5：数据版本与无损迁移

- [x] `RecMeta.ets`：schema/字典/目录包/画像/增量版本键 + 迁移前备份
- [x] 随包目录版本记录（`rec_pack_version`），换包不清增量
- [x] 增量目录文件带 `schema/basePack`，旧 schema 备份 + 补默认字段
- [x] 画像文件带 `v`，旧格式备份后兼容读取
- [x] 设置诊断展示包/schema 版本

## P1：RDB 与事件（M0 + M2）

- [x] `RecStore.ets`：relationalStore（items/events/profile/meta）+ preferences 迁移（幂等）+ RdbStore.version/schema 版本
- [x] 事件采集：曝光（可见≥50%去重）/点击/播放/完播/收藏/搜索（RDB events 表，时段桶）
- [~] 懒衰减已实现；事件已带时段桶；最小样本阈值 + Wilson 下界待做（模型特征阶段一并处理）
- [~] `RecProfile.clear()` 已实现（清画像+事件）；设置页入口待加

## P1.5：端侧模型（路线 B，已完成首版）

- [x] 模型选型调研：`docs/harmony/RECSYS-MODEL-RESEARCH.md`
- [x] `train-ranker.py`：两塔 MLP 训练 + 固定 batch 128 ONNX 导出
- [x] `convert-ranker.ps1`：ONNX→.ms 转换（MinGW 运行时问题已解决）+ benchmark
- [x] `ranker_v2.ms`（174 KB）随包；`RecModel.ets` 推理 + `RecService` 模型分数主排序
- [x] v2：标题/简介文本 3-gram 特征（128 维）+ 显式交互层，合成验证集 AUC 0.61 → 0.836
- [x] 模型版本键 `rec_model_version` + 设置页诊断展示
- [ ] 真实事件积累后做离线回放评估 / 模型迭代（P5）

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
