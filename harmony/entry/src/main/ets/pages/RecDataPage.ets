import { pasteboard } from '@kit.BasicServicesKit';
import { HgTopBar } from '../components/HgCommon';
import { ConfirmCopy, ConfirmDialog } from '../components/HgConfirmDialog';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgResponsive } from '../design/HgResponsive';
import { RecDict } from '../recommend/RecDict';
import { RecService } from '../recommend/RecService';
import { RecDiagnostics } from '../recommend/RecTypes';
import { K_BOTTOM_INSET, K_CONTENT_W, K_DARK } from '../state/UserPrefs';

/**
 * 推荐数据（二级页面）：本地画像呈现 + 导入 / 导出 / 清空（剪贴板 JSON，带格式版本，端侧不上传）。
 * 由设置页弹窗迁移为二级页面，交互与用户可见文案保持一致；清空改用共用的主题化确认弹窗。
 */
@Component
export struct RecDataPage {
  @Consume('hgNavStack') navStack: NavPathStack;
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_BOTTOM_INSET) bottomInset: number = 20;
  /** 窗口宽度（vp）：宽屏时内容限宽 760vp 居中（与设置页一致）。 */
  @StorageProp(K_CONTENT_W) windowW: number = 400;
  @State rows: number[][] = [];
  @State status: string = '';
  @State busy: boolean = false;
  @State eventCount: number = 0;
  /* ── 本地计算状态（RecService.diagnostics()）：让用户看到端侧模型确实在本地打分 ── */
  @State modelVersion: string = '';
  @State modelScored: number = 0;
  @State packVersion: string = '';
  private confirmCopy: ConfirmCopy = new ConfirmCopy('', '', '确定', '取消', false);
  /** 清空确认：共用主题化确认弹窗（不用系统 AlertDialog）。 */
  private confirmController: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialog({
      copyOf: (): ConfirmCopy => this.confirmCopy,
      onConfirm: (): void => {
        this.clearConfirmed();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.rows = RecService.profileEntries();
    const d: RecDiagnostics = RecService.diagnostics();
    this.eventCount = d.eventCount;
    this.modelVersion = d.modelVersion;
    this.modelScored = d.modelScored;
    this.packVersion = d.packVersion;
  }

  private async exportProfile(): Promise<void> {
    try {
      const json: string = RecService.exportProfileJson();
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, json);
      await pasteboard.getSystemPasteboard().setData(data);
      this.status = '已导出到剪贴板（' + this.rows.length + ' 个标签，' + json.length + ' 字符）';
    } catch (err) {
      this.status = '导出失败，请稍后重试';
    }
  }

  private async importProfile(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const data: pasteboard.PasteData = await pasteboard.getSystemPasteboard().getData();
      const text: string = data.getPrimaryText();
      if (text === undefined || text === null || text.length === 0) {
        this.status = '剪贴板里没有可导入的推荐数据';
        return;
      }
      const ok: boolean = RecService.importProfileJson(text);
      this.refresh();
      this.status = ok ? ('导入成功：' + this.rows.length + ' 个标签（已替换当前画像）') : '导入失败：数据格式不正确';
    } catch (err) {
      this.status = '导入失败，请检查剪贴板内容';
    } finally {
      this.busy = false;
    }
  }

  /** 清空入口：打开共用确认弹窗。 */
  private askClear(): void {
    this.confirmCopy = new ConfirmCopy('清空推荐数据', '将清空本地推荐画像与行为事件（不影响收藏、观看历史）。', '清空', '取消', true);
    this.confirmController.open();
  }

  /** 确认后真正清空。 */
  private clearConfirmed(): void {
    RecService.clearProfile();
    this.refresh();
    this.status = '已清空推荐画像与行为事件';
  }

  /** 宽屏内容左右额外留白：返回 (W - FORM_MAX)/2，窄屏返回 0。 */
  private pagePad(): number {
    let gutter: number = 0;
    if (this.windowW > HgResponsive.FORM_MAX) {
      gutter = (this.windowW - HgResponsive.FORM_MAX) / 2;
    }
    return HgSpace.pageInset + gutter;
  }

  /** diagnostics 文本字段兜底：端侧模型/目录未就绪时字段可能为空串，显示 —。 */
  private textOr(value: string): string {
    return value.length > 0 ? value : '—';
  }

  build() {
    NavDestination() {
      Column() {
        HgTopBar({
          title: '推荐数据',
          dark: this.dark,
          showBack: true,
          onBack: () => {
            this.navStack.pop();
          }
        })

        Column() {
          Text('本地画像 ' + this.rows.length + ' 个标签 · 行为事件 ' + this.eventCount + ' 条')
            .width('100%')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
            .padding({ top: HgSpace.s, bottom: HgSpace.m })

          if (this.rows.length === 0) {
            Column() {
              Text('画像还是空的：先收藏/播放几部剧，偏好会慢慢积累。')
                .fontSize(HgFont.body)
                .fontColor(HgColor.textSecondary(this.dark))
                .textAlign(TextAlign.Center)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            List({ space: HgSpace.s }) {
              ForEach(this.rows, (row: number[]) => {
                ListItem() {
                  Row() {
                    Text(RecDict.tagName(row[0]))
                      .fontSize(HgFont.body)
                      .fontColor(HgColor.textPrimary(this.dark))
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(row[1].toFixed(2))
                      .fontSize(HgFont.caption)
                      .fontColor(HgColor.accent(this.dark))
                  }
                  .width('100%')
                  .height(HgSize.listRow)
                  .padding({ left: HgSpace.l, right: HgSpace.l })
                  .backgroundColor(HgColor.surface1(this.dark))
                  .borderRadius(HgRadius.row)
                }
              }, (row: number[]) => row[0].toString())
            }
            .layoutWeight(1)
            .width('100%')
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
          }
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: this.pagePad(), right: this.pagePad() })

        Column({ space: HgSpace.s }) {
          Row({ space: HgSpace.s }) {
            Text(this.busy ? '导入中…' : '从剪贴板导入')
              .fontSize(HgFont.caption)
              .fontColor(HgColor.accent(this.dark))
              .backgroundColor(HgColor.accentSoft(this.dark))
              .borderRadius(HgRadius.chip)
              .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.s, bottom: HgSpace.s })
              .onClick(() => {
                this.importProfile();
              })
            Text('导出到剪贴板')
              .fontSize(HgFont.caption)
              .fontColor(HgColor.accent(this.dark))
              .backgroundColor(HgColor.accentSoft(this.dark))
              .borderRadius(HgRadius.chip)
              .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.s, bottom: HgSpace.s })
              .onClick(() => {
                this.exportProfile();
              })
            Text('清空')
              .fontSize(HgFont.caption)
              .fontColor(HgColor.danger(this.dark))
              .backgroundColor(HgColor.surface3(this.dark))
              .borderRadius(HgRadius.chip)
              .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.s, bottom: HgSpace.s })
              .onClick(() => {
                this.askClear();
              })
          }
          .width('100%')

          if (this.status.length > 0) {
            Text(this.status)
              .width('100%')
              .fontSize(HgFont.micro)
              .fontColor(HgColor.textTertiary(this.dark))
          }

          // 本地计算状态：真机验收点（截图需能看到「模型 v2 · 打分 3388」）。
          Column({ space: HgSpace.xxs }) {
            Text('本地计算状态')
              .fontSize(HgFont.micro)
              .fontWeight(HgFont.weightMedium)
              .fontColor(HgColor.textTertiary(this.dark))
            Text('模型 ' + this.textOr(this.modelVersion) + ' · 打分 ' + this.modelScored)
              .fontSize(HgFont.caption)
              .lineHeight(HgFont.lineCaption)
              .fontColor(HgColor.textSecondary(this.dark))
            Text('行为事件 ' + this.eventCount + ' 条 · 目录包 ' + this.textOr(this.packVersion))
              .fontSize(HgFont.micro)
              .lineHeight(HgFont.lineMicro)
              .fontColor(HgColor.textTertiary(this.dark))
            Text('模型特征：标签 + 标题/简介文本')
              .fontSize(HgFont.micro)
              .lineHeight(HgFont.lineMicro)
              .fontColor(HgColor.textTertiary(this.dark))
          }
          .width('100%')
          .padding(HgSpace.m)
          .backgroundColor(HgColor.surface1(this.dark))
          .borderRadius(HgRadius.row)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .padding({ left: this.pagePad(), right: this.pagePad(), top: HgSpace.m, bottom: HgSpace.m })
      }
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomInset })
      .backgroundColor(HgColor.canvas(this.dark))
    }
    .hideTitleBar(true)
    // 兜底铺满整页背景：页面转场/底部安全区内边距区不露出默认背景（深色下会像一条黑带）。
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
