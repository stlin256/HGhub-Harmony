/**
 * 调试配置菜单（仅测试变体可达）。
 *
 * 用途（docs/harmony/REMOTE-CONFIG-SPEC.md §8.3）：
 * - 首页摇一摇进入（Index 里 IS_TEST_VARIANT 门禁），分组展示全部可下发项并支持逐项修改；
 * - 改动一律写 ConfigRegistry 本地覆盖层（setLocalOverride），可逐项/整体重置；
 * - 附带灰度/A-B 模拟、资源缓存查看、更新闸门模拟、线路切换、配置 JSON 导出等联调工具。
 *
 * 安全边界：
 * - 页面入口只在 test 变体注册（release 变体摇不出来），页面内部再做一次 IS_TEST_VARIANT 门禁；
 * - 只读写本地配置与本地缓存，不新增网络请求（「立即拉取」复用 RemoteConfig.fetch，
 *   「触发更新检查」复用 UpdateChecker.checkNow，均为既有链路）；
 * - 所有异常静默降级为 Toast，不崩溃、不影响启动。
 *
 * 隐私边界：
 * - 只展示本机配置与 install_id 的哈希分桶（bucket 0-99），不展示/不落盘原始 install_id；
 * - 导出的 JSON 只包含配置 key 与生效值，不含设备标识、播放内容或搜索词。
 */

import { bundleManager } from '@kit.AbilityKit';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { LineItem, UpdateInfo } from '../models/Types';
import { HgTopBar } from '../components/HgCommon';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgPressable } from '../components/HgPressable';
import { HgResponsive } from '../design/HgResponsive';
import { K_BOTTOM_INSET, K_CONTENT_W, K_DARK, K_WINDOW_H, K_WINDOW_W } from '../state/UserPrefs';
import { Api } from '../services/Api';
import { AppContext } from '../services/AppContext';
import { ConfigDef, ConfigKey, ConfigRegistry, ConfigValue } from '../services/ConfigRegistry';
import { Endpoints } from '../services/Endpoints';
import { Lines } from '../services/Lines';
import { Prefs } from '../services/Prefs';
import { RemoteConfig } from '../services/RemoteConfig';
import { WindowChrome } from '../services/WindowChrome';
import { abGroup, bucket } from '../services/Rollout';
import { UiBus } from '../services/UiBus';
import { UpdateChecker } from '../services/UpdateChecker';
import { IS_TEST_VARIANT, VARIANT_NAME } from '../utils/BuildVariant';
import { AppChannel } from '../utils/AppChannel';
import { DebugOverlay, DebugOverlayLine } from '../components/DebugOverlay';
import { hostOf } from '../utils/Format';

/** 调试用 Prefs 键：灰度 bucket 模拟（-1 / 不存在 = 不模拟）。 */
const DEBUG_BUCKET_KEY: string = 'debug_bucket_override';
/** 调试用 Prefs 键：A/B 组模拟（-1 / 不存在 = 不模拟）。 */
const DEBUG_AB_KEY: string = 'debug_ab_group_override';
/** 调试用 Prefs 键：模拟当前版本。 */
const DEBUG_SIM_CURRENT_KEY: string = 'debug_sim_current_version';
/** 调试用 Prefs 键：模拟 min_version。 */
const DEBUG_SIM_MIN_KEY: string = 'debug_sim_min_version';
/** 资源热更新缓存目录（与 P5 RemoteAssets 约定一致）。 */
const REMOTE_ASSETS_DIR: string = 'remote-assets';
/** 资源清单缓存键（与 P5 RemoteAssets 约定一致）。 */
const REMOTE_ASSETS_MANIFEST_KEY: string = 'remote_assets_manifest';
/** A/B 分组数。 */
const AB_GROUPS: number = 2;
/** 更新下载页（模拟弹窗用）。 */
const RELEASE_URL: string = 'https://github.com/stlin256/HGhub-Harmony/releases';
/** 文本编辑上限。 */
const MAX_EDIT_TEXT: number = 64;

/** 编辑弹窗上下文：调用方 open 前写入，弹窗 build 时读取。 */
class EditCopy {
  title: string = '';
  subtitle: string = '';
  current: string = '';
  /** true=数值编辑（校验数字 + min/max），false=文本编辑（只校验长度）。 */
  numeric: boolean = false;
  min: number = 0;
  max: number = 0;

  constructor(title: string, subtitle: string, current: string, numeric: boolean, min: number, max: number) {
    this.title = title;
    this.subtitle = subtitle;
    this.current = current;
    this.numeric = numeric;
    this.min = min;
    this.max = max;
  }
}

/** 资源缓存条目。 */
interface DebugAsset {
  name: string;
  size: number;
}

/** 导出 JSON 结构（只含配置与版本信息）。 */
interface DebugExport {
  variant: string;
  config_version: number;
  config_id: string;
  source: string;
  last_fetch_at: number;
  values: Record<string, ConfigValue>;
}

/** 两位补零。 */
function pad2(value: number): string {
  return value < 10 ? '0' + value : '' + value;
}

/** 时间戳 → HH:mm:ss（0 表示本次进程还没成功拉取过）。 */
function formatTime(ms: number): string {
  if (!(ms > 0)) {
    return '本次未拉取';
  }
  const date: Date = new Date(ms);
  return pad2(date.getHours()) + ':' + pad2(date.getMinutes()) + ':' + pad2(date.getSeconds());
}

