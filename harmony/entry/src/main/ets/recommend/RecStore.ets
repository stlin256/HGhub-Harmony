import { relationalStore } from '@kit.ArkData';
import { JSON } from '@kit.ArkTS';
import { AppContext } from '../services/AppContext';
import { Prefs } from '../services/Prefs';
import { RecMeta } from './RecMeta';

interface ProfileFile {
  v?: number;
  at: number;
  w: number[][];
}

/**
 * 推荐数据 RDB 存储（P1 事件层）。
 *
 * 表：items / events / profile / meta
 * 版本：RdbStore.version + meta('schema_version') 双记录；迁移只做兼容，不清空数据。
 *
 * 写入走单条 Promise 链（串行），避免并发写 RDB；读取在初始化时一次性载入内存。
 */
export class RecStore {
  static readonly SCHEMA_VERSION: number = 1;
  static readonly BUCKET_GLOBAL: number = 4;

  private static store: relationalStore.RdbStore | null = null;
  private static readyFlag: boolean = false;
  private static eventCount: number = 0;
  private static writeChain: Promise<void> = Promise.resolve();

  static isReady(): boolean {
    return RecStore.readyFlag;
  }

  static schemaVersion(): number {
    if (RecStore.store === null) {
      return 0;
    }
    return RecStore.store.version;
  }

  static eventCountCached(): number {
    return RecStore.eventCount;
  }

