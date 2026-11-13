/**
 * 远程通知展示组件（SPEC §12 / C7）：dialog / banner / fullscreen / toast 四种模式。
 *
 * 设计约定：
 * - 本组件是**页面内浮层**（由 pages/Index.ets 在根 Stack 里条件渲染），不是系统弹窗：
 *   dialog/fullscreen 带遮罩，banner/toast 不阻断页面操作（hitTestBehavior=Transparent）；
 * - window.closable=false 时不渲染关闭按钮，遮罩点击也不关闭（服务端意图优先）；
 * - window.buttons 支持 copy（复制 value 到剪贴板）/ link（https + isSafeWebUrl 白名单后
 *   交给 Api.openUrl）/ dismiss（关闭）；link 点击后先关闭浮层再跳转；
 * - body 只作为纯文本交给 Text 渲染，**不解析 HTML/Markdown**（防注入）；
 * - 动效统一走 HgMotion（减少动态效果时 HgMotion.ms() 归零，直达终态）：
 *   dialog 260ms 淡入 + 0.96→1 缩放；banner 220ms 淡入 + 上移 8vp；fullscreen 260ms 淡入；
 *   toast 190ms 淡入；退场统一 exitStandard/exitFast；
 * - 每个可点元素都有 accessibilityText（按钮用自身文案，遮罩用关闭文案）；
 * - 无 notices 时 Index 不会渲染本组件，因此对现有行为零影响。
 */

import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { HgMotion } from '../design/HgMotion';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';
import { K_DARK, K_TOP_INSET } from '../state/UserPrefs';
import { Api } from '../services/Api';
import {
  emptyNotice, NoticeButton, NoticeButtonType, NoticeData, NoticeMode
} from '../services/RemoteNotice';
import { isSafeWebUrl, parseHttpsUrl } from '../utils/Security';

/** 退场时长（与统一弹窗壳一致：200ms）。 */
const EXIT_MS: number = HgMotion.exitStandard;
/** toast 自动消失时长：无按钮 4s，有按钮留 6s 方便点击。 */
const TOAST_MS: number = 4000;
const TOAST_WITH_BUTTONS_MS: number = 6000;
/** 弹窗正文最大高度（超出滚动，避免长文把按钮顶出屏幕）。 */
const DIALOG_BODY_MAX_HEIGHT: number = 240;
/** toast 距底部的避让距离（悬浮 Tab 栏约 68vp + 安全区）。 */
const TOAST_BOTTOM_OFFSET: number = 110;
/** 弹窗入场起始缩放（与 HgDialogMotion.enterScale 一致：0.96→1）。 */
const ENTER_SCALE: number = 0.96;

@Component
export struct RemoteNoticeDialog {
  @StorageProp(K_DARK) dark: boolean = true;
  @StorageProp(K_TOP_INSET) topInset: number = 0;
  /** 本次要展示的通知（Index 在 pick() 命中后传入；默认空对象仅满足 ArkTS 字段初始化）。 */
  notice: NoticeData = emptyNotice();
  /** 关闭回调：Index 用它把 noticeVisible 置 false，从而卸载本组件。 */
  onClosed: () => void = () => {};
  /** 入场/退场状态（驱动透明度与位移/缩放）。 */
  @State entered: boolean = false;
  private started: boolean = false;
  private closing: boolean = false;
  private closeTimer: number = -1;
  private enterTimer: number = -1;
  private autoTimer: number = -1;

  aboutToAppear(): void {
    // 首帧后兜底触发（与 HgConfirmDialog 一致：aboutToAppear 里直接 animateTo 可能没有动画）。
    this.enterTimer = setTimeout(() => {
      this.enterTimer = -1;
      this.startEnter();
    }, 16);
    if (this.notice.mode === NoticeMode.TOAST) {
      const delay: number = this.notice.buttons.length > 0 ? TOAST_WITH_BUTTONS_MS : TOAST_MS;
      this.autoTimer = setTimeout(() => {
        this.autoTimer = -1;
        this.dismiss();
      }, delay);
    }
  }

  aboutToDisappear(): void {
    if (this.enterTimer >= 0) {
      clearTimeout(this.enterTimer);
      this.enterTimer = -1;
    }
    if (this.closeTimer >= 0) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
    if (this.autoTimer >= 0) {
      clearTimeout(this.autoTimer);
      this.autoTimer = -1;
    }
  }

  /** 入场时长（按模式取统一动效梯度）。 */
  private enterMs(): number {
    if (this.notice.mode === NoticeMode.TOAST) {
      return HgMotion.base;
    }
    if (this.notice.mode === NoticeMode.BANNER) {
      return HgMotion.standard;
    }
    return HgMotion.surface;
  }

