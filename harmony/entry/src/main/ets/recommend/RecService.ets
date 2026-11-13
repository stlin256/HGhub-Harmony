import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from '../services/AppContext';
import { ConfigKey, ConfigRegistry } from '../services/ConfigRegistry';
import { Prefs } from '../services/Prefs';
import { VideoCard } from '../models/Types';
import { RecCatalog } from './RecCatalog';
import { RecDict } from './RecDict';
import { RecProfile } from './RecProfile';
import { RecDiagnostics, RecEvent, RecProfileEntry } from './RecTypes';
import { RecSync } from './RecSync';
import { RecMeta } from './RecMeta';
import { RecStore } from './RecStore';
import { RecModel } from './RecModel';

/**
 * 推荐门面：初始化 / 采样 / 事件 / 诊断 / 同步。
 *
 * 离线版"召回 + 排序"：候选来自随包目录池（+增量），
 * 画像权重决定倾向，加权随机采样保留"换一批"体感与 10% 探索。
 */
export class RecService {
  private static readonly KEY_ENABLED: string = 'rec_enabled';
  private static inited: boolean = false;
  private static initing: boolean = false;
  private static ready: boolean = false;
  private static syncKicked: boolean = false;
  /** 模型分数缓存（id → sigmoid 点击率）；模型未就绪时为空，pick 回退统计排序。 */
  private static modelScores: Map<number, number> = new Map<number, number>();
  private static scoring: boolean = false;

  static isReady(): boolean {
    return RecService.ready;
  }

  static enabled(): boolean {
    return Prefs.getBool(RecService.KEY_ENABLED, true);
  }

  static setEnabled(enabled: boolean): void {
    Prefs.putBool(RecService.KEY_ENABLED, enabled);
  }

  /** 首帧后调用；异步载入词典 + 目录 + 画像，并安排一次后台同步。 */
  static init(): void {
    if (RecService.inited || RecService.initing) {
      return;
    }
    RecService.initing = true;
    RecService.doInit().catch((err: Object) => {
      RecService.initing = false;
      RecService.ready = false;
    });
  }

  private static async doInit(): Promise<void> {
    try {
      if (!AppContext.isReady()) {
        RecService.initing = false;
        return;
      }
      RecMeta.ensure();
      let dictOk: boolean = false;
      try {
        const bytes: Uint8Array = await AppContext.abilityContext()
          .resourceManager.getRawFileContent('recommend/genre_dict.json');
        const text: string = new util.TextDecoder('utf-8').decodeToString(bytes);
        dictOk = RecDict.load(text);
      } catch (err) {
        dictOk = false;
      }
      const catalogOk: boolean = await RecCatalog.init();
      await RecProfile.loadAsync();
      // 端侧模型：加载 .ms 并预热全量目录打分（异步，不阻塞首屏）。
      const modelOk: boolean = await RecModel.init();
      hilog.info(0x0000, 'HGRec', 'init catalog=%{public}s model=%{public}s',
        catalogOk ? 'ok' : 'fail', modelOk ? 'ok' : 'fail');
      if (modelOk) {
        RecMeta.setModelVersion(RecModel.modelVersion());
        RecService.warmScores(RecCatalog.cards());
      }
      RecService.ready = catalogOk;
      RecService.initing = false;
      RecService.inited = true;
      if (RecService.enabled() && !RecService.syncKicked) {
        RecService.syncKicked = true;
        RecSync.kickoff();
      }
    } catch (err) {
      RecService.initing = false;
      RecService.ready = false;
      RecService.inited = true;
    }
  }

  /** 目录候选（随包全量，按需构建一次）。 */
  static catalogCards(): VideoCard[] {
    if (!RecService.ready) {
      return [];
    }
    return RecCatalog.cards();
  }

  static catalogCount(): number {
    return RecCatalog.count();
  }

