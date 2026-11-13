/**
 * HGhub Harmony 匿名设备计数 Worker（Cloudflare Workers + D1）
 *
 * 目标：只回答一个问题 —— **有多少台设备启动过 App**（累积去重，不是在线数）。
 *
 * 隐私与安全设计：
 *   1. 客户端上报随机 UUID（本地生成、与硬件无关），服务端用 SHA-256(id + SALT) 后落库，
 *      原始 UUID 不持久化，也不出现在日志里。
 *   2. IP 只在内存中用于限流，落库时同样先 SHA-256(ip + SALT)。
 *   3. 不收集：OAID / IMEI / SN / MAC / 账号 / 位置 / 播放内容 / 行为轨迹。
 *   4. 限流：单 IP 每小时 30 次、单设备每天 1 次；请求体上限 1 KB；字段白名单校验。
 *   5. 可选 HMAC 签名（配置 SHARED_SECRET 后启用）：防重放窗口 300 秒，
 *      仅作为「提高刷量门槛」的手段，不是安全边界（密钥内嵌客户端可被提取）。
 *
 * 端点：
 *   POST /v1/install   上报一次启动（幂等：同一设备重复上报只更新，不增加计数）
 *   GET  /badge        shields.io endpoint 格式，供 README 徽章渲染
 *   GET  /stats?key=   聚合统计（需要 STATS_KEY）
 *   GET  /health       健康检查
 */

const MAX_BODY_BYTES = 1024;
const IP_HOURLY_LIMIT = 30;
const DEVICE_DAILY_LIMIT = 1;
const IP_WINDOW_SEC = 3600;
const DEVICE_WINDOW_SEC = 86400;
const SIG_WINDOW_SEC = 300;
const BADGE_CACHE_SEC = 3600;
const RATE_CLEANUP_EVERY = 50; // 每 N 次上报清理一次过期限流桶

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const VERSION_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){0,3}$/;
const MODEL_RE = /^[A-Za-z0-9 _\-.]{0,32}$/;
const OS_RE = /^[A-Za-z0-9 ._\-]{0,24}$/;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return withCors(new Response(null, { status: 204 }));
    }
    if (url.pathname === '/health') {
      return withCors(json({ ok: true }));
    }
    if (url.pathname === '/v1/install' && request.method === 'POST') {
      return withCors(await handleInstall(request, env, ctx));
    }
    if (url.pathname === '/badge' && request.method === 'GET') {
      return withCors(await handleBadge(env, ctx));
    }
    if (url.pathname === '/stats' && request.method === 'GET') {
      return withCors(await handleStats(url, env));
    }
    return withCors(json({ error: 'not_found' }, 404));
  },
};

/* ── 上报 ───────────────────────────────────────────── */

async function handleInstall(request, env, ctx) {
  const now = Math.floor(Date.now() / 1000);

  // 体积限制：先看声明长度，再实际读一遍兜底。
  const declared = Number(request.headers.get('content-length') || '0');
  if (declared > MAX_BODY_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }
  let raw;
  try {
    raw = await request.text();
  } catch {
    return json({ error: 'bad_body' }, 400);
  }
  if (raw.length === 0 || raw.length > MAX_BODY_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }

  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: 'bad_json' }, 400);
  }
  if (!body || typeof body !== 'object') {
    return json({ error: 'bad_json' }, 400);
  }

  // 字段白名单 + 格式校验。
  const id = typeof body.id === 'string' ? body.id.trim() : '';
  const version = typeof body.ver === 'string' ? body.ver.trim() : '';
  const model = typeof body.model === 'string' ? body.model.trim() : '';
  const os = typeof body.os === 'string' ? body.os.trim() : '';

  if (!UUID_RE.test(id)) {
    return json({ error: 'bad_id' }, 400);
  }
  if (!VERSION_RE.test(version)) {
    return json({ error: 'bad_version' }, 400);
  }
  if (model.length > 0 && !MODEL_RE.test(model)) {
    return json({ error: 'bad_model' }, 400);
  }
  if (os.length > 0 && !OS_RE.test(os)) {
    return json({ error: 'bad_os' }, 400);
  }

  // 可选 HMAC 校验（配置了 SHARED_SECRET 才启用）。
  if (env.SHARED_SECRET) {
    const ts = request.headers.get('x-client-ts') || '';
    const sig = request.headers.get('x-client-sig') || '';
    const ok = await verifySignature(env.SHARED_SECRET, ts, id, version, sig, now);
    if (!ok) {
      return json({ error: 'bad_signature' }, 401);
    }
  }

  const salt = env.HASH_SALT || 'hghub-default-salt';
  const idHash = await sha256Hex(`${id}:${salt}`);

  // 限流：单设备每天 1 次（幂等上报，超出直接 200 不再写库）。
  const day = Math.floor(now / DEVICE_WINDOW_SEC);
  const deviceBucket = `dev:${idHash}:${day}`;
  const deviceAllowed = await bumpRate(env, deviceBucket, DEVICE_DAILY_LIMIT, DEVICE_WINDOW_SEC);
  if (!deviceAllowed) {
    return json({ ok: true, counted: false, reason: 'device_quota' }, 200);
  }

  // 限流：单 IP 每小时 30 次。
  const ip = request.headers.get('cf-connecting-ip') || '';
  if (ip.length > 0) {
    const ipHash = await sha256Hex(`${ip}:${salt}`);
    const hour = Math.floor(now / IP_WINDOW_SEC);
    const ipAllowed = await bumpRate(env, `ip:${ipHash}:${hour}`, IP_HOURLY_LIMIT, IP_WINDOW_SEC);
    if (!ipAllowed) {
      return json({ error: 'rate_limited' }, 429);
    }
  }

  // 幂等写入：同一 id_hash 只算一台设备，重复上报只更新元数据。
  try {
    await env.DB.prepare(
      `INSERT INTO devices (id_hash, version, model, os, first_seen_epoch, last_seen_epoch, report_count)
       VALUES (?, ?, ?, ?, ?, ?, 1)
       ON CONFLICT(id_hash) DO UPDATE SET
         version = excluded.version,
         model = excluded.model,
         os = excluded.os,
         last_seen_epoch = excluded.last_seen_epoch,
         report_count = devices.report_count + 1`
    ).bind(idHash, version, model, os, now, now).run();
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }

  // 概率性清理过期限流桶，避免表无限增长。
  if (Math.random() < 1 / RATE_CLEANUP_EVERY) {
    ctx.waitUntil(
      env.DB.prepare('DELETE FROM rate_limits WHERE expires_at < ?').bind(now).run().catch(() => {})
    );
  }

  return json({ ok: true, counted: true }, 200);
}

