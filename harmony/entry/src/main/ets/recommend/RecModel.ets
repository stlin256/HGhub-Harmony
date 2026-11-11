import mindSporeLite from '@ohos.ai.mindSporeLite';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from '../services/AppContext';
import { VideoCard } from '../models/Types';
import { RecCatalog } from './RecCatalog';
import { RecProfile } from './RecProfile';
import { UserPrefs } from '../state/UserPrefs';
import { WatchProgress } from '../models/Types';

const BUCKETS: number = 256;
const ITEM_EXTRA: number = 9;
const TEXT_DIM: number = 128;
/** user / item 同维：256 标签桶 + 9 质量/类目特征 + 128 文本 3-gram（便于模型做按位交互）。 */
const FEAT_DIM: number = BUCKETS + ITEM_EXTRA + TEXT_DIM;
const USER_DIM: number = FEAT_DIM;
const ITEM_DIM: number = FEAT_DIM;
/** 文本特征在向量中的起始偏移（user 在同一位置，训练/推理口径一致）。 */
const TEXT_OFF: number = BUCKETS + ITEM_EXTRA;
const BATCH: number = 128;
const CATES: number = 4;

/**
 * 端侧排序模型（MindSpore Lite 推理）。
 *
 * 模型：两塔 MLP + 显式交互（user/item 各 393 维 = 256 标签桶 + 9 质量/类目特征 +
 * 128 文本 3-gram；两塔各 48 维 → 48 → base 分，另加 user*item 按位乘积的交互分），
 * 固定 batch=128；由 scripts/harmony/train-ranker.py 训练导出 ONNX，
 * scripts/harmony/convert-ranker.ps1 转成 .ms 后随包放入 rawfile/recommend/ranker_v2.ms。
 *
 * 说明：模型只做"打分"，候选与画像特征均由本地生成，不上传任何数据；模型缺失/加载失败时
 * 由 RecService 回退到现有统计排序，保证可用性（SPEC 降级原则）。
 */
export class RecModel {
  private static model: mindSporeLite.Model | null = null;
  private static ready: boolean = false;
  private static version: string = '';

  static isReady(): boolean {
    return RecModel.ready;
  }

  static modelVersion(): string {
    return RecModel.version;
  }

