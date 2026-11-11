# RECSYS-MODEL-RESEARCH：端侧推荐模型选型与落地

> 状态：已选型并落地（路线 B：MindSpore Lite 推理）
> 日期：2026-11-11
> 关联：`RECSYS-SPEC.md`、`RECSYS-TODO.md`、交付包 `OFFLINE-RECSYS.md`（§11 端侧模型为可选 P2）

---

## 1. 需求与约束

用户要求：

1. **拒绝手工实现排序逻辑**，必须使用智能模型推理；
2. 先完成事件层（已落地：RDB items/events/profile/meta + 版本迁移），再上路线 B；
3. 必须先调研模型选择，再决定上什么模型；
4. 全部端侧、离线可用（允许后台网络抓目录，但不依赖云端训练/推荐服务）。

约束：

- HarmonyOS API 26 / ArkTS；可用 `@ohos.ai.mindSporeLite`（SDK 已确认存在，syscap `SystemCapability.AI.MindSporeLite`）；
- 包体尽量小、推理延迟低（<5ms 目标）、失败可降级；
- 单用户样本小，不能依赖海量行为训练深度模型；
- 数据/模型都要有版本跟踪，升级无损。

## 2. 候选方案对比

| 方案 | 说明 | 体积/延迟 | 训练数据 | 结论 |
|---|---|---|---|---|
| **A. MindSpore Lite 两塔 MLP ranker** | user/item 两塔 → concat MLP → 点击率；固定 batch 128 | 模型 ~121 KB；PC 0.24ms/批；端侧预计 1–3ms/批 | 公开目录 + 合成会话（无用户数据） | **选用** |
| B. MindSpore Lite 端侧训练（Lite Train） | 设备上继续训练 | 模型/运行时更大 | 需要真实行为 | 暂不选：API/稳定性风险高，先做推理 |
| C. 预训练文本 embedding 模型（MiniLM 等） | 文本向量召回 | 几 MB ~ 几十 MB，CPU 慢 | 通用语料 | 不选：包体/延迟不划算 |
| D. CoreVisionKit / NaturalLanguageKit | 图像分类、分词/实体 | 无排序输出 | — | 只可做辅助特征，不能做主排序 |
| E. 纯规则/统计 | 手工权重公式 | 0 | — | **用户明确拒绝**，只保留故障降级 |

## 3. 选定模型

**两塔 MLP 点击率模型（tower=48, mid=48）**

```text
user 输入 [128, 258]：256 桶标签亲和（画像哈希）+ [总权重, 画像标签数]
item 输入 [128, 265]：256 桶标签哈希（目录标签）+ [pop, fresh, score/10, eps/100, finished, cate_onehot(4)]
user_tower: Linear(258→48) → ReLU
item_tower: Linear(265→48) → ReLU
merge: Concat(96) → Linear(96→48) → ReLU → Linear(48→1) → Sigmoid
```

- 参数量约 3 万，ONNX 122 KB，转换后 `.ms` **121 KB**；
- 固定 batch 128（端侧一次给一批候选打分，避免逐条推理；候选不足 128 补零）；
- 输出为点击率 0..1，作为加权采样的主分数（保留 10% 随机探索）。

## 4. 训练数据与流程

- **公开目录**：随包 `catalog_full.json`（3,388 条，标签/热度/评分/集数/更新时间）；
- **合成用户会话**：从目录中抽 4–8 部「喜欢过的剧」，用它们的标签桶均值构造用户向量，
  按「偏好命中 + 质量 + 新鲜度 + 小噪声」生成点击标签；
- 训练：numpy 实现前向/反向（Adam），固定随机种子，可复现；
- 评估：合成验证集 AUC ≈ **0.61**（合成标签噪声 + 数据量有限；真实个性化主要依赖端侧画像特征，
  后续可用真实事件做离线回放校验，见 TODO P5）；
- 训练代码：`scripts/harmony/train-ranker.py`（产出固定 batch=128 的 ONNX）。

## 5. ONNX → .ms 转换链路

官方 MindSpore Lite Windows 包（2.11）**不自带匹配的 MinGW 运行时**，`converter_lite.exe`
启动会报 `0xC0000135`（缺 DLL）/ `0xC0000139`（entry point not found）。

解决：从 DevEco Studio 26 的 `plugins/codescanner/cpp-agent/release` 取兼容的
`libstdc++-6.dll / libgcc_s_seh-1.dll / libwinpthread-1.dll`，连同官方包内 `libssp-0.dll`
补齐到 converter 目录；再执行：

```powershell
pwsh scripts/harmony/convert-ranker.ps1
# converter_lite --fmk=ONNX --modelFile=ranker.onnx --outputFile=ranker --optimize=general
# benchmark: AvgRunTime ≈ 0.24 ms（PC CPU，batch=128）
```

产物：`ranker.ms` → 复制为 `harmony/entry/src/main/resources/rawfile/recommend/ranker_v1.ms`。

> 注意：converter/benchmark 依赖 .local 下工具包（不入库，见脚本头部下载地址）。

## 6. 端侧运行时

- `recommend/RecModel.ets`：
  - `loadModelFromBuffer` 从 rawfile 载入 `.ms`；
  - 画像 → 256 桶用户向量；目录/条目 → 256 桶 item 向量 + 质量/类目特征；
  - `scoreCards()` 按 128 一批推理，返回 0..1 分数；
- `RecService`：
  - 初始化时载入模型并**后台预热全量目录分数**（27 批，异步，不阻塞首屏）；
  - `pick()` 以模型分数为主排序分做加权采样；未打分的条目临时用统计分兜底并后台补分；
  - 模型缺失/加载失败 → 完整回退统计排序，保证可用（降级原则）。
- 设置页「推荐诊断」展示：模型版本、已打分数、事件数、库版本、包/schema 版本。

## 7. 版本与无损升级

| 数据 | 版本键 |
|---|---|
| 模型 | `rec_model_version`（当前 `v1`，模型文件 `ranker_v1.ms`） |
| 目录 | `rec_pack_version` / `rec_pack_schema` |
| 画像 | `rec_profile_schema`（RDB + preferences 双写） |
| 事件库 | `RdbStore.version` + `rec_store_schema` + `meta.schema_version` |
| 增量目录 | `rec_extra_schema` |

升级模型：新增 `ranker_v2.ms` + 版本号；旧模型文件保留一个版本作为回退。

## 8. 风险与后续

| 风险 | 对策 |
|---|---|
| 合成训练 AUC 有限 | 真实事件积累后做离线回放评估（P5），必要时扩充特征/容量 |
| 端侧推理稳定性 | 加载/推理失败立即回退统计排序；模型文件随包、版本化 |
| 首屏额外耗时 | 模型异步载入 + 后台预热分数；首屏先用统计分（仅启动瞬间） |
| 模型膨胀 | 当前 121 KB；后续若换大模型需评估包体/延迟 |
| 隐私 | 全部端侧计算，不上传画像/事件/模型输入 |

## 9. 结论

选择 **MindSpore Lite + 两塔 MLP 点击率模型（固定 batch 128，121 KB）** 作为端侧智能排序器；
事件层（RDB）与数据版本跟踪已先行落地，模型推理已接入首页推荐（模型分数为主、故障降级）；
后续按 TODO 做真实数据评估与模型迭代。
