#!/usr/bin/env node
/**
 * 写入编译期分发渠道：harmony/entry/src/main/ets/utils/BuildChannel.local.ets
 * 用法：node scripts/harmony/set-channel.mjs github
 * 该文件不入库；未传参数时写入 official。
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const TARGET = join(ROOT, 'harmony', 'entry', 'src', 'main', 'ets', 'utils', 'BuildChannel.local.ets');
const raw = process.argv[2] !== undefined ? process.argv[2].trim() : 'official';
const channel = raw.length > 0 ? raw : 'official';
if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(channel)) {
  console.error('[set-channel] 渠道名只允许小写字母/数字/_/-，长度 1-32：' + channel);
  process.exit(1);
}
mkdirSync(dirname(TARGET), { recursive: true });
writeFileSync(TARGET,
  "// 构建时由 scripts/harmony/set-channel.mjs 覆盖；默认值入库以兼容 CI/IDE。\n" +
  "export const BUILD_CHANNEL: string = '" + channel + "';\n",
  'utf8');
console.log('[set-channel] BUILD_CHANNEL = ' + channel);
