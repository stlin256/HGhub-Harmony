import { describe, it, expect } from '@ohos/hypium';
import { PlayerSeekPolicy } from '../../main/ets/player/PlayerSeekPolicy';

export default function playerSeekPolicyTest() {
  describe('PlayerSeekPolicy', () => {
    it('seekToEnd_true', 0, () => {
      expect(PlayerSeekPolicy.isSeekToEnd(true, 96000, 100000)).assertTrue();
    });
    it('seekToEnd_false_without_move', 0, () => {
      expect(PlayerSeekPolicy.isSeekToEnd(false, 99000, 100000)).assertFalse();
    });
    it('seekToEnd_false_below_ratio', 0, () => {
      expect(PlayerSeekPolicy.isSeekToEnd(true, 90000, 100000)).assertFalse();
    });
    it('seekToEnd_false_unknown_duration', 0, () => {
      expect(PlayerSeekPolicy.isSeekToEnd(true, 5000, 0)).assertFalse();
    });
    it('canAutoNext_true', 0, () => {
      expect(PlayerSeekPolicy.canAutoNext('feed', 2, 10)).assertTrue();
    });
    it('canAutoNext_false_last', 0, () => {
      expect(PlayerSeekPolicy.canAutoNext('feed', 10, 10)).assertFalse();
    });
    it('canAutoNext_false_post', 0, () => {
      expect(PlayerSeekPolicy.canAutoNext('post', 1, 10)).assertFalse();
    });
    it('canAutoNext_false_unknown_count', 0, () => {
      expect(PlayerSeekPolicy.canAutoNext('feed', 1, 0)).assertFalse();
    });
  });
}
