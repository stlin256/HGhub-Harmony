import assert from 'node:assert/strict';
import { test } from 'node:test';

import worker, { sha256Hex, timingSafeEqual, verifySignature } from '../src/index.js';

/** 极简 D1 内存替身：只实现 Worker 实际用到的几条 SQL。 */
function makeDB() {
  const devices = new Map();
  const rates = new Map();
  return {
    devices,
    rates,
    prepare(sql) {
      let args = [];
      const stmt = {
        bind(...a) {
          args = a;
          return stmt;
        },
        async first() {
          if (sql.includes('COUNT(*) AS n FROM devices')) {
            return { n: devices.size };
          }
          if (sql.includes('SELECT count, expires_at FROM rate_limits')) {
            const r = rates.get(args[0]);
            return r ? { count: r.count, expires_at: r.expires_at } : null;
          }
          return null;
        },
        async all() {
          return { results: [] };
        },
        async run() {
          if (sql.includes('INSERT INTO devices')) {
            const [idHash, version, model, os, first, last] = args;
            const cur = devices.get(idHash);
            devices.set(idHash, {
              version,
              model,
              os,
              first_seen_epoch: cur ? cur.first_seen_epoch : first,
              last_seen_epoch: last,
              report_count: (cur ? cur.report_count : 0) + 1,
            });
            return { success: true };
          }
          if (sql.includes('INSERT INTO rate_limits')) {
            rates.set(args[0], { count: 1, expires_at: args[1] });
            return { success: true };
          }
          if (sql.includes('UPDATE rate_limits')) {
            const r = rates.get(args[0]);
            if (r) r.count += 1;
            return { success: true };
          }
          return { success: true };
        },
      };
      return stmt;
    },
  };
}

const ctx = { waitUntil() {} };
const UUID = '3f2504e0-4f89-41d3-9a0c-0305e82c3301';

function env(extra = {}) {
  return { DB: makeDB(), HASH_SALT: 'test-salt', STATS_KEY: 'k', ...extra };
}

function post(body, headers = {}) {
  return new Request('https://w/v1/install', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

test('sha256Hex 稳定且为 64 位十六进制', async () => {
  const a = await sha256Hex('abc');
  const b = await sha256Hex('abc');
  assert.equal(a, b);
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.notEqual(a, await sha256Hex('abd'));
});

test('timingSafeEqual 只对完全相同的串返回 true', () => {
  assert.equal(timingSafeEqual('abc', 'abc'), true);
  assert.equal(timingSafeEqual('abc', 'abd'), false);
  assert.equal(timingSafeEqual('abc', 'abcd'), false);
});

test('首次上报计入设备数', async () => {
  const e = env();
  const res = await worker.fetch(post({ id: UUID, ver: '2.2.0', model: 'ALN-AL00', os: 'HarmonyOS 7' }), e, ctx);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.counted, true);
  assert.equal(e.DB.devices.size, 1);
});

test('同一设备重复上报不增加设备数（去重）', async () => {
  const e = env();
  const payload = { id: UUID, ver: '2.2.0', model: 'ALN-AL00', os: 'HarmonyOS 7' };
  await worker.fetch(post(payload), e, ctx);
  // 同一天第二次上报被设备日配额拦截，但仍然返回 200 且不新增设备
  const second = await worker.fetch(post(payload), e, ctx);
  assert.equal(second.status, 200);
  const body = await second.json();
  assert.equal(body.counted, false);
  assert.equal(e.DB.devices.size, 1);
});

test('不同设备累加计数', async () => {
  const e = env();
  await worker.fetch(post({ id: UUID, ver: '2.2.0' }), e, ctx);
  await worker.fetch(post({ id: '3f2504e0-4f89-41d3-9a0c-0305e82c3302', ver: '2.2.0' }), e, ctx);
  assert.equal(e.DB.devices.size, 2);
});

test('非法 UUID / 版本号被拒绝', async () => {
  const e = env();
  assert.equal((await worker.fetch(post({ id: 'not-a-uuid', ver: '2.2.0' }), e, ctx)).status, 400);
  assert.equal((await worker.fetch(post({ id: UUID, ver: 'x.y' }), e, ctx)).status, 400);
  assert.equal((await worker.fetch(post({ id: UUID, ver: '2.2.0', model: '<script>' }), e, ctx)).status, 400);
});

test('超大请求体被拒绝', async () => {
  const e = env();
  const big = JSON.stringify({ id: UUID, ver: '2.2.0', model: 'A'.repeat(2000) });
  const res = await worker.fetch(post(big), e, ctx);
  assert.equal(res.status, 413);
});

test('坏 JSON 被拒绝', async () => {
  const e = env();
  const res = await worker.fetch(post('{not json'), e, ctx);
  assert.equal(res.status, 400);
});

test('徽章返回 shields.io endpoint 格式', async () => {
  const e = env();
  await worker.fetch(post({ id: UUID, ver: '2.2.0' }), e, ctx);
  const res = await worker.fetch(new Request('https://w/badge'), e, ctx);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.schemaVersion, 1);
  assert.equal(body.message, '1');
  assert.ok(body.label.length > 0);
});

test('统计接口需要正确 key', async () => {
  const e = env();
  assert.equal((await worker.fetch(new Request('https://w/stats?key=wrong'), e, ctx)).status, 403);
  assert.equal((await worker.fetch(new Request('https://w/stats?key=k'), e, ctx)).status, 200);
});

test('HMAC 签名：正确通过、过期与错误被拒', async () => {
  const secret = 's3cret';
  const now = Math.floor(Date.now() / 1000);
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', key, enc.encode(`${now}.${UUID}.2.2.0`));
  const sig = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');

  assert.equal(await verifySignature(secret, String(now), UUID, '2.2.0', sig, now), true);
  assert.equal(await verifySignature(secret, String(now - 600), UUID, '2.2.0', sig, now), false);
  assert.equal(await verifySignature(secret, String(now), UUID, '2.2.0', 'deadbeef', now), false);

  const e = env({ SHARED_SECRET: secret });
  const ok = await worker.fetch(
    post({ id: UUID, ver: '2.2.0' }, { 'x-client-ts': String(now), 'x-client-sig': sig }), e, ctx);
  assert.equal(ok.status, 200);

  const bad = await worker.fetch(
    post({ id: UUID, ver: '2.2.0' }, { 'x-client-ts': String(now), 'x-client-sig': 'deadbeef' }), e, ctx);
  assert.equal(bad.status, 401);
});

test('CORS 预检返回 204', async () => {
  const res = await worker.fetch(new Request('https://w/v1/install', { method: 'OPTIONS' }), env(), ctx);
  assert.equal(res.status, 204);
  assert.equal(res.headers.get('access-control-allow-origin'), '*');
});
