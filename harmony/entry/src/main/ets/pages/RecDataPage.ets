import { pasteboard } from '@kit.BasicServicesKit';
import { HgTopBar } from '../components/HgCommon';
import { ConfirmCopy, ConfirmDialog } from '../components/HgConfirmDialog';
import { HgPressable } from '../components/HgPressable';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { HgMotion } from '../design/HgMotion';
import { HgResponsive } from '../design/HgResponsive';
import { RecDict } from '../recommend/RecDict';
import { parseBoundedJson } from '../utils/Security';
import { RecService } from '../recommend/RecService';
import { RecDiagnostics } from '../recommend/RecTypes';
import { K_BOTTOM_INSET, K_CONTENT_W, K_DARK } from '../state/UserPrefs';
import { I18n } from '../utils/I18n';

/** 剪贴板导入的画像 JSON 大小上限（画像最多 2000 条标签，64KB 足够且防止超大输入拖垮解析）。 */
const PROFILE_JSON_MAX: number = 64 * 1024;

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
  /** 列表整体替换过渡：exitFast 淡出 → 换数据 → standard 淡入。 */
  @State listFade: number = 1;
  private fadeTimer: number = -1;
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

  aboutToDisappear(): void {
    if (this.fadeTimer >= 0) {
      clearTimeout(this.fadeTimer);
      this.fadeTimer = -1;
    }
  }

  /** 列表整体替换（导入/清空）：exitFast 淡出 → 换数据 → standard 淡入（MOTION §3.4）。 */
  private refreshAnimated(after?: () => void): void {
    if (this.fadeTimer >= 0) {
      clearTimeout(this.fadeTimer);
      this.fadeTimer = -1;
    }
    const outMs: number = HgMotion.ms(HgMotion.exitFast);
    animateTo({ duration: outMs, curve: HgMotion.curve }, () => {
      this.listFade = 0;
    });
    this.fadeTimer = setTimeout(() => {
      this.fadeTimer = -1;
      this.refresh();
      if (after !== undefined) {
        after();
      }
      animateTo({ duration: HgMotion.ms(HgMotion.standard), curve: HgMotion.curve }, () => {
        this.listFade = 1;
      });
    }, outMs);
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
      this.status = I18n.fmt2($r('app.string.fmt_exported'), this.rows.length, json.length);
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
      // 剪贴板是不可信输入：先按大小上限 + 标准解析器校验，再交给画像导入（异常不回显原始内容）。
      if (parseBoundedJson(text, PROFILE_JSON_MAX) === null) {
        this.status = '导入失败：数据格式不正确';
        return;
      }
      const ok: boolean = RecService.importProfileJson(text);
      this.refreshAnimated(() => {
        this.status = ok ? I18n.fmt1($r('app.string.fmt_import_ok'), this.rows.length) :
        I18n.fmt0($r('app.string.fmt_import_fail'));
      });
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
    this.refreshAnimated(() => {
      this.status = '已清空推荐画像与行为事件';
    });
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
          Text($r('app.string.fmt_profile_events', this.rows.length, this.eventCount))
            .width('100%')
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
            .padding({ top: HgSpace.s, bottom: HgSpace.m })

          if (this.rows.length === 0) {
            Column() {
              Text($r('app.string.ui_fe65e02e'))
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
        .opacity(this.listFade)

        Column({ space: HgSpace.s }) {
          Row({ space: HgSpace.s }) {
            HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
              Row({ space: HgSpace.xs }) {
                if (this.busy) {
                  LoadingProgress()
                    .width(14)
                    .height(14)
                    .color(HgColor.accent(this.dark))
                }
                Text(this.busy ? '导入中…' : '从剪贴板导入')
                  .fontSize(HgFont.caption)
                  .fontColor(HgColor.accent(this.dark))
              }
              .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.s, bottom: HgSpace.s })
              .backgroundColor(HgColor.accentSoft(this.dark))
              .borderRadius(HgRadius.chip)
              .opacity(this.busy ? 0.6 : 1)
              .accessibilityText(this.busy ? '正在从剪贴板导入画像' : '从剪贴板导入画像')
              .onClick(() => {
                this.importProfile();
              })
            }
            HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
              Text($r('app.string.ui_e29f3122'))
                .fontSize(HgFont.caption)
                .fontColor(HgColor.accent(this.dark))
                .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.s, bottom: HgSpace.s })
                .backgroundColor(HgColor.accentSoft(this.dark))
                .borderRadius(HgRadius.chip)
                .accessibilityText('导出画像到剪贴板')
                .onClick(() => {
                  this.exportProfile();
                })
            }
            HgPressable({ dark: this.dark, noTap: true, pressScale: HgMotion.pressScale }) {
              Text($r('app.string.ui_84fcd70d'))
                .fontSize(HgFont.caption)
                .fontColor(HgColor.danger(this.dark))
                .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.s, bottom: HgSpace.s })
                .backgroundColor(HgColor.surface3(this.dark))
                .borderRadius(HgRadius.chip)
                .accessibilityText('清空本地画像')
                .onClick(() => {
                  this.askClear();
                })
            }
          }
          .width('100%')

          if (this.status.length > 0) {
            Text(this.status)
              .width('100%')
              .fontSize(HgFont.micro)
              .fontColor(HgColor.textTertiary(this.dark))
              .transition(HgMotion.fadeIn(HgMotion.fast))
          }

          // 本地计算状态：真机验收点（截图需能看到「模型 v2 · 打分 3388」）。
          Column({ space: HgSpace.xxs }) {
            Text($r('app.string.ui_6fbdfa23'))
              .fontSize(HgFont.micro)
              .fontWeight(HgFont.weightMedium)
              .fontColor(HgColor.textTertiary(this.dark))
            Text($r('app.string.fmt_model_scored', this.textOr(this.modelVersion), this.modelScored))
              .fontSize(HgFont.caption)
              .lineHeight(HgFont.lineCaption)
              .fontColor(HgColor.textSecondary(this.dark))
            Text($r('app.string.fmt_events_pack', this.eventCount, this.textOr(this.packVersion)))
              .fontSize(HgFont.micro)
              .lineHeight(HgFont.lineMicro)
              .fontColor(HgColor.textTertiary(this.dark))
            Text($r('app.string.ui_bb6138bb'))
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
    .systemTransition(NavigationSystemTransitionType.FADE)
    // 兜底铺满整页背景：页面转场/底部安全区内边距区不露出默认背景（深色下会像一条黑带）。
    .backgroundColor(HgColor.canvas(this.dark))
  }
}