/** 字节数 → 可读文本。 */
function formatBytes(bytes: number): string {
  if (!(bytes > 0)) {
    return '0 B';
  }
  if (bytes < 1024) {
    return bytes + ' B';
  }
  if (bytes < 1024 * 1024) {
    return (bytes / 1024).toFixed(1) + ' KB';
  }
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

/** 配置来源 → 中文说明。 */
function sourceText(source: string): string {
  if (source === 'remote') {
    return '远程下发（本次拉取）';
  }
  if (source === 'cache') {
    return '本地缓存';
  }
  return '编译期默认值';
}

/** 数值/文本编辑弹窗（自绘，完全按 App 主题 token）。 */
@CustomDialog
export struct DebugEditDialog {
  @StorageProp(K_DARK) dark: boolean = true;
  controller?: CustomDialogController;
  copyOf: () => EditCopy = () => new EditCopy('', '', '', false, 0, 0);
  /** 校验通过后回调（弹窗已关闭）。 */
  onConfirm: (text: string) => void = () => {};
  @State text: string = '';
  @State error: string = '';

  aboutToAppear(): void {
    this.text = this.copyOf().current;
  }

  private confirm(): void {
    const copy: EditCopy = this.copyOf();
    const value: string = this.text.trim();
    if (value.length === 0) {
      this.error = '不能为空';
      return;
    }
    if (copy.numeric) {
      const numberValue: number = Number(value);
      if (isNaN(numberValue)) {
        this.error = '请输入数字';
        return;
      }
      if (numberValue < copy.min || numberValue > copy.max) {
        this.error = '超出范围 ' + copy.min + ' ~ ' + copy.max;
        return;
      }
    } else if (value.length > MAX_EDIT_TEXT) {
      this.error = '最多 ' + MAX_EDIT_TEXT + ' 字';
      return;
    }
    try {
      this.controller?.close();
    } catch (err) {
    }
    this.onConfirm(value);
  }

  build() {
    Column({ space: HgSpace.m }) {
      Text(this.copyOf().title)
        .width('100%')
        .fontSize(HgFont.section)
        .fontWeight(HgFont.weightBold)
        .fontColor(HgColor.textPrimary(this.dark))
      Text(this.copyOf().subtitle)
        .width('100%')
        .fontSize(HgFont.micro)
        .fontColor(HgColor.textTertiary(this.dark))
        .maxLines(2)
      TextInput({ text: this.text, placeholder: '输入新值' })
        .width('100%')
        .height(HgSize.control)
        .fontSize(HgFont.body)
        .fontColor(HgColor.textPrimary(this.dark))
        .backgroundColor(HgColor.surface2(this.dark))
        .borderRadius(HgRadius.control)
        .onChange((value: string) => {
          this.text = value;
          this.error = '';
        })
      if (this.error.length > 0) {
        Text(this.error)
          .width('100%')
          .fontSize(HgFont.micro)
          .fontColor(HgColor.danger(this.dark))
      }
      Row({ space: HgSpace.s }) {
        Button('取消')
          .layoutWeight(1)
          .height(HgSize.secondaryAction)
          .fontSize(HgFont.body)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.onSecondary(this.dark))
          .backgroundColor(HgColor.secondaryFill(this.dark))
          .borderRadius(HgRadius.chip)
          .accessibilityText($r('app.string.ui_4d0b4688'))
          .onClick(() => {
            try {
              this.controller?.close();
            } catch (err) {
            }
          })
        Button('确定')
          .layoutWeight(1)
          .height(HgSize.secondaryAction)
          .fontSize(HgFont.body)
          .fontWeight(HgFont.weightMedium)
          .fontColor(HgColor.onAccent(this.dark))
          .backgroundColor(HgColor.accent(this.dark))
          .borderRadius(HgRadius.chip)
          .accessibilityText($r('app.string.ui_f526c899'))
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
      .margin({ top: HgSpace.xs })
    }
    .width(320)
    .padding({ left: HgSpace.xl, right: HgSpace.xl, top: HgSpace.xxl, bottom: HgSpace.xl })
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.surface)
    .border({ width: 1, color: HgColor.hairline(this.dark) })
    .shadow({ radius: 24, color: HgColor.shadowElev3, offsetX: 0, offsetY: 8 })
    .alignItems(HorizontalAlign.Start)
    .accessibilityText(this.copyOf().title)
  }
}

/**
 * 调试配置菜单页。
 * 数据全部来自 ConfigRegistry / RemoteConfig / Prefs / Lines，本页只做展示与本地覆盖写入。
 */