  /** 退场时长：toast 用 exitFast，其余用 exitStandard。 */
  private exitMs(): number {
    return this.notice.mode === NoticeMode.TOAST ? HgMotion.exitFast : EXIT_MS;
  }

  /** 开始入场动画（幂等）。 */
  private startEnter(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    animateTo({ duration: HgMotion.ms(this.enterMs()), curve: HgMotion.curve }, () => {
      this.entered = true;
    });
  }

  /** 关闭：先播退场动画，结束后通知宿主卸载（幂等，快速连点不重复）。 */
  private dismiss(): void {
    if (this.closing) {
      return;
    }
    this.closing = true;
    if (this.autoTimer >= 0) {
      clearTimeout(this.autoTimer);
      this.autoTimer = -1;
    }
    animateTo({ duration: HgMotion.ms(this.exitMs()), curve: HgMotion.curve }, () => {
      this.entered = false;
    });
    this.closeTimer = setTimeout(() => {
      this.closeTimer = -1;
      this.onClosed();
    }, HgMotion.ms(this.exitMs()));
  }

  /** 窗口按钮分发：copy 复制后保留浮层；link 先关闭再跳转；dismiss 关闭。 */
  private handleButton(btn: NoticeButton): void {
    if (btn.type === NoticeButtonType.COPY) {
      this.copyText(btn.value);
      return;
    }
    if (btn.type === NoticeButtonType.LINK) {
      this.dismiss();
      this.openLink(btn.url);
      return;
    }
    // 未知类型在解析阶段已被丢弃，这里按 dismiss 兜底。
    this.dismiss();
  }

