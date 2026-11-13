import { deviceInfo, zlib } from '@kit.BasicServicesKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { JSON } from '@kit.ArkTS';
import { AppContext } from './AppContext';
import { CrashGuard, CrashRecord } from './CrashGuard';
import { Lines } from './Lines';
import { Prefs } from './Prefs';
import { UserPrefs } from '../state/UserPrefs';
import { Api } from './Api';
import { PerfMark } from '../utils/PerfMark';
import { PlaybackLog } from '../player/PlaybackLog';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGDiag';
/** 压缩包内文件名前缀。 */
const ZIP_PREFIX: string = 'hghub-diag-';

/**
 * 诊断日志导出：把本地全部排障信息打包成一个 zip，交给用户上传到 issue。
 *
 * 包内文件：
 *   README.txt        说明与隐私提示
 *   meta.json         应用版本 / 设备型号 / 系统版本 / 导出时间
 *   crash.json        崩溃记录（CrashGuard，最多 10 条）
 *   playback.log      播放链路诊断（最近 600 行，URL 已脱敏）
 *   analytics.json    本地统计计数（不含设备 UUID）
 *   settings.json     用户偏好快照
 *   network.json      线路列表与当前线路
 *   perf.json         启动耗时样本
 *
 * 隐私：不包含设备 UUID、账号、播放内容、搜索词、完整播放 URL。
 */
export class DiagExport {
  /** 导出并让用户选择保存位置；返回保存路径（用户取消返回空串）。 */
  static async exportZip(): Promise<string> {
    const context: common.UIAbilityContext = AppContext.abilityContext();
    const dir: string = context.cacheDir + '/diag';
    DiagExport.ensureDir(dir);

    const files: string[] = [];
    files.push(DiagExport.writeFile(dir, 'README.txt', DiagExport.readmeText()));
    files.push(DiagExport.writeFile(dir, 'meta.json', DiagExport.metaJson()));
    files.push(DiagExport.writeFile(dir, 'crash.json', DiagExport.crashJson()));
    files.push(DiagExport.writeFile(dir, 'playback.log', PlaybackLog.entries().join('\n')));
    files.push(DiagExport.writeFile(dir, 'analytics.json', DiagExport.analyticsJson()));
    files.push(DiagExport.writeFile(dir, 'settings.json', DiagExport.settingsJson()));
    files.push(DiagExport.writeFile(dir, 'network.json', DiagExport.networkJson()));
    files.push(DiagExport.writeFile(dir, 'perf.json', DiagExport.perfJson()));

    const stamp: string = DiagExport.stamp();
    const zipPath: string = dir + '/' + ZIP_PREFIX + stamp + '.zip';
    const options: zlib.Options = {
      level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION
    };
    await zlib.compressFiles(files, zipPath, options);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'zip ready');