/* ── 徽章 ───────────────────────────────────────────── */

async function handleBadge(env, ctx) {
  let total = 0;
  try {
    const row = await env.DB.prepare('SELECT COUNT(*) AS n FROM devices').first();
    total = row && typeof row.n === 'number' ? row.n : 0;
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
  // shields.io endpoint 格式：README 徽章直接渲染这个 JSON。
  return json(
    {
      schemaVersion: 1,
      label: 'HGhub 设备',
      message: String(total),
      color: '4D6BFE',
      cacheSeconds: BADGE_CACHE_SEC,
    },
    200,
    { 'cache-control': `public, max-age=${BADGE_CACHE_SEC}` }
  );
}

/* ── 统计 ───────────────────────────────────────────── */

async function handleStats(url, env) {
  const key = url.searchParams.get('key') || '';
  const expected = env.STATS_KEY || '';
  if (expected.length === 0 || !timingSafeEqual(key, expected)) {
    return json({ error: 'forbidden' }, 403);
  }

  const now = Math.floor(Date.now() / 1000);
  const day = 86400;
  try {
    const total = await env.DB.prepare('SELECT COUNT(*) AS n FROM devices').first();
    const active7 = await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM devices WHERE last_seen_epoch >= ?'
    ).bind(now - 7 * day).first();
    const active30 = await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM devices WHERE last_seen_epoch >= ?'
    ).bind(now - 30 * day).first();
    const new7 = await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM devices WHERE first_seen_epoch >= ?'
    ).bind(now - 7 * day).first();
    const byVersion = await env.DB.prepare(
      'SELECT version, COUNT(*) AS n FROM devices GROUP BY version ORDER BY n DESC LIMIT 20'
    ).all();
    const byModel = await env.DB.prepare(
      "SELECT COALESCE(NULLIF(model, ''), 'unknown') AS model, COUNT(*) AS n FROM devices GROUP BY model ORDER BY n DESC LIMIT 20"
    ).all();

    return json({
      devices_total: total ? total.n : 0,
      devices_active_7d: active7 ? active7.n : 0,
      devices_active_30d: active30 ? active30.n : 0,
      devices_new_7d: new7 ? new7.n : 0,
      by_version: byVersion && byVersion.results ? byVersion.results : [],
      by_model: byModel && byModel.results ? byModel.results : [],
      generated_at: new Date(now * 1000).toISOString(),
    });
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
}

/* ── 工具 ───────────────────────────────────────────── */

async function bumpRate(env, bucket, limit, ttlSec) {
  const now = Math.floor(Date.now() / 1000);
  const row = await env.DB.prepare(
    'SELECT count, expires_at FROM rate_limits WHERE bucket = ?'
  ).bind(bucket).first();

  if (!row || row.expires_at < now) {
    await env.DB.prepare(
      'INSERT INTO rate_limits (bucket, count, expires_at) VALUES (?, 1, ?) ' +
      'ON CONFLICT(bucket) DO UPDATE SET count = 1, expires_at = excluded.expires_at'
    ).bind(bucket, now + ttlSec).run();
    return true;
  }
  if (row.count >= limit) {
    return false;
  }
  await env.DB.prepare('UPDATE rate_limits SET count = count + 1 WHERE bucket = ?')
    .bind(bucket).run();
  return true;
}

async function sha256Hex(text) {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function verifySignature(secret, ts, id, version, sig, now) {
  const tsNum = Number(ts);
  if (!Number.isFinite(tsNum) || Math.abs(now - tsNum) > SIG_WINDOW_SEC) {
    return false;
  }
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const mac = await crypto.subtle.sign('HMAC', key, enc.encode(`${ts}.${id}.${version}`));
  const expected = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
  return timingSafeEqual(expected, sig.toLowerCase());
}

/** 常数时间字符串比较（长度不同直接 false）。 */
function timingSafeEqual(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

function json(obj, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      ...extraHeaders,
    },
  });
}

function withCors(response) {
  const headers = new Headers(response.headers);
  headers.set('access-control-allow-origin', '*');
  headers.set('access-control-allow-methods', 'GET, POST, OPTIONS');
  headers.set('access-control-allow-headers', 'content-type, x-client-ts, x-client-sig');
  headers.set('access-control-max-age', '86400');
  return new Response(response.body, { status: response.status, headers });
}

// 供单元测试使用（不影响 Worker 运行时）。
export { sha256Hex, timingSafeEqual, verifySignature };