  /** 复制到系统剪贴板（失败静默）。 */
  private copyText(value: string): void {
    if (value.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        try {
          promptAction.showToast({ message: '已复制到剪贴板', duration: 2000 });
        } catch (err) {
        }
      }).catch(() => {
      });
    } catch (err) {
    }
  }

  /** 打开外链：双重校验（https + isSafeWebUrl），失败静默。 */
  private openLink(raw: string): void {
    try {
      if (!isSafeWebUrl(raw)) {
        return;
      }
      const parsed = parseHttpsUrl(raw);
      if (parsed === null) {
        return;
      }
      Api.openUrl(parsed.href);
    } catch (err) {
    }
  }

  /* ── 复用片段 ─────────────────────────────────────── */

  /** 标题（空标题不渲染；纯文本，最多 2 行）。 */
  @Builder
  TitleBlock(fontSize: number, bold: boolean) {
    if (this.notice.title.length > 0) {
      Text(this.notice.title)
        .width('100%')
        .fontSize(fontSize)
        .fontWeight(bold ? HgFont.weightBold : HgFont.weightMedium)
        .fontColor(HgColor.textPrimary(this.dark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }

  /** 正文（纯文本，不解析 HTML/Markdown；超出 maxLines 省略）。 */
  @Builder
  BodyBlock(maxLines: number) {
    if (this.notice.body.length > 0) {
      Text(this.notice.body)
        .width('100%')
        .fontSize(HgFont.body)
        .lineHeight(HgFont.lineBody)
        .fontColor(HgColor.textSecondary(this.dark))
        .maxLines(maxLines)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
  }

  /** 正文（可滚动，弹窗/全屏用；限制最大高度避免顶出按钮）。 */
  @Builder
  BodyScroll() {
    if (this.notice.body.length > 0) {
      Scroll() {
        Text(this.notice.body)
          .width('100%')
          .fontSize(HgFont.body)
          .lineHeight(HgFont.lineBody)
          .fontColor(HgColor.textSecondary(this.dark))
      }
      .width('100%')
      .constraintSize({ maxHeight: DIALOG_BODY_MAX_HEIGHT })
      .scrollBar(BarState.Auto)
    }
  }

  /** 正文（全屏模式：占满标题与按钮之间的剩余高度）。 */
  @Builder
  BodyScrollFill() {
    if (this.notice.body.length > 0) {
      Scroll() {
        Text(this.notice.body)
          .width('100%')
          .fontSize(HgFont.body)
          .lineHeight(HgFont.lineBody)
          .fontColor(HgColor.textSecondary(this.dark))
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.TopStart)
      .scrollBar(BarState.Auto)
    }
  }

  /** 整行按钮（弹窗/全屏用）。 */
  @Builder
  WideButton(btn: NoticeButton) {
    Button(btn.label)
      .width('100%')
      .height(HgSize.secondaryAction)
      .fontSize(HgFont.body)
      .fontWeight(HgFont.weightMedium)
      .fontColor(btn.type === NoticeButtonType.DISMISS ? HgColor.onSecondary(this.dark) : HgColor.onAccent(this.dark))
      .backgroundColor(btn.type === NoticeButtonType.DISMISS ? HgColor.secondaryFill(this.dark) : HgColor.accent(this.dark))
      .borderRadius(HgRadius.chip)
      .accessibilityText(btn.label)
      .onClick(() => {
        this.handleButton(btn);
      })
  }

  /** 行内按钮（banner/toast 用，等分宽度）。 */
  @Builder
  InlineButton(btn: NoticeButton) {
    Button(btn.label)
      .layoutWeight(1)
      .height(HgSize.compactControl)
      .fontSize(HgFont.secondary)
      .fontWeight(HgFont.weightMedium)
      .fontColor(btn.type === NoticeButtonType.DISMISS ? HgColor.onSecondary(this.dark) : HgColor.onAccent(this.dark))
      .backgroundColor(btn.type === NoticeButtonType.DISMISS ? HgColor.secondaryFill(this.dark) : HgColor.accent(this.dark))
      .borderRadius(HgRadius.chip)
      .accessibilityText(btn.label)
      .onClick(() => {
        this.handleButton(btn);
      })
  }

  /** 整行关闭按钮（closable=true 才渲染）。 */
  @Builder
  WideCloseButton() {
    Button(this.notice.closeLabel)
      .width('100%')
      .height(HgSize.secondaryAction)
      .fontSize(HgFont.body)
      .fontWeight(HgFont.weightMedium)
      .fontColor(HgColor.onSecondary(this.dark))
      .backgroundColor(HgColor.secondaryFill(this.dark))
      .borderRadius(HgRadius.chip)
      .accessibilityText(this.notice.closeLabel)
      .onClick(() => {
        this.dismiss();
      })
  }

  /** 遮罩：dialog/fullscreen 用；closable=false 时点击不关闭。 */
  @Builder
  MaskView() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(HgColor.mask(this.dark))
      .opacity(this.entered ? 1 : 0)
      .accessibilityText(this.notice.closeLabel)
      .onClick(() => {
        if (this.notice.closable) {
          this.dismiss();
        }
      })
  }

  /* ── 四种模式 ─────────────────────────────────────── */

  /** dialog：居中卡片，淡入 + 0.96→1 缩放。 */
  @Builder
  DialogView() {
    Column() {
      Column({ space: HgSpace.m }) {
        this.TitleBlock(HgFont.section, true)
        this.BodyScroll()
        if (this.notice.buttons.length > 0) {
          Column({ space: HgSpace.s }) {
            ForEach(this.notice.buttons, (btn: NoticeButton) => {
              this.WideButton(btn)
            }, (btn: NoticeButton, index: number) => 'wd_' + index + '_' + btn.type)
          }
          .width('100%')
        }
        if (this.notice.closable) {
          this.WideCloseButton()
        }
      }
      .width(320)
      .padding({ left: HgSpace.xl, right: HgSpace.xl, top: HgSpace.xxl, bottom: HgSpace.xl })
      .backgroundColor(HgColor.surface1(this.dark))
      .borderRadius(HgRadius.surface)
      .border({ width: 1, color: HgColor.hairline(this.dark) })
      .shadow({ radius: 24, color: HgColor.shadowElev3, offsetX: 0, offsetY: 8 })
      .alignItems(HorizontalAlign.Start)
      .opacity(this.entered ? 1 : 0)
      .scale({ x: this.entered ? 1 : ENTER_SCALE, y: this.entered ? 1 : ENTER_SCALE })
      // 卡片自身消费点击（避免点卡片空白处穿透到遮罩导致误关闭）。
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: HgSpace.l, right: HgSpace.l })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    // 自身不参与命中测试，让卡片外的点击落到下方遮罩（点击遮罩关闭）。
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** banner：顶部横幅，淡入 + 上移 8vp；不阻断页面操作。 */
  @Builder
  BannerView() {
    Column() {
      Column({ space: HgSpace.xs }) {
        Row({ space: HgSpace.s }) {
          Text(this.notice.title)
            .layoutWeight(1)
            .fontSize(HgFont.cardTitle)
            .fontWeight(HgFont.weightBold)
            .fontColor(HgColor.textPrimary(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.notice.closable) {
            Text(this.notice.closeLabel)
              .fontSize(HgFont.secondary)
              .fontColor(HgColor.accent(this.dark))
              .padding({ left: HgSpace.s, right: HgSpace.s, top: HgSpace.xs, bottom: HgSpace.xs })
              .accessibilityText(this.notice.closeLabel)
              .onClick(() => {
                this.dismiss();
              })
          }
        }
        .width('100%')
        this.BodyBlock(2)
        if (this.notice.buttons.length > 0) {
          Row({ space: HgSpace.s }) {
            ForEach(this.notice.buttons, (btn: NoticeButton) => {
              this.InlineButton(btn)
            }, (btn: NoticeButton, index: number) => 'bn_' + index + '_' + btn.type)
          }
          .width('100%')
          .margin({ top: HgSpace.xs })
        }
      }
      .width('100%')
      .padding({ left: HgSpace.l, right: HgSpace.l, top: HgSpace.m, bottom: HgSpace.m })
      .backgroundColor(HgColor.surface2(this.dark))
      .borderRadius(HgRadius.card)
      .border({ width: 1, color: HgColor.hairline(this.dark) })
      .shadow({ radius: 16, color: HgColor.shadowElev2, offsetX: 0, offsetY: 4 })
      .opacity(this.entered ? 1 : 0)
      .translate({ y: this.entered ? 0 : -HgMotion.enterOffset })
      // 卡片自身消费点击，避免点横幅空白处穿透到下方页面。
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, top: this.topInset + HgSpace.s })
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** fullscreen：整页内容，淡入 + 下移 8vp。 */
  @Builder
  FullscreenView() {
    Column() {
      Column({ space: HgSpace.m }) {
        this.TitleBlock(HgFont.pageTitle, true)
        this.BodyScrollFill()
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: HgSpace.s }) {
        if (this.notice.buttons.length > 0) {
          ForEach(this.notice.buttons, (btn: NoticeButton) => {
            this.WideButton(btn)
          }, (btn: NoticeButton, index: number) => 'fs_' + index + '_' + btn.type)
        }
        if (this.notice.closable) {
          this.WideCloseButton()
        }
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding({
      left: HgSpace.xl,
      right: HgSpace.xl,
      top: this.topInset + HgSpace.xxl,
      bottom: HgSpace.xxl
    })
    .backgroundColor(HgColor.pageBackground(this.dark))
    .opacity(this.entered ? 1 : 0)
    .translate({ y: this.entered ? 0 : HgMotion.enterOffset })
  }

  /** toast：底部提示，4-6s 自动消失；不阻断页面操作。 */
  @Builder
  ToastView() {
    Column() {
      Column({ space: HgSpace.xs }) {
        if (this.notice.title.length > 0) {
          Text(this.notice.title)
            .width('100%')
            .fontSize(HgFont.secondary)
            .fontWeight(HgFont.weightMedium)
            .fontColor(HgColor.textPrimary(this.dark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        this.BodyBlock(3)
        if (this.notice.buttons.length > 0) {
          Row({ space: HgSpace.s }) {
            ForEach(this.notice.buttons, (btn: NoticeButton) => {
              this.InlineButton(btn)
            }, (btn: NoticeButton, index: number) => 'ts_' + index + '_' + btn.type)
          }
          .width('100%')
          .margin({ top: HgSpace.xs })
        }
        if (this.notice.closable && this.notice.buttons.length === 0) {
          Text(this.notice.closeLabel)
            .fontSize(HgFont.caption)
            .fontColor(HgColor.textTertiary(this.dark))
            .padding({ top: HgSpace.xs })
            .accessibilityText(this.notice.closeLabel)
            .onClick(() => {
              this.dismiss();
            })
        }
      }
      .width('100%')
      .padding({ left: HgSpace.l, right: HgSpace.l, top: HgSpace.m, bottom: HgSpace.m })
      .backgroundColor(HgColor.surface3(this.dark))
      .borderRadius(HgRadius.card)
      .border({ width: 1, color: HgColor.hairline(this.dark) })
      .shadow({ radius: 16, color: HgColor.shadowElev2, offsetX: 0, offsetY: 4 })
      .opacity(this.entered ? 1 : 0)
      .translate({ y: this.entered ? 0 : HgMotion.enterOffset })
      // 卡片自身消费点击，避免点 toast 空白处穿透到下方页面。
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: HgSpace.pageInset, right: HgSpace.pageInset, bottom: TOAST_BOTTOM_OFFSET })
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  build() {
    Stack() {
      if (this.notice.mode === NoticeMode.DIALOG || this.notice.mode === NoticeMode.FULLSCREEN) {
        this.MaskView()
      }
      if (this.notice.mode === NoticeMode.BANNER) {
        this.BannerView()
      } else if (this.notice.mode === NoticeMode.FULLSCREEN) {
        this.FullscreenView()
      } else if (this.notice.mode === NoticeMode.TOAST) {
        this.ToastView()
      } else {
        this.DialogView()
      }
    }
    .width('100%')
    .height('100%')
    // banner/toast 不阻断页面操作（自身不参与命中测试，子节点正常响应）；
    // dialog/fullscreen 为模态浮层，默认行为会挡住下方页面。
    .hitTestBehavior(this.notice.mode === NoticeMode.BANNER || this.notice.mode === NoticeMode.TOAST ?
      HitTestMode.Transparent : HitTestMode.Default)
  }
}
