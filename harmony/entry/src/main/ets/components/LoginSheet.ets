import { Api } from '../services/Api';
import { UiBus } from '../services/UiBus';
import { UserPrefs } from '../state/UserPrefs';
import { LoginResult } from '../models/Types';
import { HgColor, HgFont, HgRadius, HgSize, HgSpace } from '../design/HgTokens';

/** 登录 / 注册面板（bindSheet 内容）。 */
@Component
export struct LoginSheet {
  @Prop dark: boolean = true;
  @State mode: string = 'login';
  @State username: string = '';
  @State password: string = '';
  @State email: string = '';
  @State busy: boolean = false;
  @State error: string = '';
  onClose: () => void = () => {};

  private async submit(): Promise<void> {
    if (this.busy) {
      return;
    }
    const name = this.username.trim();
    if (name.length < 3) {
      this.error = '账号至少 3 个字符';
      return;
    }
    if (this.password.length < 6) {
      this.error = '密码至少 6 个字符';
      return;
    }
    this.busy = true;
    this.error = '';
    try {
      let result: LoginResult;
      if (this.mode === 'login') {
        result = await Api.login(name, this.password);
      } else {
        result = await Api.register(name, this.password, this.email.trim());
      }
      UserPrefs.setUser(result.user);
      UiBus.toastOk(this.mode === 'login' ? '登录成功' : '注册成功');
      this.onClose();
    } catch (err) {
      this.error = (err as Error).message;
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column() {
      Row() {
        Text(this.mode === 'login' ? '登录' : '注册')
          .fontSize(HgFont.pageTitle)
          .fontWeight(HgFont.weightBold)
          .fontColor(HgColor.textPrimary(this.dark))
          .layoutWeight(1)
        Text(this.mode === 'login' ? '注册新账号' : '已有账号？登录')
          .fontSize(HgFont.secondary)
          .fontColor(HgColor.accent(this.dark))
          .accessibilityText('切换登录/注册')
          .onClick(() => {
            this.mode = this.mode === 'login' ? 'register' : 'login';
            this.error = '';
          })
      }
      .width('100%')
      .height(HgSize.topBar)

      TextInput({ text: this.username, placeholder: '账号' })
        .height(HgSize.control)
        .fontSize(HgFont.body)
        .backgroundColor(HgColor.surface2(this.dark))
        .borderRadius(HgRadius.control)
        .margin({ top: HgSpace.m })
        .onChange((value: string) => {
          this.username = value;
        })

      if (this.mode === 'register') {
        TextInput({ text: this.email, placeholder: '邮箱（选填）' })
          .type(InputType.Email)
          .height(HgSize.control)
          .fontSize(HgFont.body)
          .backgroundColor(HgColor.surface2(this.dark))
          .borderRadius(HgRadius.control)
          .margin({ top: HgSpace.m })
          .onChange((value: string) => {
            this.email = value;
          })
      }

      TextInput({ text: this.password, placeholder: '密码' })
        .type(InputType.Password)
        .height(HgSize.control)
        .fontSize(HgFont.body)
        .backgroundColor(HgColor.surface2(this.dark))
        .borderRadius(HgRadius.control)
        .margin({ top: HgSpace.m })
        .onChange((value: string) => {
          this.password = value;
        })

      if (this.error.length > 0) {
        Text(this.error)
          .width('100%')
          .fontSize(HgFont.caption)
          .fontColor(HgColor.danger(this.dark))
          .margin({ top: HgSpace.s })
      }

      Button(this.busy ? '请稍候…' : (this.mode === 'login' ? '登录' : '注册'))
        .width('100%')
        .height(HgSize.primaryAction)
        .fontSize(HgFont.rowTitle)
        .fontWeight(HgFont.weightMedium)
        .fontColor(HgColor.onAccent(this.dark))
        .backgroundColor(HgColor.accent(this.dark))
        .borderRadius(HgRadius.chip)
        .enabled(!this.busy)
        .margin({ top: HgSpace.xl })
        .accessibilityText('提交')
        .onClick(() => {
          this.submit();
        })

      Text('登录后可使用点赞、收藏、评论与关注；账号数据仅保存在本机。')
        .width('100%')
        .fontSize(HgFont.caption)
        .fontColor(HgColor.textTertiary(this.dark))
        .margin({ top: HgSpace.l })
    }
    .width('100%')
    .padding({ left: HgSpace.sheetInset, right: HgSpace.sheetInset, bottom: HgSpace.xxl })
    .alignItems(HorizontalAlign.Start)
  }
}
