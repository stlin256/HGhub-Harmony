import { describe, it, expect } from '@ohos/hypium';
import { fmt, fmtTime } from '../../main/ets/utils/Format';

export default function formatTest() {
  describe('Format', () => {
    it('fmt_wan', 0, () => {
      expect(fmt(12345)).assertEqual('1.2万');
    });
    it('fmt_yi', 0, () => {
      expect(fmt(123456789)).assertEqual('1.2亿');
    });
    it('fmt_small', 0, () => {
      expect(fmt(999)).assertEqual('999');
    });
    it('fmt_null', 0, () => {
      expect(fmt(undefined)).assertEqual('0');
    });
    it('fmtTime_normal', 0, () => {
      expect(fmtTime(65)).assertEqual('1:05');
    });
    it('fmtTime_negative', 0, () => {
      expect(fmtTime(-1)).assertEqual('0:00');
    });
  });
}
