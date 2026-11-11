import mindSporeLite from '@ohos.ai.mindSporeLite';
import { util } from '@kit.ArkTS';
import { AppContext } from '../services/AppContext';
import { VideoCard } from '../models/Types';
import { RecCatalog } from './RecCatalog';
import { RecProfile } from './RecProfile';

const BUCKETS: number = 256;
const USER_EXTRA: number = 2;
const ITEM_EXTRA: number = 9;
const USER_DIM: number = BUCKETS + USER_EXTRA;
const ITEM_DIM: number = BUCKETS + ITEM_EXTRA;
const BATCH: number = 128;
const CATES: number = 4;

/**
 * 端侧排序模型（MindSpore Lite 推理）。
 *
 * 模型：两塔 MLP（user 258 维 / item 265 维 → 各 48 维 → 96 → 48 → sigmoid），
 * 固定 batch=128；由 scripts/harmony/train-ranker.py 训练导出 ONNX，
 * scripts/harmony/convert-ranker.ps1 转成 .ms 后随包放入 rawfile/recommend/ranker_v1.ms。
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
        .resourceManager.getRawFileContent('recommend/ranker_v1.ms');
      const buffer: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      const context: mindSporeLite.Context = {
        target: ['cpu'],
        cpu: { threadNum: 1, precisionMode: 'preferred_fp32' }
      };
      const model: mindSporeLite.Model = await mindSporeLite.loadModelFromBuffer(buffer, context);
      RecModel.model = model;
      RecModel.version = 'v1';
      RecModel.ready = true;
      return true;
    } catch (err) {
      RecModel.ready = false;
      return false;
    }
  }

  /** 当前用户向量（画像 → 256 桶 + 2 个统计特征），与训练脚本同一口径。 */
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
    return vec;
  }

  /** 条目向量：标签桶 + 质量/类目特征（与训练脚本一致）。 */
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
