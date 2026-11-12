import { avSession } from '@kit.AVSessionKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from '../services/AppContext';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGMediaSession';
const SESSION_TAG: string = 'hghub_audio';

/** 播放器对外暴露的会话回调（由 PlayerService 注入）。 */
export interface MediaSessionCallbacks {
  onPlay: () => void;
  onPause: () => void;
  onStop: () => void;
  onNext: () => void;
  onPrevious: () => void;
  onSeek: (positionMs: number) => void;
}

/**
 * 系统媒体会话（AVSession）：把播放状态同步到锁屏 / 控制中心 / 通知栏，
 * 并接收系统侧的播放控制指令。
 *
 * 设计约束：
 * - 全部调用 try/catch，失败静默降级（不影响播放）；
 * - 首次播放时才创建会话，避免冷启动额外开销；
 * - 不申请后台播放权限（后台播放需 backgroundTaskManager + wantAgent，另行评估）。
 */
export class MediaSession {
  private static session: avSession.AVSession | undefined = undefined;
  private static creating: boolean = false;
  private static callbacks: MediaSessionCallbacks | undefined = undefined;

  /** 注入回调（PlayerService 初始化时调用一次）。 */
  static bind(callbacks: MediaSessionCallbacks): void {
    MediaSession.callbacks = callbacks;
  }

  /** 创建并激活会话（幂等；失败静默）。 */
  static async ensure(): Promise<void> {
    if (MediaSession.session !== undefined || MediaSession.creating) {
      return;
    }
    if (!AppContext.isReady()) {
      return;
    }
    MediaSession.creating = true;
    try {
      const session: avSession.AVSession = await avSession.createAVSession(
        AppContext.abilityContext(), SESSION_TAG, 'audio');
      MediaSession.session = session;
      MediaSession.registerCallbacks(session);
      await session.activate();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'session created');
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'session create failed');
    } finally {
      MediaSession.creating = false;
    }
  }

  private static registerCallbacks(session: avSession.AVSession): void {
    try {
      session.on('play', () => {
        const cb = MediaSession.callbacks;
        if (cb !== undefined) {
          cb.onPlay();
        }
      });
      session.on('pause', () => {
        const cb = MediaSession.callbacks;
        if (cb !== undefined) {
          cb.onPause();
        }
      });
      session.on('stop', () => {
        const cb = MediaSession.callbacks;
        if (cb !== undefined) {
          cb.onStop();
        }
      });
      session.on('playNext', () => {
        const cb = MediaSession.callbacks;
        if (cb !== undefined) {
          cb.onNext();
        }
      });
      session.on('playPrevious', () => {
        const cb = MediaSession.callbacks;
        if (cb !== undefined) {
          cb.onPrevious();
        }
      });
      session.on('seek', (time: number) => {
        const cb = MediaSession.callbacks;
        if (cb !== undefined) {
          cb.onSeek(time);
        }
      });
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'register callbacks failed');
    }
  }

  /** 同步媒体元数据（标题 / 作者）。 */
  static async setMetadata(title: string, artist: string, assetId: string): Promise<void> {
    const session = MediaSession.session;
    if (session === undefined) {
      return;
    }
    try {
      const metadata: avSession.AVMetadata = {
        assetId: assetId,
        title: title,
        artist: artist
      };
      await session.setAVMetadata(metadata);
    } catch (err) {
    }
  }

  /** 同步播放状态与进度。 */
  static async setState(playing: boolean, positionMs: number, speed: number): Promise<void> {
    const session = MediaSession.session;
    if (session === undefined) {
      return;
    }
    try {
      const state: avSession.AVPlaybackState = {
        state: playing ? avSession.PlaybackState.PLAYBACK_STATE_PLAY :
          avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        position: {
          elapsedTime: Math.max(0, Math.round(positionMs)),
          updateTime: Date.now()
        },
        speed: speed
      };
      await session.setAVPlaybackState(state);
    } catch (err) {
    }
  }

  /** 释放会话（应用退出/播放器释放时）。 */
  static async release(): Promise<void> {
    const session = MediaSession.session;
    MediaSession.session = undefined;
    if (session === undefined) {
      return;
    }
    try {
      await session.destroy();
    } catch (err) {
    }
  }
}
