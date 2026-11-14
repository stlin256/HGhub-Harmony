#!/usr/bin/env node
/**
 * 构建期 overlay 应用器（公开）。
 *
 * 私有构建：把 scripts/harmony/.local/overlays/ 下的真实实现覆盖到工程同路径；
 * 公开 clone 没有 overlay 目录时为空操作。构建结束后由 build.ps1 调用 --restore 恢复公开占位。
 *
 * 目录约定：overlay 文件相对 scripts/harmony/.local/overlays/ 的路径即相对
 * harmony/entry/src/main/ets/ 的路径（也兼容带 harmony/entry/src/main/ets/ 前缀的写法）：
 *   .local/overlays/services/RuntimeConfig.ets      -> ets/services/RuntimeConfig.ets
 *   .local/overlays/components/NoticeDialog.ets     -> ets/components/NoticeDialog.ets
 *
 * 用法：
 *   node scripts/harmony/set-overlays.mjs            # 应用（先自愈上次残留备份，再备份并覆盖）
 *   node scripts/harmony/set-overlays.mjs --restore  # 恢复公开占位并清理备份
 *
 * 复制规则：只覆盖 .ets/.ts 源码；跳过 test/、node_modules/、build/、点目录与文档/测试脚本。
 * 备份目录（不入库）：scripts/harmony/.local/.overlay-backup/
 * 可用 HG_OVERLAYS_DIR / HG_OVERLAY_BACKUP_DIR 覆盖，便于隔离测试。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const ETS_ROOT = path.join(ROOT, 'harmony', 'entry', 'src', 'main', 'ets');
const OVERLAY_DIR = process.env.HG_OVERLAYS_DIR || path.join(HERE, '.local', 'overlays');
const BACKUP_DIR = process.env.HG_OVERLAY_BACKUP_DIR || path.join(HERE, '.local', '.overlay-backup');
const ETS_PREFIX = 'harmony/entry/src/main/ets/';

function rel(p) {
  return path.relative(ROOT, p).replace(/\\/g, '/');
}

/** 跳过依赖/测试/构建产物目录（overlay 只需源码，文档与测试脚本不进入工程）。 */
const SKIP_DIRS = new Set(['node_modules', 'test', 'tests', 'build', 'dist']);

/** 只收集 .ets/.ts 源码文件；其余文件（manifest/README/测试脚本等）忽略。 */
function walkFiles(dir, acc) {
  for (const item of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, item.name);
    if (item.isDirectory()) {
      const lower = item.name.toLowerCase();
      if (item.name.startsWith('.') || SKIP_DIRS.has(lower)) {
        continue;
      }
      walkFiles(p, acc);
    } else if (item.isFile()) {
      const lower = item.name.toLowerCase();
      if (lower.endsWith('.ets') || lower.endsWith('.ts')) {
        acc.push(p);
      }
    }
  }
  return acc;
}

/** overlay 文件 → 工程内目标路径（统一转换成正斜杠相对路径避免平台差异）。 */
function targetOf(overlayFile) {
  let relative = path.relative(OVERLAY_DIR, overlayFile).replace(/\\/g, '/');
  if (relative.startsWith(ETS_PREFIX)) {
    relative = relative.substring(ETS_PREFIX.length);
  }
  if (relative.length === 0 || relative.startsWith('..') || relative.indexOf('../') >= 0) {
    throw new Error('overlay 路径非法：' + overlayFile);
  }
  const target = path.join(ETS_ROOT, relative);
  if (!fs.existsSync(target) || !fs.statSync(target).isFile()) {
    throw new Error('overlay 目标公开文件不存在：' + rel(target));
  }
  return target;
}

function backupPathOf(target) {
  const relative = path.relative(ETS_ROOT, target).replace(/\\/g, '/');
  return path.join(BACKUP_DIR, relative);
}

function copyFile(source, target) {
  fs.mkdirSync(path.dirname(target), { recursive: true });
  let text = fs.readFileSync(source, 'utf8');
  // 私有构建注入包构建时间（用于 45 天可用期门禁）；公开占位不含该常量。
  if (text.indexOf('const BUILD_EPOCH_MS: number = 0;') >= 0) {
    text = text.replace('const BUILD_EPOCH_MS: number = 0;',
      'const BUILD_EPOCH_MS: number = ' + Date.now() + ';');
  }
  fs.writeFileSync(target, text, 'utf8');
}

function restore() {
  if (!fs.existsSync(BACKUP_DIR)) {
    console.log('[set-overlays] 无备份（公开占位状态，无需恢复）：' + rel(BACKUP_DIR));
    return;
  }
  const files = walkFiles(BACKUP_DIR, []);
  for (const file of files) {
    const relative = path.relative(BACKUP_DIR, file).replace(/\\/g, '/');
    const target = path.join(ETS_ROOT, relative);
    copyFile(file, target);
  }
  fs.rmSync(BACKUP_DIR, { recursive: true, force: true });
  console.log('[set-overlays] 已恢复公开占位 ' + files.length + ' 个文件');
}

function apply() {
  if (fs.existsSync(BACKUP_DIR)) {
    console.log('[set-overlays] 检测到上次构建残留备份，先恢复公开占位');
    restore();
  }
  if (!fs.existsSync(OVERLAY_DIR) || !fs.statSync(OVERLAY_DIR).isDirectory()) {
    console.log('[set-overlays] 无私有 overlay 目录，公开占位保持不变：' + rel(OVERLAY_DIR));
    return;
  }
  const files = walkFiles(OVERLAY_DIR, []);
  if (files.length === 0) {
    console.log('[set-overlays] 私有 overlay 目录为空，公开占位保持不变');
    return;
  }
  const applied = [];
  try {
    for (const file of files) {
      const target = targetOf(file);
      const backup = backupPathOf(target);
      if (!fs.existsSync(backup)) {
        copyFile(target, backup);
      }
      copyFile(file, target);
      applied.push(rel(target));
    }
  } catch (err) {
    restore();
    throw err;
  }
  console.log('[set-overlays] 已覆盖 ' + applied.length + ' 个文件：');
  for (const item of applied) {
    console.log('  ' + item);
  }
}

function main() {
  const arg = process.argv[2] || '';
  try {
    if (arg === '--restore') {
      restore();
      return;
    }
    if (arg.length > 0) {
      throw new Error('未知参数：' + arg + '（可用：--restore）');
    }
    apply();
  } catch (err) {
    console.error('[set-overlays] ' + (err && err.message ? err.message : String(err)));
    process.exit(1);
  }
}

main();
