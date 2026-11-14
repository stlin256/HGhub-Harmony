#!/usr/bin/env node
/**
 * 构建期扩展 overlay 生成器（公开）。
 *
 * 本地扩展源码目录（不入库）：scripts/harmony/.local/extensions/
 *   - 可用环境变量 HG_EXTENSIONS_DIR 覆盖，便于验证公开 clone 场景。
 * 复制目标（不入库）：harmony/entry/src/main/ets/runtime/private-ext/
 * 注册文件（入库占位）：harmony/entry/src/main/ets/runtime/Extensions.local.ets
 *
 * 用法：
 *   node scripts/harmony/set-extensions.mjs            # 生成：有本地目录则复制并注册，否则写空占位
 *   node scripts/harmony/set-extensions.mjs --restore  # 恢复公开空占位并清理生成目录
 *
 * 约定（每个一级子目录为一个扩展）：
 *   - 默认入口 <PascalName>Extension.ets，导出同名类，无参构造；
 *   - 可用子目录内 extension.json 覆盖：{"entry":"XxxExtension.ets","class":"XxxExtension"}；
 *   - 没有入口文件的子目录只复制不注册（可放共享代码）。
 *
 * 复制规则：只复制 .ets/.ts 源码文件；跳过 test/、node_modules/、.build*、.git 等目录，
 * 以及 *.md、*.mjs、*.json 等非源码文件（extension.json 只在源目录读取，不复制）。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const SRC_DIR = process.env.HG_EXTENSIONS_DIR || path.join(HERE, '.local', 'extensions');
const ETS_ROOT = path.join(ROOT, 'harmony', 'entry', 'src', 'main', 'ets');
const RUNTIME_DIR = path.join(ETS_ROOT, 'runtime');
const OUT_DIR = path.join(RUNTIME_DIR, 'private-ext');
const TARGET = path.join(RUNTIME_DIR, 'Extensions.local.ets');

const PLACEHOLDER = [
  '// 本文件由 scripts/harmony/set-extensions.mjs 生成；公开构建保留空实现，构建时可被本地扩展覆盖。',
  "import { ExtensionHost } from './ExtensionHost';",
  '',
  '/** 注册构建期内置扩展；公开构建没有任何扩展。 */',
  'export function registerLocalExtensions(host: ExtensionHost): void {',
  '}',
  ''
].join('\n');

function rel(p) {
  return path.relative(ROOT, p).replace(/\\/g, '/');
}

function fail(message) {
  throw new Error(message);
}

function pascal(name) {
  return name
    .split(/[^A-Za-z0-9]+/)
    .filter((part) => part.length > 0)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join('');
}

function isIdent(value) {
  return /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(value);
}

function readManifest(dir) {
  const file = path.join(dir, 'extension.json');
  if (!fs.existsSync(file)) {
    return null;
  }
  let data = null;
  try {
    data = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    fail('extension.json 解析失败：' + rel(file) + '（' + err.message + '）');
  }
  if (data === null || typeof data !== 'object' || Array.isArray(data)) {
    fail('extension.json 必须是对象：' + rel(file));
  }
  return data;
}

/** 扫描一级子目录：有入口文件的登记为扩展，其余只复制。 */
function discover(srcDir) {
  const entries = [];
  const items = fs.readdirSync(srcDir, { withFileTypes: true });
  for (const item of items) {
    if (!item.isDirectory() || item.name.startsWith('.') || item.name === 'node_modules') {
      continue;
    }
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(item.name)) {
      fail('扩展目录名只允许字母/数字/._-：' + item.name);
    }
    const dir = path.join(srcDir, item.name);
    const manifest = readManifest(dir);
    let entry = '';
    let className = '';
    if (manifest !== null) {
      entry = typeof manifest.entry === 'string' ? manifest.entry.trim() : '';
      className = typeof manifest.class === 'string' ? manifest.class.trim() : '';
      if (entry.length === 0 || className.length === 0) {
        fail('extension.json 缺少 entry/class：' + rel(path.join(dir, 'extension.json')));
      }
    } else {
      className = pascal(item.name) + 'Extension';
      entry = className + '.ets';
    }
    if (!isIdent(className)) {
      fail('扩展类名不合法：' + className + '（目录 ' + item.name + '）');
    }
    if (!/^[A-Za-z0-9_][A-Za-z0-9_.-]*\.ets$/.test(entry) || entry.indexOf('..') >= 0) {
      fail('扩展入口文件名不合法：' + entry + '（目录 ' + item.name + '）');
    }
    if (!fs.existsSync(path.join(dir, entry))) {
      console.log('[set-extensions] 跳过（无入口文件）：' + item.name);
      continue;
    }
    entries.push({
      dir: item.name,
      className,
      entry: entry.slice(0, -4)
    });
  }
  entries.sort((a, b) => (a.dir < b.dir ? -1 : a.dir > b.dir ? 1 : 0));
  return entries;
}

