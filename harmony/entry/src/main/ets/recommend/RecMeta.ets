import { fileIo } from '@kit.CoreFileKit';
import { Prefs } from '../services/Prefs';
import { AppContext } from '../services/AppContext';

/**
 * 推荐数据系统的版本与迁移元信息。
 *
 * 目标：升级 App 时"无损过渡"——目录池（随包 + 增量）、画像、词典、同步状态
 * 各自带版本号，迁移只做增量兼容，不清空任何用户数据；迁移前自动备份。
 *
 * key 一览（preferences）：
 *   rec_meta_schema     推荐数据整体 schema（本文件管理）
 *   rec_pack_schema     随包目录 schema（catalog_full.json）
 *   rec_pack_version    随包目录内容版本（生成物 v 字段）
 *   rec_dict_version    标签词典版本
 *   rec_profile_schema  画像 schema（RecProfile 写入）
 *   rec_extra_schema    增量目录 schema（RecCatalog 写入）
 *   rec_sync_at         上次后台同步时间
 */
export class RecMeta {
  /** 推荐系统整体数据 schema：结构变化时 +1，并在此追加迁移分支。 */
  static readonly SCHEMA: number = 1;
  static readonly PACK_SCHEMA: number = 1;
  static readonly PROFILE_SCHEMA: number = 1;
  static readonly EXTRA_SCHEMA: number = 1;

  private static readonly K_SCHEMA: string = 'rec_meta_schema';
  private static readonly K_PACK_SCHEMA: string = 'rec_pack_schema';
  private static readonly K_PACK_VERSION: string = 'rec_pack_version';
  private static readonly K_DICT_VERSION: string = 'rec_dict_version';
  private static readonly K_PROFILE_SCHEMA: string = 'rec_profile_schema';
  private static readonly K_EXTRA_SCHEMA: string = 'rec_extra_schema';
  private static readonly K_STORE_SCHEMA: string = 'rec_store_schema';
  private static readonly K_MODEL_VERSION: string = 'rec_model_version';

  /** 启动时执行一次；老版本（无 key）视为 0，逐个迁移到当前版本。 */
  static ensure(): void {
    const schema: number = Prefs.getNumber(RecMeta.K_SCHEMA, 0);
    if (schema < RecMeta.SCHEMA) {
      // 未来 schema 升级：在此按版本顺序执行迁移，绝不删除用户画像/增量目录。
      Prefs.putNumber(RecMeta.K_SCHEMA, RecMeta.SCHEMA);
    }
  }

  static schema(): number {
    return Prefs.getNumber(RecMeta.K_SCHEMA, RecMeta.SCHEMA);
  }

  static packVersion(): string {
    return Prefs.getString(RecMeta.K_PACK_VERSION, '');
  }

  static setPackVersion(version: string): void {
    Prefs.putString(RecMeta.K_PACK_VERSION, version);
  }

  static dictVersion(): string {
    return Prefs.getString(RecMeta.K_DICT_VERSION, '');
  }

  static setDictVersion(version: string): void {
    Prefs.putString(RecMeta.K_DICT_VERSION, version);
  }

  static profileSchema(): number {
    return Prefs.getNumber(RecMeta.K_PROFILE_SCHEMA, 0);
  }

  static setProfileSchema(schema: number): void {
    Prefs.putNumber(RecMeta.K_PROFILE_SCHEMA, schema);
  }

  static setExtraSchema(schema: number): void {
    Prefs.putNumber(RecMeta.K_EXTRA_SCHEMA, schema);
  }

  static setStoreSchema(schema: number): void {
    Prefs.putNumber(RecMeta.K_STORE_SCHEMA, schema);
  }

  static storeSchema(): number {
    return Prefs.getNumber(RecMeta.K_STORE_SCHEMA, 0);
  }

  static setModelVersion(version: string): void {
    Prefs.putString(RecMeta.K_MODEL_VERSION, version);
  }

  static modelVersion(): string {
    return Prefs.getString(RecMeta.K_MODEL_VERSION, '');
  }

  /** 迁移前备份：把某个文件复制为 *.bak-<tag>（失败静默，不阻塞主流程）。 */
  static backupFile(path: string, tag: string): void {
    try {
      if (path.length === 0 || !fileIo.accessSync(path) || !AppContext.isReady()) {
        return;
      }
      const dir: string = AppContext.abilityContext().filesDir + '/recsys/backup';
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const name: string = path.substring(path.lastIndexOf('/') + 1);
      const dest: string = dir + '/' + name + '.' + tag + '.bak';
      fileIo.copyFileSync(path, dest);
    } catch (err) {
    }
  }

  /** 迁移前备份任意文本（如 preferences 里的画像 JSON）。 */
  static backupText(name: string, text: string, tag: string): void {
    try {
      if (text.length === 0 || !AppContext.isReady()) {
        return;
      }
      const dir: string = AppContext.abilityContext().filesDir + '/recsys/backup';
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const file: fileIo.File = fileIo.openSync(dir + '/' + name + '.' + tag + '.bak',
        fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
    } catch (err) {
    }
  }
}
