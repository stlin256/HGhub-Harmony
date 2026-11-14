/**
 * 后台播放持续任务：申请/释放 AUDIO_PLAYBACK 类型的 backgroundTaskManager 连续任务。
 * 只在真实播放状态持有任务，暂停/完成/退出立即释放；失败静默，不影响播放。
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppContext } from '../services/AppContext';

const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'HGBackgroundPlayback';

export class BackgroundPlayback {
  private static running: boolean = false;
  private static starting: boolean = false;

  static isRunning(): boolean {
    return BackgroundPlayback.running;
  }

  /** 申请后台播放任务（幂等）。 */
  static async start(): Promise<void> {
    if (BackgroundPlayback.running || BackgroundPlayback.starting || !AppContext.isReady()) {
      return;
    }
    BackgroundPlayback.starting = true;
    try {
      const context: common.UIAbilityContext = AppContext.abilityContext();
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
      BackgroundPlayback.running = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'background task started');
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'background task start failed');
    } finally {
      BackgroundPlayback.starting = false;
    }
  }

  /** 释放后台播放任务（幂等）。 */
  static async stop(): Promise<void> {
    if (!BackgroundPlayback.running || !AppContext.isReady()) {
      return;
    }
    BackgroundPlayback.running = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(AppContext.abilityContext());
      hilog.info(LOG_DOMAIN, LOG_TAG, 'background task stopped');
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'background task stop failed');
    }
  }
}