@Component
export struct DebugConfigPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：宽屏时内容限宽 760vp 居中（与设置页一致）。 */
  @StorageProp(K_CONTENT_W) windowW: number = 400;
  @StorageProp(K_WINDOW_W) winW: number = 400;
  @StorageProp(K_WINDOW_H) winH: number = 800;

  /** 刷新代次：作为 ForEach key 的一部分，保证改值后行组件重建并读到最新生效值。 */
  @State revision: number = 0;
  /** 功能开关（17 项：allowUser=false 的 boolean）。 */
  @State flagDefs: ConfigDef[] = [];
  /** 用户偏好（9 项：allowUser=true）。 */
  @State prefDefs: ConfigDef[] = [];
  /** 阈值（27 项：allowUser=false 的 number）。 */
  @State numberDefs: ConfigDef[] = [];
  /* ── 当前配置 ── */
  @State infoVersion: number = 0;
  @State infoConfigId: string = '';
  @State infoSource: string = '';
  @State infoFetchAt: string = '';
  @State infoSig: string = '';
  /* ── 灰度 / A-B ── */
  @State realBucket: number = 0;
  @State bucketOverride: number = -1;
  @State realAb: number = 0;
  @State abOverride: number = -1;
  /* ── 资源 / 网络 / 更新闸门 ── */
  @State assets: DebugAsset[] = [];
  @State lines: LineItem[] = [];
  @State simCurrent: string = '';
  @State simMin: string = '';
  /* ── 搜索 / 服务端 / 版本信息 / 悬浮窗 ── */
  @State query: string = '';
  @State serverBase: string = '';
  @State serverHost: string = '';
  @State serverKeyReady: boolean = false;
  @State caReady: boolean = false;
  @State appVersion: string = '';
  @State appVersionCode: string = '';
  @State apiVersion: string = '';
  @State deviceModel: string = '';

  /** 当前编辑目标：kind 决定写回位置，key 为 ConfigRegistry key（数值编辑时使用）。 */
  private editKind: string = '';
  private editKey: string = '';
  private editCopy: EditCopy = new EditCopy('', '', '', false, 0, 0);
  private editController: CustomDialogController = new CustomDialogController({
    builder: DebugEditDialog({
      copyOf: (): EditCopy => this.editCopy,
      onConfirm: (text: string): void => {
        this.applyEdit(text);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  aboutToAppear(): void {
    this.refresh();
    // 页面级兜底：重新下发导航栏 canvas 色，避免新页面/主题切换后底部导航区露白。
    WindowChrome.forceSyncSystemBarColors(this.dark);
  }

  /** 宽屏内容左右额外留白：返回 (W - FORM_MAX)/2，窄屏返回 0。 */
  private pagePad(): number {
    let gutter: number = 0;
    if (this.windowW > HgResponsive.FORM_MAX) {
      gutter = (this.windowW - HgResponsive.FORM_MAX) / 2;
    }
    return HgSpace.pageInset + gutter;
  }

  /** 重新读取全部状态：ConfigRegistry 分层值 / 远程配置元信息 / 灰度 / 资源 / 线路。 */
  private refresh(): void {
    const defs: ConfigDef[] = ConfigRegistry.allDefs();
    const flags: ConfigDef[] = [];
    const prefs: ConfigDef[] = [];
    const numbers: ConfigDef[] = [];
    for (let i = 0; i < defs.length; i++) {
      const def: ConfigDef = defs[i];
      if (def.allowUser) {
        prefs.push(def);
      } else if (def.type === 'boolean') {
        flags.push(def);
      } else if (def.type === 'number') {
        numbers.push(def);
      }
    }
    this.flagDefs = flags;
    this.prefDefs = prefs;
    this.numberDefs = numbers;
    this.infoVersion = RemoteConfig.currentVersion();
    this.infoConfigId = RemoteConfig.configId();
    this.infoSource = sourceText(RemoteConfig.source());
    this.infoFetchAt = formatTime(RemoteConfig.lastFetchAt());
    this.infoSig = RemoteConfig.source() === 'default' ?
      '未拉取或校验失败（整包丢弃）' : '通过（失败整包丢弃）';
    const installId: string = Prefs.getString('install_id', '');
    this.realBucket = bucket(installId);
    this.bucketOverride = Prefs.getNumber(DEBUG_BUCKET_KEY, -1);
    this.realAb = abGroup(installId, AB_GROUPS);
    this.abOverride = Prefs.getNumber(DEBUG_AB_KEY, -1);
    this.simCurrent = Prefs.getString(DEBUG_SIM_CURRENT_KEY, '');
    this.simMin = Prefs.getString(DEBUG_SIM_MIN_KEY, '');
    this.serverBase = Endpoints.baseUrl();
    this.serverHost = Endpoints.host();
    this.serverKeyReady = Endpoints.clientKey().length > 0;
    this.caReady = Endpoints.caPath().length > 0;
    this.appVersion = Api.appVersion();
    try {
      const bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersionCode = String(bundleInfo.versionCode);
    } catch (err) {
      this.appVersionCode = '—';
    }
    try {
      this.apiVersion = String(deviceInfo.sdkApiVersion);
      this.deviceModel = deviceInfo.productModel !== undefined && deviceInfo.productModel !== null ?
        String(deviceInfo.productModel) : '—';
    } catch (err) {
      this.apiVersion = '—';
      this.deviceModel = '—';
    }
    this.loadAssets();
    this.loadLines();
    // 代次自增：ForEach 的 key 变化 → 行组件重建，读到最新生效值。
    this.revision = this.revision + 1;
  }

  /* ── 搜索：按 key / 说明过滤配置项 ─────────────────── */

  private matches(def: ConfigDef): boolean {
    if (this.query.length === 0) {
      return true;
    }
    const needle: string = this.query.toLowerCase();
    return def.key.toLowerCase().indexOf(needle) >= 0 || def.desc.toLowerCase().indexOf(needle) >= 0;
  }

  private filtered(defs: ConfigDef[]): ConfigDef[] {
    const out: ConfigDef[] = [];
    for (let i = 0; i < defs.length; i++) {
      if (this.matches(defs[i])) {
        out.push(defs[i]);
      }
    }
    return out;
  }

  private matchCount(): number {
    return this.filtered(this.flagDefs).length + this.filtered(this.prefDefs).length +
      this.filtered(this.numberDefs).length;
  }

  /** 搜索命中的全部配置项（布尔/数值/枚举），用于独立结果卡。 */
  private searchResults(): ConfigDef[] {
    const out: ConfigDef[] = [];
    const groups: ConfigDef[][] = [this.flagDefs, this.prefDefs, this.numberDefs];
    for (let g = 0; g < groups.length; g++) {
      const list: ConfigDef[] = this.filtered(groups[g]);
      for (let i = 0; i < list.length; i++) {
        out.push(list[i]);
      }
    }
    return out;
  }

  @Builder
  SearchResultsContent() {
    if (this.searchResults().length === 0) {
      this.InfoRow('没有匹配项', this.query)
    } else {
      ForEach(this.searchResults(), (def: ConfigDef) => {
        if (def.type === 'boolean') {
          this.SwitchRow(def)
        } else if (def.type === 'number') {
          this.NumberRow(def)
        } else {
          this.CycleRow(def)
        }
      }, (def: ConfigDef) => 'search-' + def.key + '-' + this.revision)
    }
  }
  /* ── 配置读写 ─────────────────────────────────────── */

  private applyBool(key: string, value: boolean): void {
    if (!ConfigRegistry.setLocalOverride(key, value)) {
      UiBus.toast('该配置项不接受该值');
      return;
    }
    this.refresh();
  }

  private resetOverride(key: string): void {
    ConfigRegistry.clearLocalOverride(key);
    this.refresh();
    UiBus.toastOk('已重置 ' + key);
  }

  private clearAllOverrides(): void {
    ConfigRegistry.clearLocalOverride();
    this.refresh();
    UiBus.toastOk('已清除全部本地覆盖');
  }

  /** 字符串枚举项：点击循环切换到下一个可选值。 */
  private cycleString(def: ConfigDef): void {
    const options: string[] = def.options ?? [];
    if (options.length === 0) {
      UiBus.toast('该配置项没有可选值');
      return;
    }
    const current: string = ConfigRegistry.getString(def.key);
    let next: string = options[0];
    for (let i = 0; i < options.length; i++) {
      if (options[i] === current) {
        next = options[(i + 1) % options.length];
        break;
      }
    }
    if (!ConfigRegistry.setLocalOverride(def.key, next)) {
      UiBus.toast('该配置项不接受该值');
      return;
    }
    this.refresh();
    UiBus.toastOk(def.key + ' → ' + next);
  }

  /** 打开数值编辑弹窗（阈值 / 用户偏好数值项）。 */
  private openNumberEditor(def: ConfigDef): void {
    this.editKind = 'number';
    this.editKey = def.key;
    this.editCopy = new EditCopy(def.desc,
      def.key + '（范围 ' + def.min + ' ~ ' + def.max + '）',
      String(ConfigRegistry.getNumber(def.key)), true, def.min, def.max);
    this.editController.open();
  }

  /** 打开调试数值编辑弹窗（bucket / A-B 组）。 */
  private openDebugNumber(kind: string, title: string, subtitle: string,
    current: number, min: number, max: number): void {
    this.editKind = kind;
    this.editKey = '';
    this.editCopy = new EditCopy(title, subtitle, String(current), true, min, max);
    this.editController.open();
  }

  /** 打开文本编辑弹窗（模拟版本号）。 */
  private openTextEditor(kind: string, title: string, subtitle: string, current: string): void {
    this.editKind = kind;
    this.editKey = '';
    this.editCopy = new EditCopy(title, subtitle, current, false, 0, 0);
    this.editController.open();
  }

  /** 编辑弹窗确认：按 kind 写回 ConfigRegistry 本地覆盖或调试 Prefs 键。 */
  private applyEdit(text: string): void {
    const kind: string = this.editKind;
    if (kind === 'number') {
      const value: number = Number(text);
      if (isNaN(value)) {
        UiBus.toast('请输入数字');
        return;
      }
      if (!ConfigRegistry.setLocalOverride(this.editKey, value)) {
        UiBus.toast('超出允许范围');
        return;
      }
      this.refresh();
      UiBus.toastOk('已写入本地覆盖：' + this.editKey + ' = ' + value);
      return;
    }
    if (kind === 'bucket') {
      const value: number = Math.floor(Number(text));
      Prefs.putNumber(DEBUG_BUCKET_KEY, value);
      this.refresh();
      UiBus.toastOk('已设置模拟 bucket = ' + value);
      return;
    }
    if (kind === 'ab') {
      const value: number = Math.floor(Number(text));
      Prefs.putNumber(DEBUG_AB_KEY, value);
      this.refresh();
      UiBus.toastOk('已设置模拟 A/B 组 = ' + value);
      return;
    }
    if (kind === 'sim_current') {
      Prefs.putString(DEBUG_SIM_CURRENT_KEY, text);
      this.refresh();
      UiBus.toastOk('已设置模拟当前版本 = ' + text);
      return;
    }
    if (kind === 'sim_min') {
      Prefs.putString(DEBUG_SIM_MIN_KEY, text);
      this.refresh();
      UiBus.toastOk('已设置模拟 min_version = ' + text);
    }
  }

  /* ── 远程配置 ─────────────────────────────────────── */

  private async fetchConfig(): Promise<void> {
    UiBus.toast('正在拉取远程配置…');
    try {
      await RemoteConfig.fetch();
    } catch (err) {
    }
    this.refresh();
    UiBus.toastOk('拉取结束：' + this.infoSource +
      (this.infoVersion > 0 ? ' v' + this.infoVersion : ''));
  }

  private clearConfigCache(): void {
    try {
      RemoteConfig.clearCache();
    } catch (err) {
    }
    this.refresh();
    UiBus.toastOk('已清空配置缓存，回落编译期默认值');
  }

  /* ── 灰度 / A-B 模拟 ─────────────────────────────── */

  private openBucketEditor(): void {
    const current: number = this.bucketOverride >= 0 ? this.bucketOverride : this.realBucket;
    this.openDebugNumber('bucket', '手动指定 bucket',
      '0-99；写入本地调试键，供 P4 更新闸门 / P7 面板联调（真实下发仍用真实 bucket）',
      current, 0, 99);
  }

  private clearBucket(): void {
    Prefs.remove(DEBUG_BUCKET_KEY);
    this.refresh();
    UiBus.toastOk('已清除 bucket 模拟');
  }

  private openAbEditor(): void {
    const current: number = this.abOverride >= 0 ? this.abOverride : this.realAb;
    this.openDebugNumber('ab', '手动指定 A/B 组',
      '0 = A 组 / 1 = B 组；写入本地调试键，供 A/B 实验联调',
      current, 0, AB_GROUPS - 1);
  }

  private clearAb(): void {
    Prefs.remove(DEBUG_AB_KEY);
    this.refresh();
    UiBus.toastOk('已清除 A/B 模拟');
  }

  /* ── 资源缓存 ─────────────────────────────────────── */

  /** 资源缓存目录（P5 RemoteAssets 落盘位置）。 */
  private assetsDir(): string {
    try {
      if (!AppContext.isReady()) {
        return '';
      }
      return AppContext.abilityContext().filesDir + '/' + REMOTE_ASSETS_DIR;
    } catch (err) {
      return '';
    }
  }

  private loadAssets(): void {
    const out: DebugAsset[] = [];
    try {
      const dir: string = this.assetsDir();
      if (dir.length > 0 && fileIo.accessSync(dir)) {
        const names: string[] = fileIo.listFileSync(dir);
        for (let i = 0; i < names.length; i++) {
          let size: number = 0;
          try {
            size = fileIo.statSync(dir + '/' + names[i]).size;
          } catch (err) {
          }
          const asset: DebugAsset = { name: names[i], size: size };
          out.push(asset);
        }
      }
    } catch (err) {
    }
    this.assets = out;
  }

  private loadLines(): void {
    const items: LineItem[] = [];
    const seen: Set<string> = new Set<string>();
    const fixed: LineItem[] = Lines.fixed();
    const mirrors: LineItem[] = Lines.cachedMirrors();
    for (let i = 0; i < fixed.length; i++) {
      if (!seen.has(fixed[i].url)) {
        seen.add(fixed[i].url);
        items.push(fixed[i]);
      }
    }
    for (let i = 0; i < mirrors.length; i++) {
      if (!seen.has(mirrors[i].url)) {
        seen.add(mirrors[i].url);
        items.push(mirrors[i]);
      }
    }
    this.lines = items;
  }

  private refreshAssets(): void {
    try {
      Prefs.remove(REMOTE_ASSETS_MANIFEST_KEY);
    } catch (err) {
    }
    this.loadAssets();
    UiBus.toastOk('已清空资源清单缓存，下次启动重新拉取');
  }

  private clearAssets(): void {
    try {
      const dir: string = this.assetsDir();
      if (dir.length > 0 && fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (err) {
    }
    this.loadAssets();
    UiBus.toastOk('已清空已缓存资源');
  }

  /* ── 更新闸门 ─────────────────────────────────────── */

  private async triggerUpdateCheck(): Promise<void> {
    UiBus.toast('正在检查更新…');
    try {
      const info: UpdateInfo = await UpdateChecker.checkNow();
      if (info.has_update) {
        UiBus.showUpdate(info);
        UiBus.toastOk('发现新版本 v' + info.latest);
      } else {
        UiBus.toastOk('已是最新版本 v' + info.current);
      }
    } catch (err) {
      UiBus.toast('检查失败（网络异常或接口不可用）');
    }
  }

  /** 不联网：用模拟版本直接构造 UpdateInfo 弹窗，验证强制更新 UI。 */
  private simulateUpdate(): void {
    const current: string = this.simCurrent.length > 0 ? this.simCurrent : Api.appVersion();
    const latest: string = this.simMin.length > 0 ? this.simMin : '9.9.9';
    const info: UpdateInfo = {
      current: current,
      latest: latest,
      has_update: true,
      url: RELEASE_URL,
      notes: '调试菜单模拟的更新弹窗（模拟当前版本 ' + current + '，模拟 min_version ' +
        (this.simMin.length > 0 ? this.simMin : '未设置') + '）'
    };
    UiBus.showUpdate(info);
    UiBus.toastOk('已触发模拟更新弹窗');
  }

  private clearSim(): void {
    Prefs.remove(DEBUG_SIM_CURRENT_KEY);
    Prefs.remove(DEBUG_SIM_MIN_KEY);
    this.refresh();
    UiBus.toastOk('已清除模拟版本');
  }

  /* ── 网络 ─────────────────────────────────────────── */

  private switchLine(url: string): void {
    try {
      const next: string = Lines.setBase(url);
      this.refresh();
      UiBus.toastOk('已切换线路：' + hostOf(next));
    } catch (err) {
      UiBus.toast('切换失败（线路不在白名单或地址无效）');
    }
  }

  /* ── 导出 ─────────────────────────────────────────── */

  private copyText(text: string, okMessage: string): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        UiBus.toastOk(okMessage);
      }).catch(() => {
        UiBus.toast('复制失败');
      });
    } catch (err) {
      UiBus.toast('复制失败');
    }
  }

  private copyConfigJson(): void {
    try {
      const payload: DebugExport = {
        variant: VARIANT_NAME,
        config_version: RemoteConfig.currentVersion(),
        config_id: RemoteConfig.configId(),
        source: RemoteConfig.source(),
        last_fetch_at: RemoteConfig.lastFetchAt(),
        values: ConfigRegistry.snapshot()
      };
      this.copyText(JSON.stringify(payload), '当前生效配置 JSON 已复制');
    } catch (err) {
      UiBus.toast('导出失败');
    }
  }

  private copyDefsJson(): void {
    try {
      this.copyText(JSON.stringify(ConfigRegistry.allDefs()), '注册表定义 JSON 已复制');
    } catch (err) {
      UiBus.toast('导出失败');
    }
  }

  /* ── 动作分发（@Builder 参数只传字符串 id，避免函数参数）── */

  private runAction(id: string): void {
    if (id === 'fetch') {
      this.fetchConfig();
      return;
    }
    if (id === 'refresh') {
      this.refresh();
      UiBus.toastOk('已刷新');
      return;
    }
    if (id === 'clear_overrides') {
      this.clearAllOverrides();
      return;
    }
    if (id === 'set_bucket') {
      this.openBucketEditor();
      return;
    }
    if (id === 'clear_bucket') {
      this.clearBucket();
      return;
    }
    if (id === 'set_ab') {
      this.openAbEditor();
      return;
    }
    if (id === 'clear_ab') {
      this.clearAb();
      return;
    }
    if (id === 'refresh_assets') {
      this.refreshAssets();
      return;
    }
    if (id === 'clear_assets') {
      this.clearAssets();
      return;
    }
    if (id === 'set_sim_current') {
      this.openTextEditor('sim_current', '模拟当前版本',
        '仅本地记录，用于构造更新弹窗；不改变真实包版本', this.simCurrent);
      return;
    }
    if (id === 'set_sim_min') {
      this.openTextEditor('sim_min', '模拟 min_version',
        '仅本地记录，用于构造强制更新弹窗', this.simMin);
      return;
    }
    if (id === 'check_update') {
      this.triggerUpdateCheck();
      return;
    }
    if (id === 'sim_update') {
      this.simulateUpdate();
      return;
    }
    if (id === 'clear_sim') {
      this.clearSim();
      return;
    }
    if (id === 'clear_config_cache') {
      this.clearConfigCache();
      return;
    }
    if (id === 'copy_config') {
      this.copyConfigJson();
      return;
    }
    if (id === 'copy_defs') {
      this.copyDefsJson();
    }
  }

  /* ── 通用渲染件 ───────────────────────────────────── */

  @Builder
  SectionTitle(title: string) {
    Text(title)
      .width('100%')
      .fontSize(HgFont.micro)
      .fontColor(HgColor.textTertiary(this.dark))
      .padding({ left: HgSpace.s, top: HgSpace.xl, bottom: HgSpace.s })
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row({ space: HgSpace.m }) {
      Text(label)
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.textSecondary(this.dark))
      Text(value)
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.textPrimary(this.dark))
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: HgSpace.s, bottom: HgSpace.s })
    .accessibilityText(label + '：' + value)
  }

  @Builder
  ActionRow(title: string, subtitle: string, actionLabel: string, tone: string, actionId: string) {
    HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
      Row({ space: HgSpace.m }) {
        Column({ space: 2 }) {
          Text(title)
            .fontSize(HgFont.secondary)
            .fontColor(HgColor.textPrimary(this.dark))
            .maxLines(2)
          Text(subtitle)
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(2)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(actionLabel)
          .fontSize(HgFont.caption)
          .fontColor(tone === 'danger' ? HgColor.danger(this.dark) : HgColor.accent(this.dark))
          .height(HgSize.hitTarget)
          .padding({ left: HgSpace.s })
          .accessibilityText(title)
          .onClick(() => {
            this.runAction(actionId);
          })
      }
      .width('100%')
      .constraintSize({ minHeight: HgSize.listRowDouble })
    }
  }

  @Builder
  SwitchRow(def: ConfigDef) {
    Row({ space: HgSpace.m }) {
      Column({ space: 2 }) {
        Text(def.desc)
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(2)
        Text(def.key + (ConfigRegistry.hasLocalOverride(def.key) ? ' · 已覆盖' : ''))
          .fontSize(HgFont.micro)
          .fontColor(ConfigRegistry.hasLocalOverride(def.key) ? HgColor.warning(this.dark) :
            HgColor.textTertiary(this.dark))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (ConfigRegistry.hasLocalOverride(def.key)) {
        Text('重置')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
          .height(HgSize.hitTarget)
          .padding({ left: HgSpace.s, right: HgSpace.s })
          .accessibilityText('重置 ' + def.desc)
          .onClick(() => {
            this.resetOverride(def.key);
          })
      }
      Toggle({ type: ToggleType.Switch, isOn: ConfigRegistry.getBool(def.key) })
        .selectedColor(HgColor.accent(this.dark))
        .accessibilityText(def.desc)
        .onChange((isOn: boolean) => {
          this.applyBool(def.key, isOn);
        })
    }
    .width('100%')
    .constraintSize({ minHeight: HgSize.listRowDouble })
  }

  @Builder
  NumberRow(def: ConfigDef) {
    Row({ space: HgSpace.s }) {
      Column({ space: 2 }) {
        Text(def.desc)
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(2)
        Text(def.key + ' · ' + def.min + '~' + def.max +
          (ConfigRegistry.hasLocalOverride(def.key) ? ' · 已覆盖' : ''))
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Text(String(ConfigRegistry.getNumber(def.key)))
        .fontSize(HgFont.caption)
        .fontColor(HgColor.accent(this.dark))
        .maxLines(1)
      if (ConfigRegistry.hasLocalOverride(def.key)) {
        Text('重置')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
          .height(HgSize.hitTarget)
          .padding({ left: HgSpace.s })
          .accessibilityText('重置 ' + def.desc)
          .onClick(() => {
            this.resetOverride(def.key);
          })
      }
      Text('编辑')
        .fontSize(HgFont.caption)
        .fontColor(HgColor.accent(this.dark))
        .height(HgSize.hitTarget)
        .padding({ left: HgSpace.s })
        .accessibilityText('编辑 ' + def.desc)
        .onClick(() => {
          this.openNumberEditor(def);
        })
    }
    .width('100%')
    .constraintSize({ minHeight: HgSize.listRow })
    .padding({ top: HgSpace.xs, bottom: HgSpace.xs })
  }

  @Builder
  CycleRow(def: ConfigDef) {
    HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
      Row({ space: HgSpace.m }) {
        Column({ space: 2 }) {
          Text(def.desc)
            .fontSize(HgFont.secondary)
            .fontColor(HgColor.textPrimary(this.dark))
            .maxLines(2)
          Text(def.key + ' · 可选 ' + (def.options ?? []).join('/') +
            (ConfigRegistry.hasLocalOverride(def.key) ? ' · 已覆盖' : ''))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(ConfigRegistry.getString(def.key) + ' ›')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.accent(this.dark))
          .maxLines(1)
      }
      .width('100%')
      .constraintSize({ minHeight: HgSize.listRowDouble })
      .accessibilityText(def.desc + '，当前 ' + ConfigRegistry.getString(def.key) + '，点击切换')
      .onClick(() => {
        this.cycleString(def);
      })
    }
  }

  @Builder
  LineRow(line: LineItem) {
    HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
      Row({ space: HgSpace.m }) {
        Column({ space: 2 }) {
          Text(line.name ?? hostOf(line.url))
            .fontSize(HgFont.secondary)
            .fontColor(HgColor.textPrimary(this.dark))
            .maxLines(1)
          Text(hostOf(line.url))
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .maxLines(1)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text(Lines.current() === line.url ? '当前' : '切换')
          .fontSize(HgFont.caption)
          .fontColor(Lines.current() === line.url ? HgColor.textTertiary(this.dark) :
            HgColor.accent(this.dark))
          .height(HgSize.hitTarget)
          .padding({ left: HgSpace.s })
          .accessibilityText('切换到 ' + hostOf(line.url))
          .onClick(() => {
            this.switchLine(line.url);
          })
      }
      .width('100%')
      .constraintSize({ minHeight: HgSize.listRow })
    }
  }

  /** 分组卡片外框（标题 + 卡片内容由调用方给出）。 */
  @Builder
  Card(title: string, keyPrefix: string) {
    Column() {
      this.SectionTitle(title)
      Column() {
        if (keyPrefix === 'info') {
          this.InfoCardContent()
        } else if (keyPrefix === 'server') {
          this.ServerCardContent()
        } else if (keyPrefix === 'search') {
          this.SearchResultsContent()
        } else if (keyPrefix === 'flags') {
          this.FlagsCardContent()
        } else if (keyPrefix === 'prefs') {
          this.PrefsCardContent()
        } else if (keyPrefix === 'numbers') {
          this.NumbersCardContent()
        } else if (keyPrefix === 'rollout') {
          this.RolloutCardContent()
        } else if (keyPrefix === 'ab') {
          this.AbCardContent()
        } else if (keyPrefix === 'assets') {
          this.AssetsCardContent()
        } else if (keyPrefix === 'update') {
          this.UpdateCardContent()
        } else if (keyPrefix === 'network') {
          this.NetworkCardContent()
        } else if (keyPrefix === 'export') {
          this.ExportCardContent()
        }
      }
      .width('100%')
      .padding({ left: HgSpace.l, right: HgSpace.l, top: HgSpace.s, bottom: HgSpace.s })
      .backgroundColor(HgColor.surface1(this.dark))
      .borderRadius(HgRadius.group)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /* ── 各分组内容 ───────────────────────────────────── */

  @Builder
  ServerCardContent() {
    this.InfoRow('服务端地址', this.serverBase.length > 0 ? this.serverBase : '未注入（占位端点）')
    this.InfoRow('Host', this.serverHost.length > 0 ? this.serverHost : '—')
    this.InfoRow('接入密钥', this.serverKeyReady ? '已注入（32 hex，已混淆）' : '未注入')
    this.InfoRow('内置 CA', this.caReady ? '已复制到沙箱' : '未初始化/复制失败')
    this.InfoRow('更新接口', Endpoints.updateUrl())
    this.InfoRow('配置接口', Endpoints.configUrl())
    this.InfoRow('App 版本', 'v' + this.appVersion + ' (' + this.appVersionCode + ')')
    this.InfoRow('变体', VARIANT_NAME + (IS_TEST_VARIANT ? '（测试）' : '（发布）'))
    this.InfoRow('分发渠道', AppChannel.id())
    this.InfoRow('系统 API', this.apiVersion)
    this.InfoRow('设备型号', this.deviceModel)
    this.InfoRow('当前线路', hostOf(Lines.current()))
  }

  @Builder
  InfoCardContent() {
    this.InfoRow('变体', VARIANT_NAME + (IS_TEST_VARIANT ? '（调试可用）' : ''))
    this.InfoRow('配置版本', this.infoVersion > 0 ? 'v' + this.infoVersion : '0（编译期默认）')
    this.InfoRow('config_id', this.infoConfigId.length > 0 ? this.infoConfigId : '—')
    this.InfoRow('来源', this.infoSource)
    this.InfoRow('拉取时间', this.infoFetchAt)
    this.InfoRow('签名校验', this.infoSig)
    this.ActionRow('立即拉取远程配置', 'GET /v1/config；验签失败整包丢弃', '拉取', 'accent', 'fetch')
    this.ActionRow('刷新本页', '重新读取 ConfigRegistry / RemoteConfig 状态', '刷新', 'accent', 'refresh')
  }

  @Builder
  FlagsCardContent() {
    ForEach(this.filtered(this.flagDefs), (def: ConfigDef) => {
      this.SwitchRow(def)
    }, (def: ConfigDef) => 'flag-' + def.key + '-' + this.revision)
    this.ActionRow('清除全部本地覆盖', '恢复 远程 / 用户偏好 / 编译期默认 三层值', '清除', 'danger',
      'clear_overrides')
  }

  @Builder
  PrefsCardContent() {
    ForEach(this.filtered(this.prefDefs), (def: ConfigDef) => {
      if (def.type === 'boolean') {
        this.SwitchRow(def)
      } else if (def.type === 'number') {
        this.NumberRow(def)
      } else {
        this.CycleRow(def)
      }
    }, (def: ConfigDef) => 'pref-' + def.key + '-' + this.revision)
  }

  @Builder
  NumbersCardContent() {
    ForEach(this.filtered(this.numberDefs), (def: ConfigDef) => {
      this.NumberRow(def)
    }, (def: ConfigDef) => 'num-' + def.key + '-' + this.revision)
  }

  @Builder
  RolloutCardContent() {
    this.InfoRow('真实 bucket', String(this.realBucket) + ' / 99')
    this.InfoRow('手动 bucket', this.bucketOverride >= 0 ? String(this.bucketOverride) : '未设置')
    this.ActionRow('手动指定 bucket', '0-99；写入本地调试键，供 P4 更新闸门 / P7 面板联调',
      '设置', 'accent', 'set_bucket')
    this.ActionRow('清除 bucket 模拟', '删除本地调试键', '清除', 'danger', 'clear_bucket')
  }

  @Builder
  AbCardContent() {
    this.InfoRow('真实 A/B 组', '组 ' + (this.realAb === 0 ? 'A' : 'B') + '（' + this.realAb + '）')
    this.InfoRow('手动 A/B 组', this.abOverride >= 0 ?
      '组 ' + (this.abOverride === 0 ? 'A' : 'B') + '（' + this.abOverride + '）' : '未设置')
    this.ActionRow('手动指定 A/B 组', '0 = A 组 / 1 = B 组；写入本地调试键', '设置', 'accent', 'set_ab')
    this.ActionRow('清除 A/B 模拟', '删除本地调试键', '清除', 'danger', 'clear_ab')
  }

  @Builder
  AssetsCardContent() {
    this.InfoRow('缓存目录', 'filesDir/' + REMOTE_ASSETS_DIR)
    if (this.assets.length === 0) {
      this.InfoRow('已缓存资源', '暂无（P5 资源热更新接入后生效）')
    } else {
      ForEach(this.assets, (asset: DebugAsset) => {
        this.InfoRow(asset.name, formatBytes(asset.size))
      }, (asset: DebugAsset) => 'asset-' + asset.name + '-' + this.revision)
    }
    this.ActionRow('强制刷新', '清空资源清单缓存，下次启动重新拉取', '刷新', 'accent', 'refresh_assets')
    this.ActionRow('清空已缓存资源', '删除 remote-assets 目录', '清空', 'danger', 'clear_assets')
  }

  @Builder
  UpdateCardContent() {
    this.InfoRow('当前版本', 'v' + Api.appVersion())
    this.InfoRow('模拟当前版本', this.simCurrent.length > 0 ? this.simCurrent : '未设置')
    this.InfoRow('模拟 min_version', this.simMin.length > 0 ? this.simMin : '未设置')
    this.ActionRow('模拟当前版本', '仅本地记录，用于构造更新弹窗', '设置', 'accent', 'set_sim_current')
    this.ActionRow('模拟 min_version', '仅本地记录，用于构造强制更新弹窗', '设置', 'accent', 'set_sim_min')
    this.ActionRow('触发更新检查', '调用 UpdateChecker.checkNow()，有新版本则弹窗', '检查', 'accent',
      'check_update')
    this.ActionRow('用模拟值弹更新窗', '不联网，直接构造 UpdateInfo 弹窗', '弹窗', 'accent', 'sim_update')
    this.ActionRow('清除模拟值', '删除模拟版本本地记录', '清除', 'danger', 'clear_sim')
  }

  @Builder
  NetworkCardContent() {
    this.InfoRow('当前线路', hostOf(Lines.current()))
    ForEach(this.lines, (line: LineItem) => {
      this.LineRow(line)
    }, (line: LineItem) => 'line-' + line.url + '-' + this.revision)
    this.ActionRow('清空配置缓存', 'RemoteConfig.clearCache()：回落编译期默认值', '清空', 'danger',
      'clear_config_cache')
  }

  @Builder
  ExportCardContent() {
    this.ActionRow('复制当前生效配置 JSON', '含版本 / config_id / 来源 / 全部生效值', '复制', 'accent',
      'copy_config')
    this.ActionRow('复制注册表定义 JSON', '全部注册项的 key / 类型 / 范围 / 说明', '复制', 'accent',
      'copy_defs')
  }

  /** 非 test 变体兜底：显示提示（正常路径不可达，防误配）。 */
  @Builder
  GuardView() {
    Column({ space: HgSpace.m }) {
      SymbolGlyph($r('sys.symbol.lock'))
        .fontSize(40)
        .fontColor([HgColor.textTertiary(this.dark)])
      Text('仅测试变体可用')
        .fontSize(HgFont.section)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
      Text('当前为 ' + VARIANT_NAME + ' 变体。用 scripts/harmony/set-variant.mjs test 切换后重新构建。')
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.textTertiary(this.dark))
        .textAlign(TextAlign.Center)
        .maxLines(3)
    }
    .width('100%')
    .padding(HgSpace.xxl)
    .justifyContent(FlexAlign.Center)
  }

  private overlayLines(): DebugOverlayLine[] {
    const out: DebugOverlayLine[] = [];
    out.push(new DebugOverlayLine('服务端', this.serverHost.length > 0 ? this.serverHost : '未注入'));
    out.push(new DebugOverlayLine('App', 'v' + this.appVersion + ' · ' + VARIANT_NAME));
    out.push(new DebugOverlayLine('配置', 'v' + this.infoVersion + ' · ' + this.infoSource));
    out.push(new DebugOverlayLine('config_id', this.infoConfigId.length > 0 ? this.infoConfigId : '—'));
    out.push(new DebugOverlayLine('AI 超分', 'config=' + ConfigRegistry.getBool(ConfigKey.SUPER_RESOLUTION) +
      ' · 目标=' + ConfigRegistry.getNumber(ConfigKey.SR_TARGET_WIDTH) + '×' +
      ConfigRegistry.getNumber(ConfigKey.SR_TARGET_HEIGHT)));
    out.push(new DebugOverlayLine('优先高清', String(ConfigRegistry.getBool(ConfigKey.PREFER_HEVC))));
    out.push(new DebugOverlayLine('线路', hostOf(Lines.current())));
    out.push(new DebugOverlayLine('桶/AB', this.realBucket + '/99 · 组 ' + (this.realAb === 0 ? 'A' : 'B')));
    return out;
  }

  build() {
    NavDestination() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Column() {
          HgTopBar({
          title: '调试配置',
          dark: this.dark,
          showBack: true,
          onBack: () => {
            this.navStack.pop();
          }
        })

        if (!IS_TEST_VARIANT) {
          this.GuardView()
        } else {
          Scroll() {
            Column({ space: HgSpace.l }) {
              TextInput({ text: this.query, placeholder: '搜索配置项（key / 说明）' })
                .width('100%')
                .height(HgSize.control)
                .fontSize(HgFont.secondary)
                .fontColor(HgColor.textPrimary(this.dark))
                .placeholderColor(HgColor.textTertiary(this.dark))
                .backgroundColor(HgColor.surface1(this.dark))
                .borderRadius(HgRadius.control)
                .padding({ left: HgSpace.m, right: HgSpace.m })
                .onChange((value: string) => {
                  this.query = value;
                })
              if (this.query.length > 0) {
                Text('匹配 ' + this.matchCount() + ' 项')
                  .width('100%')
                  .fontSize(HgFont.micro)
                  .fontColor(HgColor.textTertiary(this.dark))
                  .padding({ left: HgSpace.s })
              }
              if (this.query.length > 0) {
                this.Card('搜索结果（' + this.searchResults().length + '）', 'search')
              } else {
                this.Card('服务端与版本', 'server')
                this.Card('当前配置', 'info')
                this.Card('功能开关（' + this.flagDefs.length + '）', 'flags')
                this.Card('用户偏好（' + this.prefDefs.length + '）', 'prefs')
                this.Card('阈值（' + this.numberDefs.length + '）', 'numbers')
                this.Card('灰度', 'rollout')
                this.Card('A/B', 'ab')
                this.Card('资源', 'assets')
                this.Card('更新闸门', 'update')
                this.Card('网络', 'network')
                this.Card('导出', 'export')
              }
            }
            .width('100%')
            .padding({
              left: this.pagePad(),
              right: this.pagePad(),
              top: HgSpace.s,
              bottom: HgSpace.xxl
            })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
        }
        .width('100%')
        .height('100%')
        .padding({ bottom: this.bottomInset })
        .backgroundColor(HgColor.canvas(this.dark))

        if (IS_TEST_VARIANT) {
          DebugOverlay({
            lines: this.overlayLines(),
            dark: this.dark,
            screenW: this.winW,
            screenH: this.winH,
            bottomInset: this.bottomInset
          })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(HgColor.canvas(this.dark))
      // 底部沉浸：背景延伸到系统导航区域，避免页面底边与导航栏之间露出窗口白底。
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.FADE)
    // 兜底铺满整页背景：页面转场/底部安全区内边距区不露出默认背景。
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
