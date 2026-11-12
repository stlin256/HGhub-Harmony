import { describe, it, expect } from '@ohos/hypium';
import { PlayerQuality } from '../../main/ets/player/PlayerQuality';
import { PlaybackInfo, PlaybackStreams } from '../../main/ets/models/Types';

function info(main: string, hevc: string): PlaybackInfo {
  const streams: PlaybackStreams = { main: main, hevc: hevc };
  const result: PlaybackInfo = { streams: streams };
  return result;
}

export default function playerQualityTest() {
  describe('PlayerQuality', () => {
    it('hasHevc_true', 0, () => {
      expect(PlayerQuality.hasHevc(info('m3u8-main', 'm3u8-hevc'))).assertTrue();
    });
    it('hasHevc_false_when_empty', 0, () => {
      expect(PlayerQuality.hasHevc(info('m3u8-main', ''))).assertFalse();
    });
    it('hasHevc_false_when_undefined', 0, () => {
      expect(PlayerQuality.hasHevc(undefined)).assertFalse();
    });
    it('streamUrl_prefers_hevc', 0, () => {
      expect(PlayerQuality.streamUrl(info('main', 'hevc'), true)).assertEqual('hevc');
    });
    it('streamUrl_falls_back_main', 0, () => {
      expect(PlayerQuality.streamUrl(info('main', ''), true)).assertEqual('main');
    });
    it('streamUrl_standard', 0, () => {
      expect(PlayerQuality.streamUrl(info('main', 'hevc'), false)).assertEqual('main');
    });
    it('retryable_network', 0, () => {
      expect(PlayerQuality.isRetryable(-1, '网络异常')).assertTrue();
    });
    it('retryable_http5xx', 0, () => {
      expect(PlayerQuality.isRetryable(-1, 'HTTP 502: bad gateway')).assertTrue();
    });
    it('retryable_io_code', 0, () => {
      expect(PlayerQuality.isRetryable(5400103, 'io')).assertTrue();
    });
    it('not_retryable_401', 0, () => {
      expect(PlayerQuality.isRetryable(-1, '401')).assertFalse();
    });
    it('not_retryable_no_url', 0, () => {
      expect(PlayerQuality.isRetryable(-1, '暂无播放地址')).assertFalse();
    });
    it('not_retryable_5400102', 0, () => {
      expect(PlayerQuality.isRetryable(5400102, 'operate not permit')).assertFalse();
    });
    it('retryDelay_sequence', 0, () => {
      expect(PlayerQuality.retryDelay(0)).assertEqual(500);
      expect(PlayerQuality.retryDelay(1)).assertEqual(1500);
      expect(PlayerQuality.retryDelay(2)).assertEqual(3000);
      expect(PlayerQuality.retryDelay(9)).assertEqual(3000);
    });
    it('canRetry_boundary', 0, () => {
      expect(PlayerQuality.canRetry(0)).assertTrue();
      expect(PlayerQuality.canRetry(2)).assertTrue();
      expect(PlayerQuality.canRetry(3)).assertFalse();
    });
  });
}
