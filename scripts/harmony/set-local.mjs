#!/usr/bin/env node
/**
 * 从本地配置文件生成本地/上游注入常量。
 *
 * 配置文件：scripts/harmony/.local/local-config.json（已 gitignore，不入库）
 * 生成物：harmony/entry/src/main/ets/services/LocalUpstream.local.ets
 *
 * 未配置时生成空占位，保证 CI/全新 clone 可编译；本地正式构建前写入真实值。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const CFG = process.env.HG_LOCAL_CONFIG || path.join(HERE, '.local', 'local-config.json');
const OUT = path.join(ROOT, 'harmony', 'entry', 'src', 'main', 'ets', 'services', 'LocalUpstream.local.ets');

function str(value, fallback = '') {
  return typeof value === 'string' ? value.trim() : fallback;
}
function list(value) {
  return Array.isArray(value) ? value.filter((v) => typeof v === 'string' && v.trim().length > 0).map((v) => v.trim()) : [];
}

let cfg = {};
try {
  cfg = JSON.parse(fs.readFileSync(CFG, 'utf8'));
  console.log('[set-local] loaded ' + CFG);
} catch {
  console.log('[set-local] config missing, writing empty placeholders: ' + CFG);
}
const upstream = cfg.upstream && typeof cfg.upstream === 'object' ? cfg.upstream : {};
const values = {
  UPSTREAM_DEFAULT_BASE: str(upstream.defaultBase),
  UPSTREAM_FIXED_LINES: list(upstream.fixedLines),
  UPSTREAM_PUBLISH_PAGE: str(upstream.publishPage),
  UPSTREAM_CANONICAL_HOST: str(upstream.canonicalHost),
  UPSTREAM_CLIPBOARD_HOSTS: list(upstream.clipboardHosts),
  UPSTREAM_COVER_REFERER: str(upstream.coverReferer)
};
const lines = [
  '// 本文件由 scripts/harmony/set-local.mjs 生成；默认占位可入库，构建时被本地配置覆盖。',
  'export const UPSTREAM_DEFAULT_BASE: string = ' + JSON.stringify(values.UPSTREAM_DEFAULT_BASE) + ';',
  'export const UPSTREAM_FIXED_LINES: string[] = ' + JSON.stringify(values.UPSTREAM_FIXED_LINES) + ';',
  'export const UPSTREAM_PUBLISH_PAGE: string = ' + JSON.stringify(values.UPSTREAM_PUBLISH_PAGE) + ';',
  'export const UPSTREAM_CANONICAL_HOST: string = ' + JSON.stringify(values.UPSTREAM_CANONICAL_HOST) + ';',
  'export const UPSTREAM_CLIPBOARD_HOSTS: string[] = ' + JSON.stringify(values.UPSTREAM_CLIPBOARD_HOSTS) + ';',
  'export const UPSTREAM_COVER_REFERER: string = ' + JSON.stringify(values.UPSTREAM_COVER_REFERER) + ';',
  ''
];
fs.writeFileSync(OUT, lines.join('\n'), 'utf8');
console.log('[set-local] wrote ' + OUT);
