import { LineItem } from '../models/Types';
import { Lines } from '../services/Lines';
import { Api } from '../services/Api';
import { UiBus } from '../services/UiBus';
import { UserPrefs } from '../state/UserPrefs';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { hostOf } from '../utils/Format';

/** 线路（数据源）面板：固定线路 + 地址发布页镜像。 */
@Component
export struct LineSheet {
  @Prop dark: boolean = true;
  @State current: string = Lines.current();
  @State mirrors: LineItem[] = [];
  @State loading: boolean = false;
  @State error: string = '';
  onClose: () => void = () => {};

  aboutToAppear(): void {
    this.current = Lines.current();
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
    } catch (err) {
      this.error = (err as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private switchTo(url: string): void {
    try {
      const next = Api.setLine(url);
      this.current = next;
      UserPrefs.setUser(null);
      UiBus.toastOk('已切换线路，需要重新登录');
      this.onClose();
    } catch (err) {
      UiBus.toast((err as Error).message);
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

      if (this.current === item.url) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(HgFont.section)
          .fontColor([HgColor.accent(this.dark)])
      }
    }
    .width('100%')
    .height(HgSize.listRowDouble)
    .onClick(() => {
      this.switchTo(item.url);
    })
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
        .margin({ bottom: HgSpace.s })

      List() {
        ListItem() {
          Text('固定线路')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
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
            .margin({ top: HgSpace.m })
        }
        ForEach(this.mirrors, (item: LineItem) => {
          ListItem() {
            this.LineRow(item)
          }
        }, (item: LineItem) => item.url)
      }
      .width('100%')
      .layoutWeight(1)
      .divider({ strokeWidth: 0.5, color: HgColor.hairline(this.dark) })

      if (this.loading) {
        Row() {
          LoadingProgress().width(16).height(16).color(HgColor.accent(this.dark))
          Text('正在获取镜像线路…')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
            .margin({ left: HgSpace.s })
        }
        .width('100%')
        .padding(HgSpace.m)
      }
      if (this.error.length > 0) {
        Text(this.error)
          .width('100%')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.danger(this.dark))
          .padding(HgSpace.m)
      }
    }
    .width('100%')
    .padding({ left: HgSpace.sheetInset, right: HgSpace.sheetInset, bottom: HgSpace.xxl })
    .alignItems(HorizontalAlign.Start)
  }
}