  /**
   * 从候选池中按画像权重采样 n 条（无放回）。
   * 画像为空/未启用/未就绪时退化为随机洗牌，保证首页永远有内容。
   */
  static pick(pool: VideoCard[], n: number): VideoCard[] {
    if (pool === undefined || pool === null || pool.length === 0 || n <= 0) {
      return [];
    }
    if (!RecService.ready || !RecService.enabled() || RecProfile.size() === 0) {
      return RecService.shuffleTake(pool, n);
    }
    const count: number = Math.min(n, pool.length);
    const raw: number[] = [];
    let affMin: number = 1e9;
    let affMax: number = -1e9;
    for (let i = 0; i < pool.length; i++) {
      const aff: number = RecService.affinityOf(pool[i]);
      raw.push(aff);
      if (aff < affMin) {
        affMin = aff;
      }
      if (aff > affMax) {
        affMax = aff;
      }
    }
    const span: number = affMax - affMin;
    // 探索比例（recommend_explore_pct / 100，默认 10%）：分数里保留的随机扰动权重。
    const explore: number = ConfigRegistry.getNumber(ConfigKey.RECOMMEND_EXPLORE_PCT) / 100;
    const weights: number[] = [];
    const missing: VideoCard[] = [];
    for (let i = 0; i < pool.length; i++) {
      const card: VideoCard = pool[i];
      const modelScore: number | undefined = RecService.modelScores.get(card.id);
      if (modelScore === undefined || modelScore === null) {
        missing.push(card);
      }
      let score: number;
      if (modelScore !== undefined && modelScore !== null) {
        // 模型输出作为主排序分（0..1 点击率），只加极小抖动做探索。
        score = modelScore * (1 - explore) + Math.random() * explore;
      } else {
        // 模型分数尚未就绪（首次启动/新条目）：用统计分兜底，同时后台补分。
        const affNorm: number = span > 1e-6 ? (raw[i] - affMin) / span : 0.5;
        const pop: number = RecCatalog.popOf(card.id);
        const fresh: number = RecService.freshOf(card);
        score = 0.55 * affNorm + 0.25 * pop + 0.10 * fresh + explore * Math.random();
      }
      const w: number = Math.exp(score / 0.35);
      weights.push(w);
    }
    if (missing.length > 0) {
      RecService.warmScores(missing);
    }
    const out: VideoCard[] = [];
    const used: boolean[] = [];
    for (let k = 0; k < count; k++) {
      let total: number = 0;
      for (let i = 0; i < weights.length; i++) {
        if (!used[i]) {
          total += weights[i];
        }
      }
      if (total <= 0) {
        break;
      }
      let needle: number = Math.random() * total;
      let picked: number = -1;
      for (let i = 0; i < weights.length; i++) {
        if (used[i]) {
          continue;
        }
        needle -= weights[i];
        if (needle <= 0) {
          picked = i;
          break;
        }
      }
      if (picked < 0) {
        for (let i = weights.length - 1; i >= 0; i--) {
          if (!used[i]) {
            picked = i;
            break;
          }
        }
      }
      if (picked < 0) {
        break;
      }
      used[picked] = true;
      out.push(pool[picked]);
    }
    return out;
  }

  private static affinityOf(card: VideoCard): number {
    const labels: number[] = RecCatalog.labelsOf(card.id);
    let sum: number = 0;
    for (let i = 0; i < labels.length; i++) {
      sum += RecProfile.weightOf(labels[i]);
    }
    return sum;
  }