function buildRegistration(entries) {
  const lines = [
    '// 本文件由 scripts/harmony/set-extensions.mjs 生成；构建结束后会恢复公开空占位，请勿手工编辑。',
    "import { ExtensionHost } from './ExtensionHost';"
  ];
  for (const entry of entries) {
    lines.push('import { ' + entry.className + " } from './private-ext/" + entry.dir + '/' + entry.entry + "';");
  }
  lines.push('');
  lines.push('/** 注册构建期内置扩展。 */');
  lines.push('export function registerLocalExtensions(host: ExtensionHost): void {');
  for (const entry of entries) {
    lines.push('  host.register(new ' + entry.className + '());');
  }
  lines.push('}');
  lines.push('');
  return lines.join('\n');
}

/** 要整体跳过的目录名（.build* 等点目录由 isAllowed 中的点前缀规则统一跳过）。 */
const SKIP_DIRS = new Set(['node_modules', 'test', 'tests', 'build', 'dist', 'out']);

/** 是否为需要复制到工程内的源码文件（只保留 ArkTS/TS 源码）。 */
function isSourceFile(name) {
  const lower = name.toLowerCase();
  return lower.endsWith('.ets') || lower.endsWith('.ts');
}

function copySource(srcDir, outDir) {
  fs.cpSync(srcDir, outDir, {
    recursive: true,
    dereference: false,
    filter: (source) => {
      const name = path.basename(source);
      let stat = null;
      try {
        stat = fs.lstatSync(source);
      } catch (err) {
        return false;
      }
      if (stat.isDirectory()) {
        const lower = name.toLowerCase();
        return !name.startsWith('.') && !SKIP_DIRS.has(lower);
      }
      return isSourceFile(name);
    }
  });
}

function writePlaceholder() {
  fs.mkdirSync(RUNTIME_DIR, { recursive: true });
  fs.writeFileSync(TARGET, PLACEHOLDER, 'utf8');
}

function generate() {
  fs.mkdirSync(RUNTIME_DIR, { recursive: true });
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  if (!fs.existsSync(SRC_DIR) || !fs.statSync(SRC_DIR).isDirectory()) {
    writePlaceholder();
    console.log('[set-extensions] 无本地扩展目录，写入空占位：' + rel(TARGET));
    return;
  }
  const entries = discover(SRC_DIR);
  copySource(SRC_DIR, OUT_DIR);
  if (entries.length === 0) {
    writePlaceholder();
    console.log('[set-extensions] 本地扩展目录无注册入口，写入空占位：' + rel(TARGET));
    return;
  }
  fs.writeFileSync(TARGET, buildRegistration(entries), 'utf8');
  console.log('[set-extensions] 已复制本地扩展到 ' + rel(OUT_DIR) + '，注册 ' + entries.length + ' 个：' + entries.map((e) => e.dir).join(', '));
  console.log('[set-extensions] 写入注册文件：' + rel(TARGET));
}

function restore() {
  writePlaceholder();
  fs.rmSync(OUT_DIR, { recursive: true, force: true });
  console.log('[set-extensions] 已恢复公开空占位并清理 ' + rel(OUT_DIR));
}

function main() {
  const arg = process.argv[2] || '';
  try {
    if (arg === '--restore') {
      restore();
      return;
    }
    if (arg.length > 0) {
      fail('未知参数：' + arg + '（可用：--restore）');
    }
    generate();
  } catch (err) {
    try {
      writePlaceholder();
      fs.rmSync(OUT_DIR, { recursive: true, force: true });
    } catch (cleanupErr) {
    }
    console.error('[set-extensions] ' + (err && err.message ? err.message : String(err)));
    process.exit(1);
  }
}

main();
