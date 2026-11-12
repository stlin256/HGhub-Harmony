import { LineItem } from '../models/Types';
import { LineAuto } from '../services/LineAuto';
import { Lines } from '../services/Lines';
import { Api } from '../services/Api';
import { UiBus } from '../services/UiBus';
import { UserPrefs } from '../state/UserPrefs';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { hostOf } from '../utils/Format';

/** 探测延迟的候选线路数量上限：当前 + 固定 + 镜像，避免面板打开时探测过久。 */
const MAX_PROBE_LINES: number = 6;

/**
 * 线路（数据源）面板：固定线路 + 地址发布页镜像。
 *
 * 视觉规范：所有颜色/字号/间距走 HgColor/HgFont/HgSpace token，随 App 深浅色主题切换；
 * 面板自带标题栏与关闭按钮（不依赖系统 Sheet 的 close，系统按钮颜色跟随系统主题，会与 App 主题不一致）。
 */
@Component
export struct LineSheet {
  @Prop dark: boolean = true;
  /** 是否显示本组件自带的关闭按钮；宿主已提供关闭按钮（如播放页系统 Sheet）时传 false 避免重复。 */
  @Prop showCloseButton: boolean = true;
  @State current: string = Lines.current();
  @State mirrors: LineItem[] = [];
  @State loading: boolean = false;
  @State error: string = '';
  /** 自动线路状态文案（正在检测/当前可用/已自动切换）+ 检测中 loading。 */
  @State autoStatus: string = LineAuto.statusText();
  @State autoBusy: boolean = false;
  /** 线路延迟（url → ms；-1 表示探测失败）。 */
  @State latency: Map<string, number> = new Map<string, number>();
  /** 是否正在探测延迟。 */
  @State probing: boolean = false;
  onClose: () => void = () => {};

  aboutToAppear(): void {
    this.current = Lines.current();
    this.autoStatus = LineAuto.statusText();
    // 先用上次缓存的镜像立刻渲染（打开面板不空白、不等网络），随后再静默刷新。
    const cached: LineItem[] = Lines.cachedMirrors();
    if (cached.length > 0) {
      this.mirrors = cached;
      this.probeLatency();
    }
    this.loadMirrors();
  }

  private close(): void {
    this.onClose();
  }

  private async loadMirrors(): Promise<void> {
    if (this.loading) {
      return;
    }
    // 有缓存时只做后台刷新，不显示 loading（避免已有列表被骨架替换）。
    const hasCache: boolean = this.mirrors.length > 0;
    this.loading = !hasCache;
    this.error = '';
    try {
      const result = await Api.lineMirrors();
      this.mirrors = result.items !== undefined && result.items !== null ? result.items : [];
    } catch (err) {
      this.error = (err as Error).message;
      // 发布页不可达时用上次缓存的镜像兜底（缓存可能为空，此时只显示错误）。
      const cached: LineItem[] = Lines.cachedMirrors();
      if (cached.length > 0) {
        this.mirrors = cached;
      }
    } finally {
      this.loading = false;
      this.autoStatus = LineAuto.statusText();
      this.probeLatency();
    }
  }

  /** 探测当前线路 + 固定线路 + 前几条镜像的延迟（60s 内复用缓存），结果用于列表右侧展示。 */
  private async probeLatency(): Promise<void> {
    if (this.probing) {
      return;
    }
    const urls: string[] = [];
    const seen: Set<string> = new Set<string>();
    const push = (url: string): void => {
      if (url.length === 0 || seen.has(url) || urls.length >= MAX_PROBE_LINES) {
        return;
      }
      seen.add(url);
      urls.push(url);
    };
    push(this.current);
    const fixed: LineItem[] = Lines.fixed();
    for (let i = 0; i < fixed.length; i++) {
      push(fixed[i].url);
    }
    for (let i = 0; i < this.mirrors.length; i++) {
      push(this.mirrors[i].url);
    }
    if (urls.length === 0) {
      return;
    }
    this.probing = true;
    try {
      const result: Map<string, number> = await LineAuto.probeLatency(urls);
      const next: Map<string, number> = new Map<string, number>();
      result.forEach((ms: number, url: string) => {
        next.set(url, ms);
      });
      this.latency = next;
    } catch (err) {
    } finally {
      this.probing = false;
    }
  }

  /** 延迟文案：未知/探测中/超时/毫秒。 */
  private latencyText(url: string): string {
    const ms: number = this.latency.get(url) ?? -2;
    if (ms === -2) {
      return this.probing ? '检测中…' : '';
    }
    if (ms < 0) {
      return '超时';
    }
    return ms + 'ms';
  }

