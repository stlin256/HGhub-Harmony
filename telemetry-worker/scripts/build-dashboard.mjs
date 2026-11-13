#!/usr/bin/env node
/**
 * 把 src/dashboard.html 转成 src/dashboard.generated.js。
 *
 * 为什么需要这一步：Worker 运行时可以直接 import HTML（wrangler Text 规则），
 * 但 Node 的测试环境不认识 .html 后缀。生成一个 JS 模块后，两边都能加载，
 * 且 dashboard.html 仍是唯一事实源。
 *
 * 用法：node scripts/build-dashboard.mjs
 * CI 会校验生成结果与仓库内文件一致（防止改了 html 忘了重新生成）。
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const htmlPath = join(root, 'src', 'dashboard.html');
const outPath = join(root, 'src', 'dashboard.generated.js');

const html = readFileSync(htmlPath, 'utf8');
const out = `// 由 scripts/build-dashboard.mjs 从 dashboard.html 生成，请勿手改。
export default ${JSON.stringify(html)};
`;
writeFileSync(outPath, out, 'utf8');
console.log(`generated ${outPath} (${html.length} bytes)`);