  static async init(): Promise<boolean> {
    if (RecModel.ready) {
      return true;
    }
    try {
      if (!AppContext.isReady()) {
        return false;
      }
      const bytes: Uint8Array = await AppContext.abilityContext()
        .resourceManager.getRawFileContent('recommend/ranker_v2.ms');
      const buffer: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      const context: mindSporeLite.Context = {
        target: ['cpu'],
        cpu: { threadNum: 1, precisionMode: 'preferred_fp32' }
      };
      const model: mindSporeLite.Model = await mindSporeLite.loadModelFromBuffer(buffer, context);
      RecModel.model = model;
      RecModel.version = 'v2';
      RecModel.ready = true;
      hilog.info(0x0000, 'HGRec', 'model %{public}s loaded', RecModel.version);
      return true;
    } catch (err) {
      RecModel.ready = false;
      hilog.warn(0x0000, 'HGRec', 'model load failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  /** 文本向量：标题+简介的字符 3-gram 哈希到 64 桶（与训练脚本同一口径）。 */
  private static textVector(title: string, desc: string): Float32Array {
    const vec: Float32Array = new Float32Array(TEXT_DIM);
    const text: string = (title + ' ' + desc).toLowerCase();
    if (text.length < 3) {
      return vec;
    }
    for (let i = 0; i + 2 < text.length; i++) {
      let h: number = 2166136261;
      for (let k = 0; k < 3; k++) {
        h ^= text.charCodeAt(i + k);
        h = (h * 16777619) >>> 0;
      }
      vec[h % TEXT_DIM] += 1;
    }
    let norm: number = 0;
    for (let i = 0; i < TEXT_DIM; i++) {
      norm += vec[i] * vec[i];
    }
    norm = Math.sqrt(norm);
    if (norm > 0) {
      for (let i = 0; i < TEXT_DIM; i++) {
        vec[i] /= norm;
      }
    }
    return vec;
  }

  /** 当前用户向量（画像 → 256 桶 + 2 统计特征 + 128 文本特征），与训练脚本同一口径。 */
  private static userVector(): Float32Array {
    const vec: Float32Array = new Float32Array(USER_DIM);
    let total: number = 0;
    const top = RecProfile.top(200);
    for (let i = 0; i < top.length; i++) {
      const w: number = Math.max(0, top[i].weight);
      const bucket: number = ((top[i].tag % BUCKETS) + BUCKETS) % BUCKETS;
      vec[bucket] += w;
      total += w;
    }
    if (total > 0) {
      for (let b = 0; b < BUCKETS; b++) {
        vec[b] /= total;
      }
    }
    vec[BUCKETS + 0] = total > 0 ? 1 : 0;
    vec[BUCKETS + 1] = Math.min(1, RecProfile.size() / 10);
    // 文本画像：收藏(+3)/点赞(+1.5)/历史(+1) 条目的文本向量加权平均。
    const textBase: number = TEXT_OFF;
    const favs: number[] = UserPrefs.favs();
    const likes: number[] = UserPrefs.likes();
    const history: WatchProgress[] = UserPrefs.history();
    for (let i = 0; i < favs.length; i++) {
      RecModel.addItemText(vec, textBase, favs[i], 3.0);
    }
    for (let i = 0; i < likes.length; i++) {
      RecModel.addItemText(vec, textBase, likes[i], 1.5);
    }
    for (let i = 0; i < history.length && i < 80; i++) {
      RecModel.addItemText(vec, textBase, history[i].id, 1.0);
    }
    let tnorm: number = 0;
    for (let i = 0; i < TEXT_DIM; i++) {
      tnorm += vec[textBase + i] * vec[textBase + i];
    }
    tnorm = Math.sqrt(tnorm);
    if (tnorm > 0) {
      for (let i = 0; i < TEXT_DIM; i++) {
        vec[textBase + i] /= tnorm;
      }
    }
    return vec;
  }

  /** 把某条目的文本向量按权重累加到用户文本特征。 */
  private static addItemText(vec: Float32Array, base: number, id: number, weight: number): void {
    const item = RecCatalog.get(id);
    if (item === null) {
      return;
    }
    const tv: Float32Array = RecModel.textVector(item.title, item.desc);
    for (let i = 0; i < TEXT_DIM; i++) {
      vec[base + i] += tv[i] * weight;
    }
  }

  /** 条目向量：标签桶 + 质量/类目特征 + 文本 3-gram（与训练脚本一致）。 */
  private static itemVector(card: VideoCard): Float32Array {
    const vec: Float32Array = new Float32Array(ITEM_DIM);
    const labels: number[] = RecCatalog.labelsOf(card.id);
    for (let i = 0; i < labels.length; i++) {
      const bucket: number = ((labels[i] % BUCKETS) + BUCKETS) % BUCKETS;
      vec[bucket] += 1;
    }
    const n: number = Math.max(1, labels.length);
    for (let b = 0; b < BUCKETS; b++) {
      vec[b] /= n;
    }
    const item = RecCatalog.get(card.id);
    const pop: number = item === null ? 0.5 : item.pop;
    const score: number = item === null ? 0 : item.score;
    const eps: number = item === null ? card.episode_count : item.eps;
    const finished: number = item === null ? 0 : item.finished;
    const cate: number = item === null ? -1 : item.cate;
    const lastEp: number = item === null ? 0 : item.lastEp;
    vec[BUCKETS + 0] = pop;
    vec[BUCKETS + 1] = RecModel.freshOf(lastEp, card);
    vec[BUCKETS + 2] = score / 10;
    vec[BUCKETS + 3] = Math.min(1, eps / 100);
    vec[BUCKETS + 4] = finished === 1 ? 1 : 0;
    if (cate >= 0 && cate < CATES) {
      vec[BUCKETS + 5 + cate] = 1;
    }
    const textVec: Float32Array = RecModel.textVector(card.title, item === null ? '' : item.desc);
    for (let i = 0; i < TEXT_DIM; i++) {
      vec[TEXT_OFF + i] = textVec[i];
    }
    return vec;
  }

  private static freshOf(lastEp: number, card: VideoCard): number {
    let t: number = lastEp > 0 ? lastEp : 0;
    if (t <= 0 && card.last_ep_at !== undefined && card.last_ep_at !== null) {
      t = Number(card.last_ep_at) || 0;
    }
    if (t <= 0) {
      return 0.5;
    }
    if (t < 1000000000000) {
      t = t * 1000;
    }
    const age: number = Date.now() - t;
    const week: number = 7 * 86400 * 1000;
    if (age <= 0) {
      return 1;
    }
    if (age >= week) {
      return 0;
    }
    return 1 - age / week;
  }

  /**
   * 批量打分：返回值与 cards 等长；模型未就绪或异常时返回 null（调用方回退）。
   * 一次最多 BATCH 条；超过则分批。
   */
  static async scoreCards(cards: VideoCard[]): Promise<number[] | null> {
    if (!RecModel.ready || RecModel.model === null || cards === undefined || cards === null) {
      return null;
    }
    const model = RecModel.model;
    try {
      const inputs: mindSporeLite.MSTensor[] = model.getInputs();
      if (inputs.length < 2) {
        return null;
      }
      const userInput: mindSporeLite.MSTensor = inputs[0];
      const itemInput: mindSporeLite.MSTensor = inputs[1];
      const userVec: Float32Array = RecModel.userVector();
      const out: number[] = [];
      for (let start = 0; start < cards.length; start += BATCH) {
        const userBatch: Float32Array = new Float32Array(BATCH * USER_DIM);
        const itemBatch: Float32Array = new Float32Array(BATCH * ITEM_DIM);
        for (let i = 0; i < BATCH; i++) {
          const idx: number = start + i;
          for (let d = 0; d < USER_DIM; d++) {
            userBatch[i * USER_DIM + d] = userVec[d];
          }
          if (idx < cards.length) {
            const vec: Float32Array = RecModel.itemVector(cards[idx]);
            for (let d = 0; d < ITEM_DIM; d++) {
              itemBatch[i * ITEM_DIM + d] = vec[d];
            }
          }
        }
        userInput.setData(userBatch.buffer);
        itemInput.setData(itemBatch.buffer);
        const outputs: mindSporeLite.MSTensor[] = await model.predict([userInput, itemInput]);
        if (outputs.length === 0) {
          return null;
        }
        const data: Float32Array = new Float32Array(outputs[0].getData());
        const take: number = Math.min(BATCH, cards.length - start);
        for (let i = 0; i < take; i++) {
          out.push(data[i]);
        }
      }
      return out;
    } catch (err) {
      return null;
    }
  }
}