  /** 新鲜度：最近更新 7 天内=1，线性衰减；缺失 0.5。 */
  private static freshOf(card: VideoCard): number {
    let t: number = 0;
    if (card.last_ep_at !== undefined && card.last_ep_at !== null) {
      t = Number(card.last_ep_at) || 0;
    }
    if (t <= 0 && card.new_at !== undefined && card.new_at !== null) {
      t = Number(card.new_at) || 0;
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

  private static shuffleTake(pool: VideoCard[], n: number): VideoCard[] {
    const copy: VideoCard[] = pool.slice(0);
    for (let i = copy.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: VideoCard = copy[i];
      copy[i] = copy[j];
      copy[j] = tmp;
    }
    const out: VideoCard[] = [];
    for (let i = 0; i < copy.length && i < n; i++) {
      out.push(copy[i]);
    }
    return out;
  }

  static record(event: string, id: number): void {
    if (!RecService.ready || !RecService.enabled()) {
      return;
    }
    RecProfile.record(event, id);
  }

  /** 曝光事件（由列表可见性回调触发，调用方需去重）。 */
  static recordImpression(id: number): void {
    if (!RecService.ready || !RecService.enabled() || id <= 0) {
      return;
    }
    RecProfile.record(RecEvent.IMPRESSION, id);
  }

  /** 搜索信号：搜索词 → 标签 → 画像 + RDB 事件。 */
  static recordSearch(keyword: string): void {
    if (!RecService.ready || !RecService.enabled() || keyword.length === 0) {
      return;
    }
    const labels: number[] = RecDict.labelsFromText(keyword, '');
    if (labels.length > 0) {
      RecProfile.recordLabels(labels, 1.5, RecEvent.SEARCH);
    } else {
      RecStore.insertEvent(0, RecEvent.SEARCH, 0, 0, 0);
    }
  }

  /** 后台批量补模型分数（去重；同一时刻只跑一批）。 */
  private static warmScores(cards: VideoCard[]): void {
    if (RecService.scoring || !RecModel.isReady() || cards.length === 0) {
      return;
    }
    const todo: VideoCard[] = [];
    for (let i = 0; i < cards.length; i++) {
      if (!RecService.modelScores.has(cards[i].id)) {
        todo.push(cards[i]);
      }
    }
    if (todo.length === 0) {
      return;
    }
    RecService.scoring = true;
    RecModel.scoreCards(todo).then((scores: number[] | null) => {
      RecService.scoring = false;
      if (scores === null) {
        return;
      }
      for (let i = 0; i < todo.length && i < scores.length; i++) {
        RecService.modelScores.set(todo[i].id, scores[i]);
      }
      hilog.info(0x0000, 'HGRec', 'warm scores batch=%{public}d scored=%{public}d',
        todo.length, RecService.modelScores.size);
    }).catch((err: Object) => {
      RecService.scoring = false;
      hilog.warn(0x0000, 'HGRec', 'warm scores failed: %{public}s', JSON.stringify(err));
    });
  }

  /** 画像导出（JSON，含格式版本）。 */
  static exportProfileJson(): string {
    return RecProfile.exportJson();
  }

  /** 画像导入：成功后清空模型分数缓存并后台重算。 */
  static importProfileJson(text: string): boolean {
    const ok: boolean = RecProfile.importJson(text);
    if (ok) {
      RecService.refreshModelScores();
    }
    return ok;
  }

  static profileEntries(): number[][] {
    return RecProfile.entries();
  }

  /** 画像变化后重算模型分数（幂等，异步）。 */
  static refreshModelScores(): void {
    RecService.modelScores.clear();
    if (RecModel.isReady()) {
      RecService.warmScores(RecCatalog.cards());
    }
  }

  static recordClick(id: number): void {
    RecService.record(RecEvent.CLICK, id);
  }

  static recordPlayStart(id: number): void {
    RecService.record(RecEvent.PLAY_START, id);
  }

  static recordComplete(id: number): void {
    RecService.record(RecEvent.COMPLETE, id);
  }

  static recordFavorite(id: number, on: boolean): void {
    RecService.record(on ? RecEvent.FAVORITE : RecEvent.UNFAVORITE, id);
  }

  static syncNow(force: boolean): void {
    if (!RecService.enabled()) {
      return;
    }
    RecSync.run(force).catch((err: Object) => {
    });
  }

  static diagnostics(): RecDiagnostics {
    const top: RecProfileEntry[] = RecProfile.top(5);
    return {
      ready: RecService.ready,
      packVersion: RecCatalog.version(),
      dictVersion: RecDict.dictVersion(),
      schemaVersion: RecMeta.schema(),
      profileSchema: RecMeta.profileSchema(),
      extraSchema: RecMeta.EXTRA_SCHEMA,
      catalogCount: RecCatalog.count(),
      extraCount: RecCatalog.extraCount(),
      profileSize: RecProfile.size(),
      topTags: top,
      syncState: RecSync.status(),
      lastSyncAt: RecSync.lastSyncAt(),
      storeReady: RecStore.isReady(),
      storeVersion: RecStore.schemaVersion(),
      eventCount: RecStore.eventCountCached(),
      modelReady: RecModel.isReady(),
      modelVersion: RecMeta.modelVersion(),
      modelScored: RecService.modelScores.size
    };
  }

  static clearProfile(): void {
    RecProfile.clear();
    // 画像已清空：旧画像算出的模型分不再成立，丢弃缓存（pick 时按空画像/新画像懒重算）。
    RecService.modelScores.clear();
  }
}
