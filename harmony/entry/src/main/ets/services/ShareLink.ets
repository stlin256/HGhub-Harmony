import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { pasteboard } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from './AppContext';
import { Lines } from './Lines';
import { UPSTREAM_CANONICAL_HOST } from './LocalUpstream.local';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGShare';

/**
 * 分享链接与系统分享面板。
 *
 * 多线路兼容的两个关键点：
 * 1. **分享出去的永远是主站规范链接**（由本地配置注入），不跟随当前线路。
 *    镜像域名不保证每个用户都有，用镜像分享会让对方打不开。
 * 2. **接收方只解析视频 ID**，播放时走自己当前线路。
 *    所以链接只是「标识」，不承担「可用性」——发送方和接收方的线路互不影响。
 */
export class ShareLink {
  /** 分享链接固定使用的规范域名（所有用户的内置固定线路里都有）。 */
  static readonly CANONICAL_HOST: string = UPSTREAM_CANONICAL_HOST;

  /** 生成规范分享链接（与当前线路无关）。 */
  static canonicalUrl(videoId: number): string {
    return 'https://' + ShareLink.CANONICAL_HOST + '/video/' + videoId + '/';
  }

  /**
   * 调起系统分享面板。
   * @returns true=已弹出系统面板；false=设备不支持或失败（已回退为复制链接）
   */
  static async share(videoId: number, title: string): Promise<boolean> {
    const url: string = ShareLink.canonicalUrl(videoId);
    if (videoId <= 0) {
      return false;
    }
    if (ShareLink.canSystemShare()) {
      try {
        const data: systemShare.SharedData = new systemShare.SharedData({
          utd: uniformTypeDescriptor.UniformDataType.HYPERLINK,
          content: url,
          title: title.length > 0 ? title : 'HGhub 视频',
          description: '来自 HGhub 的分享'
        });
        const controller: systemShare.ShareController = new systemShare.ShareController(data);
        await controller.show(AppContext.abilityContext(), {
          previewMode: systemShare.SharePreviewMode.DETAIL,
          selectionMode: systemShare.SelectionMode.SINGLE
        });
        hilog.info(LOG_DOMAIN, LOG_TAG, 'system share shown');
        return true;
      } catch (err) {
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'system share failed, fallback to copy');
      }
    }
    // 回退：复制链接（老设备 / 不支持系统分享时仍可用）。
    await ShareLink.copy(url);
    return false;
  }

  /** 复制文本到剪贴板。 */
  static async copy(text: string): Promise<boolean> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      return true;
    } catch (err) {
      return false;
    }
  }

  /** 设备是否支持系统分享面板。 */
  static canSystemShare(): boolean {
    try {
      return canIUse('SystemCapability.Collaboration.SystemShare');
    } catch (err) {
      return false;
    }
  }

  /** 当前线路是否就是规范域名（用于提示文案）。 */
  static onCanonicalHost(): boolean {
    try {
      return Lines.hostOfUrl(Lines.current()) === ShareLink.CANONICAL_HOST;
    } catch (err) {
      return false;
    }
  }
}
