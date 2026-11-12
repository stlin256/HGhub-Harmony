import formatTest from './Format.test';
import playerQualityTest from './PlayerQuality.test';
import playerSeekPolicyTest from './PlayerSeekPolicy.test';

export default function testsuite() {
  formatTest();
  playerQualityTest();
  playerSeekPolicyTest();
}
