import { LineItem } from '../models/Types';
import { LineAuto } from '../services/LineAuto';
import { Lines } from '../services/Lines';
import { Api } from '../services/Api';
import { UiBus } from '../services/UiBus';
import { UserPrefs } from '../state/UserPrefs';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { hostOf } from '../utils/Format';

/** 线路（数据源）面板：固定线路 + 地址发布页镜像。 */
@Component
export struct LineSheet {
  @Prop dark: boolean = true;
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
    this.loadMirrors();
  }

  private async loadMirrors(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.error = '';
    try {
      const result = await Api.lineMirrors();
      this.mirrors = result.items;
      this.probeLatency();
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
    }
  }

  /** 探测当前线路 + 前 4 条镜像的延迟（60s 内复用缓存），结果用于列表右侧展示。 */
  private async probeLatency(): Promise<void> {
    if (this.probing) {
      return;
    }
    const urls: string[] = [this.current];
    for (let i = 0; i < this.mirrors.length && urls.length < 5; i++) {
      const item: LineItem = this.mirrors[i];
      if (item !== undefined && item !== null && item.url !== this.current) {
        urls.push(item.url);
      }
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

  /** 延迟文案与颜色：<100ms 绿、<300ms 黄、其余红、探测失败灰。 */
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
    if (ms === -2) {
      return HgColor.textTertiary(this.dark);
    }
    if (ms < 0) {
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

  private switchTo(url: string): void {
    const before: string = Lines.current();
    try {
      const next: string = Api.setLine(url);
      this.current = next;
      // 点当前已选线路不算切换：不能清会话/提示重新登录，否则会误把已登录用户踢下线。
      if (next === before) {
        UiBus.toastInfo('当前已在该线路');
        this.onClose();
        return;
      }
      // 手动选线的线路也记为偏好：下次启动优先探测它，不可用再自动选最快。
      LineAuto.remember(next);
      UserPrefs.setUser(null);
      UiBus.toastOk('已切换线路，需要重新登录');
      this.onClose();
    } catch (err) {
      UiBus.toast((err as Error).message);
    }
  }

  /** 用户点「自动选择」：强制检测并切换（记忆优先），成功后复用全局换线监听做无感重载。 */
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

  @Builder
  LineRow(item: LineItem) {
    Row() {
      Column({ space: 2 }) {
        Text(item.name !== undefined && item.name !== null && item.name.length > 0 ? item.name : '镜像线路')
          .fontSize(HgFont.rowTitle)
          .fontColor(HgColor.textPrimary(this.dark))
        Text(hostOf(item.url))
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.latencyText(item.url).length > 0) {
        Text(this.latencyText(item.url))
          .fontSize(HgFont.caption)
          .fontColor(this.latencyColor(item.url))
          .maxLines(1)
          .margin({ right: HgSpace.s })
      }

      if (this.current === item.url) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(HgFont.section)
          .fontColor([HgColor.accent(this.dark)])
      }
    }
    .width('100%')
    .height(HgSize.listRowDouble)
    .padding({ right: HgSpace.s })
    .onClick(() => {
      this.switchTo(item.url);
    })
  }

  /** 镜像线路加载中：标题下方直接给 3 行骨架 + 进度提示，不等列表底部。 */
  @Builder
  MirrorSkeleton() {
    Column({ space: HgSpace.m }) {
      Row({ space: HgSpace.s }) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(HgColor.accent(this.dark))
        Text('正在获取镜像线路…')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.textTertiary(this.dark))
      }
      .width('100%')
      .padding({ top: HgSpace.m })

      ForEach([0, 1, 2], (index: number) => {
        Row() {
          Column({ space: 2 }) {
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
            .width(HgIconSize.compact)
            .height(HgIconSize.compact)
            .backgroundColor(HgColor.skeletonBase(this.dark))
            .borderRadius(HgIconSize.compact / 2)
        }
        .width('100%')
        .height(HgSize.listRowDouble)
        .padding({ right: HgSpace.s })
      }, (index: number) => 'mirror-skeleton-' + index)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 镜像线路拉取失败：在标题下方给错误与重试，而不是沉到列表底部。 */
  @Builder
  MirrorError() {
    Row({ space: HgSpace.s }) {
      Text(this.error)
        .fontSize(HgFont.caption)
        .fontColor(HgColor.danger(this.dark))
        .layoutWeight(1)
        .maxLines(2)
      Text('重试')
        .fontSize(HgFont.secondary)
        .fontColor(HgColor.accent(this.dark))
        .onClick(() => {
          this.loadMirrors();
        })
    }
    .width('100%')
    .padding({ top: HgSpace.s, bottom: HgSpace.s, right: HgSpace.s })
  }

  build() {
    Column() {
      Row() {
        Text('线路')
          .fontSize(HgFont.pageTitle)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
          .layoutWeight(1)
        Text('刷新镜像')
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.accent(this.dark))
          .onClick(() => {
            this.loadMirrors();
          })
      }
      .width('100%')
      .height(HgSize.topBar)

      Text('镜像线路仅支持游客浏览，登录请使用固定线路。')
        .width('100%')
        .fontSize(HgFont.caption)
        .fontColor(HgColor.textTertiary(this.dark))
        .margin({ bottom: HgSpace.xs })

      // 自动线路状态 + 手动触发检测（Loading 时禁用重复点击）。
      Row({ space: HgSpace.s }) {
        Text(this.autoStatus)
          .layoutWeight(1)
          .fontSize(HgFont.caption)
          .fontColor(this.autoBusy ? HgColor.textSecondary(this.dark) : HgColor.textTertiary(this.dark))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.autoBusy) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(HgColor.accent(this.dark))
        } else {
          Text('自动选择')
            .fontSize(HgFont.secondary)
            .fontColor(HgColor.accent(this.dark))
            .height(HgSize.hitTarget)
            .padding({ left: HgSpace.s, right: HgSpace.s })
            .onClick(() => {
              this.autoSelect();
            })
            .accessibilityText('自动检测并选择可用线路')
        }
      }
      .width('100%')
      .height(HgSize.hitTarget)
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: HgSpace.xs })

      List() {
        ListItem() {
          Text('固定线路')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
            .padding({ right: HgSpace.s })
        }
        ForEach(Lines.fixed(), (item: LineItem) => {
          ListItem() {
            this.LineRow(item)
          }
        }, (item: LineItem) => item.url)

        ListItem() {
          Text('镜像线路')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
            .padding({ top: HgSpace.m, right: HgSpace.s })
        }
        if (this.loading) {
          ListItem() {
            this.MirrorSkeleton()
          }
        } else if (this.error.length > 0) {
          ListItem() {
            this.MirrorError()
          }
        }
        ForEach(this.mirrors, (item: LineItem) => {
          ListItem() {
            this.LineRow(item)
          }
        }, (item: LineItem) => item.url)
      }
      .width('100%')
      .layoutWeight(1)
      // 关闭悬浮滚动条：避免默认滚动条压在行内容/对勾上。
      .scrollBar(BarState.Off)
      .divider({ strokeWidth: 0.5, color: HgColor.hairline(this.dark) })
    }
    .width('100%')
    .padding({ left: HgSpace.sheetInset, right: HgSpace.sheetInset, bottom: HgSpace.xxl })
    .alignItems(HorizontalAlign.Start)
  }
}
