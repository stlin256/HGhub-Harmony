#!/usr/bin/env node
/**
 * 切换编译期变体：release / test。
 *
 * 用法：
 *   node scripts/harmony/set-variant.mjs test
 *   node scripts/harmony/set-variant.mjs release
 *
 * 直接改写 harmony/entry/src/main/ets/utils/BuildVariant.ets 中的
 * IS_TEST_VARIANT / VARIANT_NAME 两个常量，幂等。
 *
 * 发布前必须切回 release —— CI 的 scripts/check/variant_check.py 会拦截 test 变体。
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const TARGET = join(ROOT, 'harmony', 'entry', 'src', 'main', 'ets', 'utils', 'BuildVariant.ets');

const VARIANTS = {
  release: { isTest: false, name: 'release' },
  test: { isTest: true, name: 'test' },
};

// 锚定到声明行（^ + m），避免把注释里的示例文字也改掉。
const IS_TEST_RE = /^(export const IS_TEST_VARIANT\s*:\s*boolean\s*=\s*)(?:true|false)(\s*;)/m;
const VARIANT_NAME_RE = /^(export const VARIANT_NAME\s*:\s*string\s*=\s*')(?:release|test)(')(\s*;)/m;

function fail(message) {
  console.error(`[set-variant] 失败：${message}`);
  process.exit(1);
}

const variant = process.argv[2];
if (!variant || !Object.prototype.hasOwnProperty.call(VARIANTS, variant)) {
  fail(`用法：node scripts/harmony/set-variant.mjs <release|test>（收到：${variant === undefined ? '空' : variant}）`);
}
const target = VARIANTS[variant];

let text;
try {
  text = readFileSync(TARGET, 'utf8');
} catch (err) {
  fail(`读取 ${TARGET} 失败：${err.message}`);
}

const next = text
  .replace(IS_TEST_RE, `$1${target.isTest}$2`)
  .replace(VARIANT_NAME_RE, `$1${target.name}$2$3`);

if (next === text) {
  console.log(`[set-variant] 当前已是 ${variant} 变体，无需修改`);
} else {
  writeFileSync(TARGET, next, 'utf8');
  console.log(`[set-variant] 已切换为 ${variant} 变体（IS_TEST_VARIANT = ${target.isTest}）`);
}

// 回读校验：两个常量必须都落到目标值，避免只改到一半。
const check = readFileSync(TARGET, 'utf8');
const isTest = check.match(/^export const IS_TEST_VARIANT\s*:\s*boolean\s*=\s*(true|false)\s*;/m);
const name = check.match(/^export const VARIANT_NAME\s*:\s*string\s*=\s*'([^']+)'/m);
if (!isTest || !name) {
  fail('BuildVariant.ets 中未找到 IS_TEST_VARIANT / VARIANT_NAME，文件可能被改动');
}
if (isTest[1] !== String(target.isTest) || name[1] !== target.name) {
  fail(`回读校验不一致：IS_TEST_VARIANT=${isTest[1]}，VARIANT_NAME=${name[1]}`);
}

if (variant === 'release') {
  console.log('[set-variant] 当前为发布变体 release，可以提交/发布');
} else {
  console.log('[set-variant] 当前为测试变体 test，仅用于联调；发布前必须执行 release 切回');
}