  /** 打开/创建数据库并执行 schema 迁移；失败返回 false（推荐降级为内存画像，不阻塞首页）。 */
  static async init(): Promise<boolean> {
    if (RecStore.readyFlag) {
      return true;
    }
    try {
      if (!AppContext.isReady()) {
        return false;
      }
      const config: relationalStore.StoreConfig = {
        name: 'recsys.db',
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(
        AppContext.abilityContext(), config);
      RecStore.store = store;
      const fromVersion: number = store.version > 0 ? store.version : 0;
      await RecStore.ensureSchema(store);
      if (fromVersion < RecStore.SCHEMA_VERSION) {
        await RecStore.migrate(store, fromVersion);
        store.version = RecStore.SCHEMA_VERSION;
      }
      await RecStore.setMeta('schema_version', String(RecStore.SCHEMA_VERSION));
      RecMeta.setStoreSchema(RecStore.SCHEMA_VERSION);
      RecStore.readyFlag = true;
      RecStore.eventCount = await RecStore.countEvents();
      return true;
    } catch (err) {
      RecStore.readyFlag = false;
      return false;
    }
  }

  private static async ensureSchema(store: relationalStore.RdbStore): Promise<void> {
    const ddl: string[] = [
      'CREATE TABLE IF NOT EXISTS items (' +
        'id INTEGER PRIMARY KEY, labels TEXT, pop REAL, cate INTEGER, eps INTEGER, updated INTEGER)',
      'CREATE TABLE IF NOT EXISTS events (' +
        'id INTEGER PRIMARY KEY AUTOINCREMENT, item_id INTEGER, type TEXT, weight REAL, ' +
        'ep INTEGER, progress REAL, bucket INTEGER, ts INTEGER)',
      'CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts)',
      'CREATE INDEX IF NOT EXISTS idx_events_item ON events(item_id)',
      'CREATE TABLE IF NOT EXISTS profile (' +
        'tag INTEGER NOT NULL, bucket INTEGER NOT NULL, weight REAL NOT NULL, updated INTEGER NOT NULL, ' +
        'PRIMARY KEY(tag, bucket))',
      'CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)'
    ];
    for (let i = 0; i < ddl.length; i++) {
      await store.executeSql(ddl[i]);
    }
  }

  /** 版本迁移：v0→v1 将 preferences 画像无损导入 RDB（备份原文本，不删旧 key）。 */
  private static async migrate(store: relationalStore.RdbStore, fromVersion: number): Promise<void> {
    const migrated: string = await RecStore.getMeta('migrated_prefs_profile');
    if (migrated === '1') {
      return;
    }
    try {
      const text: string = Prefs.getString('rec_profile_v1', '');
      if (text.length > 0) {
        RecMeta.backupText('profile_prefs', text, 'rdb_v' + fromVersion);
        const parsed = JSON.parse(text) as ProfileFile;
        const rows: number[][] = parsed.w === undefined || parsed.w === null ? [] : parsed.w;
        const now: number = Date.now();
        for (let i = 0; i < rows.length; i++) {
          const row: number[] = rows[i];
          if (row === undefined || row === null || row.length < 2) {
            continue;
          }
          await store.executeSql(
            'INSERT OR REPLACE INTO profile(tag, bucket, weight, updated) VALUES(?, ?, ?, ?)',
            [row[0], RecStore.BUCKET_GLOBAL, row[1], now]);
        }
      }
      await RecStore.setMeta('migrated_prefs_profile', '1');
    } catch (err) {
    }
  }

  static async getMeta(key: string): Promise<string> {
    const store = RecStore.store;
    if (store === null) {
      return '';
    }
    const rs: relationalStore.ResultSet = await store.querySql(
      'SELECT v FROM meta WHERE k = ?', [key]);
    let out: string = '';
    try {
      if (rs.goToNextRow()) {
        out = rs.getString(rs.getColumnIndex('v'));
      }
    } finally {
      rs.close();
    }
    return out;
  }

  static async setMeta(key: string, value: string): Promise<void> {
    const store = RecStore.store;
    if (store === null) {
      return;
    }
    await store.executeSql('INSERT OR REPLACE INTO meta(k, v) VALUES(?, ?)', [key, value]);
  }

  /** 读取全局画像（tag → weight）。 */
  static async loadProfile(): Promise<Map<number, number>> {
    const out: Map<number, number> = new Map<number, number>();
    const store = RecStore.store;
    if (store === null) {
      return out;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql(
        'SELECT tag, weight FROM profile WHERE bucket = ?', [RecStore.BUCKET_GLOBAL]);
      try {
        while (rs.goToNextRow()) {
          out.set(rs.getLong(rs.getColumnIndex('tag')), rs.getDouble(rs.getColumnIndex('weight')));
        }
      } finally {
        rs.close();
      }
    } catch (err) {
    }
    return out;
  }

  /** 串行排队写入画像权重（防抖由 RecProfile 负责）。 */
  static upsertProfile(tag: number, weight: number): void {
    if (!RecStore.readyFlag || RecStore.store === null) {
      return;
    }
    const now: number = Date.now();
    RecStore.enqueue(async (store: relationalStore.RdbStore) => {
      await store.executeSql(
        'INSERT OR REPLACE INTO profile(tag, bucket, weight, updated) VALUES(?, ?, ?, ?)',
        [tag, RecStore.BUCKET_GLOBAL, weight, now]);
    });
  }

  /** 追加行为事件（曝光/点击/播放/完播/收藏/搜索/快划）。 */
  static insertEvent(itemId: number, type: string, weight: number, ep: number, progress: number): void {
    if (!RecStore.readyFlag || RecStore.store === null) {
      return;
    }
    const now: number = Date.now();
    const bucket: number = RecStore.timeBucket(now);
    RecStore.eventCount++;
    RecStore.enqueue(async (store: relationalStore.RdbStore) => {
      await store.executeSql(
        'INSERT INTO events(item_id, type, weight, ep, progress, bucket, ts) VALUES(?, ?, ?, ?, ?, ?, ?)',
        [itemId, type, weight, ep, progress, bucket, now]);
    });
  }

  /** 时段桶：0 通勤早 / 1 午休 / 2 通勤晚 / 3 睡前 / 4 其他（与设计文档 §8.10 对齐）。 */
  static timeBucket(ts: number): number {
    const d: Date = new Date(ts);
    const h: number = d.getHours();
    if (h >= 7 && h < 10) {
      return 0;
    }
    if (h >= 11 && h < 14) {
      return 1;
    }
    if (h >= 17 && h < 20) {
      return 2;
    }
    if (h >= 21 || h < 1) {
      return 3;
    }
    return 4;
  }

  private static enqueue(fn: (store: relationalStore.RdbStore) => Promise<void>): void {
    RecStore.writeChain = RecStore.writeChain.then(async () => {
      const store = RecStore.store;
      if (store === null) {
        return;
      }
      try {
        await fn(store);
      } catch (err) {
      }
    }).catch(() => {
    });
  }

  static async countEvents(): Promise<number> {
    const store = RecStore.store;
    if (store === null) {
      return 0;
    }
    try {
      const rs: relationalStore.ResultSet = await store.querySql('SELECT COUNT(*) AS n FROM events');
      let n: number = 0;
      try {
        if (rs.goToNextRow()) {
          n = rs.getLong(rs.getColumnIndex('n'));
        }
      } finally {
        rs.close();
      }
      return n;
    } catch (err) {
      return 0;
    }
  }

  /** 导入画像：整表替换（版本字段由调用方校验后传入）。 */
  static replaceProfile(rows: number[][]): void {
    if (!RecStore.readyFlag || RecStore.store === null) {
      return;
    }
    const now: number = Date.now();
    RecStore.enqueue(async (store: relationalStore.RdbStore) => {
      await store.executeSql('DELETE FROM profile');
      for (let i = 0; i < rows.length; i++) {
        const row: number[] = rows[i];
        if (row === undefined || row === null || row.length < 2) {
          continue;
        }
        await store.executeSql(
          'INSERT OR REPLACE INTO profile(tag, bucket, weight, updated) VALUES(?, ?, ?, ?)',
          [row[0], RecStore.BUCKET_GLOBAL, row[1], now]);
      }
    });
  }

  static async clearAll(): Promise<void> {
    const store = RecStore.store;
    if (store === null) {
      return;
    }
    RecStore.enqueue(async (s: relationalStore.RdbStore) => {
      await s.executeSql('DELETE FROM events');
      await s.executeSql('DELETE FROM profile');
    });
    RecStore.eventCount = 0;
  }
}