    // 让用户选择保存位置（下载目录 / 文件管理器）。
    const saveOptions: picker.DocumentSaveOptions = {
      newFileNames: [ZIP_PREFIX + stamp + '.zip']
    };
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.save(saveOptions);
    if (uris === undefined || uris === null || uris.length === 0) {
      return '';
    }
    const target: string = uris[0];
    DiagExport.copyTo(zipPath, target);
    hilog.info(LOG_DOMAIN, LOG_TAG, 'zip saved');
    return target;
  }

  /* ── 内容组装 ─────────────────────────────────────── */

  private static readmeText(): string {
    const lines: string[] = [
      'HGhub Harmony 诊断日志包',
      '',
      '这个压缩包用于排查问题，请把它上传到项目 issue：',
      'https://github.com/stlin256/HGhub-Harmony/issues/new',
      '',
      '包内文件：',
      '  meta.json       应用版本 / 设备型号 / 系统版本 / 导出时间',
      '  crash.json      崩溃记录（最多 10 条）',
      '  playback.log    播放链路诊断（最近 600 行，URL 已脱敏）',
      '  analytics.json  本地统计计数（不含设备标识）',
      '  settings.json   用户偏好快照',
      '  network.json    线路列表与当前线路',
      '  perf.json       启动耗时样本',
      '',
      '隐私说明：',
      '  - 不包含设备唯一标识、账号、手机号、位置',
      '  - 不包含播放内容、搜索词、观看记录',
      '  - 播放 URL 只保留域名与路径首段，签名参数已去除',
      '',
      '上传前你可以自行解压检查内容。'
    ];
    return lines.join('\n');
  }

  private static metaJson(): string {
    const data: Record<string, Object> = {
      'app_version': Api.appVersion(),
      'exported_at': new Date().toISOString(),
      'device_model': DiagExport.safe(() => deviceInfo.productModel),
      'device_brand': DiagExport.safe(() => deviceInfo.brand),
      'os_full_name': DiagExport.safe(() => deviceInfo.osFullName),
      'sdk_api_version': DiagExport.safeNumber(() => deviceInfo.sdkApiVersion),
      'abi': DiagExport.safe(() => deviceInfo.abiList),
      'display_version': DiagExport.safe(() => deviceInfo.displayVersion)
    };
    return JSON.stringify(data, null, 2);
  }

  private static crashJson(): string {
    const list: CrashRecord[] = CrashGuard.records();
    return JSON.stringify(list, null, 2);
  }

  private static analyticsJson(): string {
    // 只导出计数器，不含 install_id / 任何标识。
    const keys: string[] = [
      'an_day', 'an_sessions', 'an_duration_sec', 'an_vv', 'an_crash',
      'an_play_fail', 'an_fail_network', 'an_fail_auth', 'an_fail_notfound',
      'an_fail_server', 'an_fail_other', 'an_sr_on', 'an_sr_supported',
      'an_quality_hd', 'an_quality_sd', 'an_play_complete',
      'an_page_home', 'an_page_search', 'an_page_category', 'an_page_profile', 'an_page_player',
      'an_startup_list'
    ];
    const data: Record<string, Object> = {};
    for (let i = 0; i < keys.length; i++) {
      const key: string = keys[i];
      if (key === 'an_startup_list') {
        data[key] = Prefs.getString(key, '[]');
      } else {
        data[key] = Prefs.getNumber(key, 0);
      }
    }
    data['analytics_enabled'] = UserPrefs.analytics();
    return JSON.stringify(data, null, 2);
  }

  private static settingsJson(): string {
    const data: Record<string, Object> = {
      'theme_mode': UserPrefs.themeMode(),
      'prefer_hevc': UserPrefs.preferHevc(),
      'super_resolution': UserPrefs.superResolution(),
      'multi_source': UserPrefs.multiSource(),
      'video_scale': UserPrefs.videoScale(),
      'mute_on_startup': UserPrefs.muteOnStartup(),
      'volume': UserPrefs.volume(),
      'reduce_motion': AppStorage.get<boolean>('hgReduceMotion') ?? false,
      'analytics': UserPrefs.analytics()
    };
    return JSON.stringify(data, null, 2);
  }

  private static networkJson(): string {
    const data: Record<string, Object> = {
      'current_line': Lines.current(),
      'fixed_lines': Lines.fixed(),
      'cached_mirrors': Lines.cachedMirrors()
    };
    return JSON.stringify(data, null, 2);
  }

  private static perfJson(): string {
    const data: Record<string, Object> = {
      'last_startup_ms': PerfMark.lastStartupMs(),
      'last_startup_at': PerfMark.lastStartupAt(),
      'startup_samples': Prefs.getString('an_startup_list', '[]')
    };
    return JSON.stringify(data, null, 2);
  }

  /* ── 文件工具 ─────────────────────────────────────── */

  private static ensureDir(dir: string): void {
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (err) {
      try {
        fs.mkdirSync(dir, true);
      } catch (err2) {
      }
    }
  }

  private static writeFile(dir: string, name: string, content: string): string {
    const path: string = dir + '/' + name;
    try {
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, content);
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'write failed ' + name);
    }
    return path;
  }

  private static copyTo(src: string, uri: string): void {
    try {
      const srcFile = fs.openSync(src, fs.OpenMode.READ_ONLY);
      try {
        const dstFile = fs.openSync(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.copyFileSync(srcFile.fd, dstFile.fd);
        } finally {
          fs.closeSync(dstFile);
        }
      } finally {
        fs.closeSync(srcFile);
      }
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'copy failed');
      throw err as Error;
    }
  }

  private static stamp(): string {
    const d: Date = new Date();
    const p2 = (n: number): string => (n < 10 ? '0' + n : '' + n);
    return '' + d.getFullYear() + p2(d.getMonth() + 1) + p2(d.getDate()) + '-' +
      p2(d.getHours()) + p2(d.getMinutes()) + p2(d.getSeconds());
  }

  private static safe(fn: () => string): string {
    try {
      const v: string = fn();
      return v !== undefined && v !== null ? v : '';
    } catch (err) {
      return '';
    }
  }

  private static safeNumber(fn: () => number): number {
    try {
      const v: number = fn();
      return v !== undefined && v !== null ? v : 0;
    } catch (err) {
      return 0;
    }
  }
}
