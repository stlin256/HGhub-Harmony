# RECSYS-TODO：离线推荐实施清单

> SPEC：`docs/harmony/RECSYS-SPEC.md`；上游设计：`hghub-recsys-deliverable/docs/OFFLINE-RECSYS.md`
> 状态：`[ ]` 未开始 · `[~]` 进行中 · `[x]` 完成

## P0：本期实施（M0.5 + M1.5-lite）

- [ ] 编写 SPEC 与 TODO
- [ ] 资源落包：`rawfile/recommend/catalog_pack.json`（183 KB）、`genre_dict.json`（26 KB）
- [ ] `recommend/RecTypes.ets`：CatalogItem / RecDiagnostics / 事件常量
- [ ] `recommend/RecPack.ets`：异步载入预置包；id→labels/pop/cate/eps；by_tag 倒排；失败降级
- [ ] `recommend/RecProfile.ets`：画像 Map、指数衰减（τ=7d）、事件权重、种子（收藏+3 / 点赞+1.5 / 历史+1）、防抖持久化
- [ ] `recommend/RecService.ets`：init / enabled / pick（加权随机采样）/ recordCardClick / recordPlayStart / recordComplete / recordFavorite / diagnostics
- [ ] HomePage：`shuffled(pool)` → `RecService.pick(pool, n)`（启动、换一批、下拉刷新、触底追加、预挑批次）
- [ ] HomePage：卡片点击 → `recordCardClick`
- [ ] PlayerPage：播放开始/完播/收藏 → 对应事件
- [ ] EntryAbility：首帧后异步 `RecService.init()`
- [ ] SettingsPage：推荐开关（默认开）+ 诊断（目录条数 / 画像标签数 / Top5 标签 / 包版本）
- [ ] 编译通过；真机冒烟（首页出内容、换一批有变化、收藏后画像可见）
- [ ] 提交（docs / assets / core / integration 分步 commit）

## P1：下一里程碑（M2 画像与事件）

- [ ] `RecStore.ets`：relationalStore 建表（items / events / profile / meta），启动迁移 preferences → RDB（幂等）
- [ ] `EventLog.ets`：曝光（可见≥50%且≥1s，30 分钟去重）/ 点击 / 播放 / 完播 / 收藏 / 快划
- [ ] 画像 7 天衰减改为懒衰减 + 时段桶（通勤/午休/睡前）
- [ ] 小样本平滑：最小样本阈值 + Wilson 下界
- [ ] 设置页：清除推荐数据

## P2：M1 打标 + M1.5 池增长

- [ ] `LabelDict.ets`：AC 自动机（词典 199 词）+ 停用词 + 形式规则
- [ ] `Labeler.ets`：tags 直采 / 关键词 / 规则 / n-gram 向量；TaskPool 批量；meta_hash 去重
- [ ] `NgramVec.ets`：字符 2/3-gram 哈希 64 维，L2 归一化
- [ ] 增量入池（接收池语义：整页 14 条全部入库）
- [ ] G3 滚动预取 / G5 冷启动预热（热门榜 + feed 前 2 页）
- [ ] 曝光回流（G2）

## P3：M3 多路召回与排序

- [ ] `Recall.ets`：R1 续看 / R2 标签 / R3 向量 / R4 热门 / R5 新剧 / R6 曝光回流 / R7 探索
- [ ] `Ranker.ets`：评分公式 + MMR（λ=0.7）+ 同 L1 标签 Top10≤3 + ε-greedy
- [ ] reason 生成（续看/因为你看过/本周热播/新上线）
- [ ] "为你推荐"独立入口与离线标识

## P4：M0.2 统一缓存池（可与 P0 并行）

- [ ] `CacheManager`：RDB 索引 + 文件分层（api/content/img/media）、原子写、分级配额（默认 2GB，自适应 ≤15% 可用空间）
- [ ] `Api.edgeOnce` 写穿（白名单排除 account/token/带签名 URL）
- [ ] ImageCache / 媒体缓存适配器接入
- [ ] 播放会话 pin（P0/P1/P2）+ 价值加权 LRU + 剧集完整性
- [ ] 设置页：缓存占用明细 / 分命名空间清理 / 智能清理

## P5：M4 观测与评估

- [ ] 设置 → 推荐诊断页（条目数/覆盖率/画像/理由分布/耗时）
- [ ] 离线回放评估（HitRate@10 / NDCG@10 / Coverage / Diversity）
- [ ] 本地 A/B（时间分桶）+ 负向指标警戒线

## P6：可选

- [ ] 端侧模型（MindSpore Lite ranker，缺失回退规则）
- [ ] 封面分类（CoreVisionKit，默认关闭）
- [ ] 词典自动补充（本地词频候选，诊断页手动触发）