  private latencyColor(url: string): string {
    const ms: number = this.latency.get(url) ?? -2;
    if (ms === -2 || ms < 0) {
      return HgColor.textTertiary(this.dark);
    }
    if (ms < 100) {
      return HgColor.success(this.dark);
    }
    if (ms < 300) {
      return HgColor.warning(this.dark);
    }
    return HgColor.danger(this.dark);
  }

  /** 延迟底色：与文字同语义的浅底，避免裸文字飘在行内。 */
  private latencyBg(url: string): string {
    const ms: number = this.latency.get(url) ?? -2;
    if (ms === -2) {
      return HgColor.surface3(this.dark);
    }
    if (ms < 0) {
      return HgColor.surface3(this.dark);
    }
    if (ms < 100) {
      return HgColor.successSurface(this.dark);
    }
    if (ms < 300) {
      return HgColor.warningSurface(this.dark);
    }
    return HgColor.dangerSurface(this.dark);
  }

  private lineName(item: LineItem): string {
    if (item.name !== undefined && item.name !== null && item.name.length > 0) {
      return item.name;
    }
    return '镜像线路';
  }

  private switchTo(url: string): void {
    const before: string = Lines.current();
    try {
      const next: string = Api.setLine(url);
      this.current = next;
      // 点当前已选线路不算切换：不能清会话/提示重新登录，否则会误把已登录用户踢下线。
      if (next === before) {
        UiBus.toastInfo('当前已在该线路');
        this.close();
        return;
      }
      // 手动选线的线路也记为偏好：下次启动优先探测它，不可用再自动选最快。
      LineAuto.remember(next);
      UserPrefs.setUser(null);
      UiBus.toastOk('已切换线路，需要重新登录');
      this.close();
    } catch (err) {
      UiBus.toast((err as Error).message);
    }
  }

  /** 点「自动选择」：强制检测并切换（记忆优先），成功后复用全局换线监听做无感重载。 */
  private async autoSelect(): Promise<void> {
    if (this.autoBusy) {
      return;
    }
    this.autoBusy = true;
    this.autoStatus = '正在检测线路…';
    const before: string = Lines.current();
    try {
      const changed: boolean = await LineAuto.ensureBest(true);
      this.current = Lines.current();
      this.autoStatus = LineAuto.statusText();
      if (changed && Lines.current() !== before) {
        UserPrefs.setUser(null);
        UiBus.toastOk('已自动切换到 ' + hostOf(Lines.current()));
        this.probeLatency();
      } else if (this.autoStatus.indexOf('可用') >= 0) {
        UiBus.toastInfo('当前线路可用');
      } else {
        UiBus.toast(this.autoStatus);
      }
    } catch (err) {
      this.autoStatus = '自动选择失败，可手动切换';
      UiBus.toast('自动选择失败，可手动切换');
    } finally {
      this.autoBusy = false;
    }
  }

  /* ── 小组件 ────────────────────────────────────────── */

  @Builder
  LatencyChip(url: string) {
    if (this.latencyText(url).length > 0) {
      Text(this.latencyText(url))
        .fontSize(HgFont.micro)
        .fontColor(this.latencyColor(url))
        .maxLines(1)
        .padding({ left: 7, right: 7, top: 3, bottom: 3 })
        .backgroundColor(this.latencyBg(url))
        .borderRadius(HgRadius.badge)
    }
  }

  @Builder
  UseBadge() {
    Text('使用中')
      .fontSize(HgFont.micro)
      .fontColor(HgColor.onAccent(this.dark))
      .padding({ left: 7, right: 7, top: 3, bottom: 3 })
      .backgroundColor(HgColor.accent(this.dark))
      .borderRadius(HgRadius.badge)
  }

