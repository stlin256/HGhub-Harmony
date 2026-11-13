#!/usr/bin/env node
/**
 * 生成编译期服务器端点（IP:端口 + 128 位接入密钥）。
 *
 * 生成物：harmony/entry/src/main/ets/services/ServerEndpoint.local.ets
 *   - 已加入 .gitignore：服务器 IP / 端口 / 接入密钥都不入库；
 *   - 内容为 XOR 混淆后的字节数组，源码里不出现明文；
 *   - 运行期由 services/ServerEndpoint.ets 解码。
 *
 * 用法：
 *   node scripts/harmony/set-server.mjs --ip 1.2.3.4 --port 8443 --key <32位hex>
 *   node scripts/harmony/set-server.mjs --placeholder   # CI 占位（127.0.0.1 + 全零 key）
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..', '..');
const OUT = path.join(ROOT, 'harmony', 'entry', 'src', 'main', 'ets', 'services', 'ServerEndpoint.local.ets');

/** 与 services/ServerEndpoint.ets 保持一致：第 i 字节的掩码 = (0x5A + i*31) & 0xFF。 */
const OBF_KEY = 0x5a;
const OBF_STEP = 31;

function parseArgs(argv) {
  const args = { ip: '', port: 0, key: '', placeholder: false };
  for (let i = 2; i < argv.length; i++) {
    const name = argv[i];
    const value = argv[i + 1];
    if (name === '--ip') { args.ip = value || ''; i++; }
    else if (name === '--port') { args.port = Number(value); i++; }
    else if (name === '--key') { args.key = (value || '').toLowerCase(); i++; }
    else if (name === '--placeholder') { args.placeholder = true; }
    else if (name === '--help' || name === '-h') { args.help = true; }
    else { throw new Error('未知参数: ' + name); }
  }
  return args;
}

function encode(text) {
  const bytes = [];
  for (let i = 0; i < text.length; i++) {
    const mask = (OBF_KEY + i * OBF_STEP) & 0xff;
    bytes.push((text.charCodeAt(i) ^ mask) & 0xff);
  }
  return bytes;
}

function toArrayLiteral(name, bytes) {
  const lines = [];
  for (let i = 0; i < bytes.length; i += 16) {
    lines.push('  ' + bytes.slice(i, i + 16).join(', '));
  }
  return 'export const ' + name + ': number[] = [\n' + lines.join(',\n') + '\n];\n';
}

function main() {
  const args = parseArgs(process.argv);
  if (args.help) {
    console.log('用法: node scripts/harmony/set-server.mjs --ip <ipv4> --port <1-65535> --key <32位hex>');
    console.log('      node scripts/harmony/set-server.mjs --placeholder');
    return;
  }
  if (args.placeholder) {
    args.ip = '127.0.0.1';
    args.port = 8443;
    args.key = '0'.repeat(32);
  }
  if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(args.ip) ||
    args.ip.split('.').some((part) => Number(part) > 255)) {
    throw new Error('--ip 必须是合法 IPv4 地址');
  }
  if (!Number.isInteger(args.port) || args.port < 1 || args.port > 65535) {
    throw new Error('--port 必须是 1-65535 的整数');
  }
  if (!/^[0-9a-f]{32}$/.test(args.key)) {
    throw new Error('--key 必须是 32 位十六进制（128 位）');
  }

  const url = 'https://' + args.ip + ':' + args.port;
  const content = [
    '// 本文件由 scripts/harmony/set-server.mjs 生成，勿手改、勿入库（见 .gitignore）。',
    '// 内容为 XOR 混淆后的 UTF-8 字节，运行期由 ServerEndpoint.ets 解码。',
    '',
    toArrayLiteral('SERVER_URL_OBF', encode(url)),
    toArrayLiteral('CLIENT_KEY_OBF', encode(args.key))
  ].join('\n');
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, content, 'utf8');
  console.log('已生成 ' + path.relative(ROOT, OUT) + '（' + url + '，密钥 128 位）');
}

try {
  main();
} catch (err) {
  console.error('生成失败: ' + err.message);
  process.exit(1);
}