  /** 一行线路：名称/域名 + 延迟 + 选中态。 */
  @Builder
  LineRow(item: LineItem) {
    Row({ space: HgSpace.s }) {
      Column({ space: 2 }) {
        Text(this.lineName(item))
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(hostOf(item.url))
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      this.LatencyChip(item.url)

      if (this.current === item.url) {
        this.UseBadge()
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(HgIconSize.compact)
          .fontColor([HgColor.accent(this.dark)])
      }
    }
    .width('100%')
    .height(HgSize.listRowDouble)
    .padding({ left: HgSpace.m, right: HgSpace.m })
    .backgroundColor(this.current === item.url ? HgColor.accentSoft(this.dark) : Color.Transparent)
    .onClick(() => {
      this.switchTo(item.url);
    })
    .accessibilityText('线路 ' + this.lineName(item) + '，' + hostOf(item.url) +
      (this.current === item.url ? '，使用中' : '，点击切换'))
  }

  @Builder
  SectionTitle(title: string, trailing: string) {
    Row() {
      Text(title)
        .fontSize(HgFont.caption)
        .fontColor(HgColor.textTertiary(this.dark))
      Blank()
      if (trailing.length > 0) {
        Text(trailing)
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
      }
    }
    .width('100%')
    .height(24)
    .padding({ left: HgSpace.s, right: HgSpace.s })
  }

  /** 镜像线路加载中：3 行骨架。 */
  @Builder
  MirrorSkeleton() {
    Column() {
      ForEach([0, 1, 2], (index: number) => {
        Row() {
          Column({ space: 6 }) {
            Row()
              .width('46%')
              .height(HgFont.rowTitle)
              .backgroundColor(HgColor.skeletonBase(this.dark))
              .borderRadius(4)
            Row()
              .width('70%')
              .height(HgFont.caption)
              .backgroundColor(HgColor.skeletonBase(this.dark))
              .borderRadius(4)
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          Row()
            .width(40)
            .height(18)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(HgRadius.badge)
        }
        .width('100%')
        .height(HgSize.listRowDouble)
        .padding({ left: HgSpace.m, right: HgSpace.m })
        if (index < 2) {
          Divider()
            .strokeWidth(0.5)
            .color(HgColor.hairline(this.dark))
        }
      }, (index: number) => 'mirror-skeleton-' + index)
    }
    .width('100%')
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
    .border({ width: 1, color: HgColor.hairline(this.dark) })
  }

  /** 镜像线路加载失败：错误 + 重试。 */
  @Builder
  MirrorError() {
    Row({ space: HgSpace.s }) {
      Text(this.error)
        .fontSize(HgFont.caption)
        .fontColor(HgColor.danger(this.dark))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text('重试')
        .fontSize(HgFont.caption)
        .fontColor(HgColor.accent(this.dark))
        .height(HgSize.compactControl)
        .padding({ left: HgSpace.m, right: HgSpace.m })
        .onClick(() => {
          this.loadMirrors();
        })
        .accessibilityText('重新获取镜像线路')
    }
    .width('100%')
    .padding(HgSpace.m)
    .backgroundColor(HgColor.dangerSurface(this.dark))
    .borderRadius(HgRadius.group)
  }

  @Builder
  MirrorEmpty() {
    Row({ space: HgSpace.s }) {
      SymbolGlyph($r('sys.symbol.arrow_clockwise'))
        .fontSize(HgIconSize.compact)
        .fontColor([HgColor.textTertiary(this.dark)])
      Text('暂未获取到镜像线路，可稍后刷新重试。')
        .fontSize(HgFont.caption)
        .fontColor(HgColor.textSecondary(this.dark))
        .layoutWeight(1)
      Text('刷新')
        .fontSize(HgFont.caption)
        .fontColor(HgColor.accent(this.dark))
        .height(HgSize.compactControl)
        .padding({ left: HgSpace.m, right: HgSpace.m })
        .onClick(() => {
          this.loadMirrors();
        })
    }
    .width('100%')
    .padding(HgSpace.m)
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
    .border({ width: 1, color: HgColor.hairline(this.dark) })
  }

  /** 镜像列表外框：圆角卡片 + 行分隔线。 */
  @Builder
  MirrorList() {
    Column() {
      ForEach(this.mirrors, (item: LineItem, index: number) => {
        this.LineRow(item)
        if (index < this.mirrors.length - 1) {
          Divider()
            .strokeWidth(0.5)
            .color(HgColor.hairline(this.dark))
        }
      }, (item: LineItem) => item.url)
    }
    .width('100%')
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
    .border({ width: 1, color: HgColor.hairline(this.dark) })
    .clip(true)
  }

  @Builder
  FixedList() {
    Column() {
      ForEach(Lines.fixed(), (item: LineItem, index: number) => {
        this.LineRow(item)
        if (index < Lines.fixed().length - 1) {
          Divider()
            .strokeWidth(0.5)
            .color(HgColor.hairline(this.dark))
        }
      }, (item: LineItem) => item.url)
    }
    .width('100%')
    .backgroundColor(HgColor.surface1(this.dark))
    .borderRadius(HgRadius.group)
    .border({ width: 1, color: HgColor.hairline(this.dark) })
    .clip(true)
  }

  @Builder
  Header() {
    Row({ space: HgSpace.s }) {
      Column({ space: HgSpace.xxs }) {
        Text('线路')
          .fontSize(HgFont.pageTitle)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
        Text('选择数据源线路；手动切换后需要重新登录')
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textTertiary(this.dark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.showCloseButton) {
        Stack() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(HgIconSize.compact)
            .fontColor([HgColor.textSecondary(this.dark)])
        }
        .width(HgSize.compactControl)
        .height(HgSize.compactControl)
        .borderRadius(HgSize.compactControl / 2)
        .backgroundColor(HgColor.surface3(this.dark))
        .onClick(() => {
          this.close();
        })
        .accessibilityText('关闭线路面板')
      }
    }
    .width('100%')
    .height(HgSize.topBar + 12)
  }

  @Builder
  CurrentCard() {
    Column({ space: HgSpace.s }) {
      Row({ space: HgSpace.s }) {
        Column({ space: 2 }) {
          Text('当前线路')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
          Text(hostOf(this.current))
            .fontSize(HgFont.rowTitle)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.textPrimary(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        this.LatencyChip(this.current)
      }
      .width('100%')

      Row({ space: HgSpace.s }) {
        Text(this.autoStatus)
          .layoutWeight(1)
          .fontSize(HgFont.micro)
          .fontColor(HgColor.textSecondary(this.dark))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.autoBusy) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(HgColor.accent(this.dark))
        } else {
          Text('自动选择')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.accent(this.dark))
            .backgroundColor(HgColor.accentSoft(this.dark))
            .borderRadius(HgRadius.chip)
            .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.xs, bottom: HgSpace.xs })
            .onClick(() => {
              this.autoSelect();
            })
            .accessibilityText('自动检测并选择可用线路')
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(HgSpace.m)
    .backgroundColor(HgColor.surface2(this.dark))
    .borderRadius(HgRadius.group)
    .border({ width: 1, color: HgColor.hairline(this.dark) })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      this.Header()

      Scroll() {
        Column({ space: HgSpace.m }) {
          this.CurrentCard()

          Column({ space: HgSpace.s }) {
            this.SectionTitle('固定线路', this.probing ? '检测延迟中…' : '')
            this.FixedList()
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Column({ space: HgSpace.s }) {
            Row() {
              Text('镜像线路')
                .fontSize(HgFont.caption)
                .fontColor(HgColor.textTertiary(this.dark))
              if (this.mirrors.length > 0) {
                Text(' · ' + this.mirrors.length + ' 条')
                  .fontSize(HgFont.micro)
                  .fontColor(HgColor.textTertiary(this.dark))
              }
              Blank()
              if (this.loading) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                  .color(HgColor.accent(this.dark))
              } else {
                Row({ space: HgSpace.xxs }) {
                  SymbolGlyph($r('sys.symbol.arrow_clockwise'))
                    .fontSize(HgIconSize.inline)
                    .fontColor([HgColor.accent(this.dark)])
                  Text('刷新')
                    .fontSize(HgFont.micro)
                    .fontColor(HgColor.accent(this.dark))
                }
                .height(HgSize.compactControl)
                .padding({ left: HgSpace.s, right: HgSpace.s })
                .onClick(() => {
                  this.loadMirrors();
                })
                .accessibilityText('刷新镜像线路')
              }
            }
            .width('100%')
            .height(24)
            .padding({ left: HgSpace.s, right: HgSpace.s })

            if (this.loading && this.mirrors.length === 0) {
              this.MirrorSkeleton()
            } else if (this.error.length > 0 && this.mirrors.length === 0) {
              this.MirrorError()
            } else if (this.mirrors.length === 0) {
              this.MirrorEmpty()
            } else {
              if (this.error.length > 0) {
                this.MirrorError()
              }
              this.MirrorList()
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Text('镜像线路仅支持游客浏览，登录请使用固定线路。')
            .width('100%')
            .fontSize(HgFont.micro)
            .fontColor(HgColor.textTertiary(this.dark))
            .lineHeight(HgFont.lineMicro)
            .padding({ left: HgSpace.s, right: HgSpace.s, bottom: HgSpace.xxl })
        }
        .width('100%')
        .padding({ top: HgSpace.xs, bottom: HgSpace.xxl })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    .padding({ left: HgSpace.sheetInset, right: HgSpace.sheetInset })
    .backgroundColor(HgColor.surface1(this.dark))
    .alignItems(HorizontalAlign.Start)
  }
}
