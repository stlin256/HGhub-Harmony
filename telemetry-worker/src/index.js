/**
 * HGhub Harmony 匿名统计 Worker（Cloudflare Workers + D1）
 *
 * 回答四类问题：
 *   1. 安装数（徽章口径）—— 有多少台设备启动过，累积去重
 *   2. DAU —— 每天有多少台设备活跃
 *   3. VV —— 每天播放了多少次
 *   4. 时长 —— 每天用了多久
 *
 * 隐私与安全设计：
 *   1. 客户端上报随机 UUID（本地生成、与硬件无关），服务端用 SHA-256(id + SALT) 后落库，
 *      原始 UUID 不持久化，也不出现在日志里。
 *   2. IP 只在内存中用于限流，落库时同样先 SHA-256(ip + SALT)。
 *   3. 不收集：OAID / IMEI / SN / MAC / 账号 / 位置 / 播放内容 / 搜索词。
 *   4. 限流：单 IP 每小时 30 次、单设备每天 1 次；请求体上限 2 KB；字段白名单校验。
 *   5. 可选 HMAC 签名（配置 SHARED_SECRET 后启用）：防重放窗口 300 秒，
 *      仅作为「提高刷量门槛」的手段，不是安全边界（密钥内嵌客户端可被提取）。
 *
 * 端点：
 *   POST /v1/report    上报一次启动 + 上一次的当日聚合（幂等）
 *   POST /v1/install   兼容旧路径，等价 /v1/report
 *   GET  /badge        shields.io endpoint 格式，只显示安装数
 *   GET  /stats?key=   聚合统计（需要 STATS_KEY）
 *   GET  /health       健康检查
 */

const MAX_BODY_BYTES = 2048;
const IP_HOURLY_LIMIT = 30;
const DEVICE_DAILY_LIMIT = 1;
const IP_WINDOW_SEC = 3600;
const DEVICE_WINDOW_SEC = 86400;
const SIG_WINDOW_SEC = 300;
const BADGE_CACHE_SEC = 3600;
const RATE_CLEANUP_EVERY = 50;
const MAX_STATS_DAYS = 90;
/** 单日聚合字段上限，防止异常客户端把数字撑爆。 */
const MAX_COUNTER = 1000000;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const VERSION_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){0,3}$/;
const MODEL_RE = /^[A-Za-z0-9 _\-.]{0,32}$/;
const OS_RE = /^[A-Za-z0-9 ._\-]{0,24}$/;
/** YYYYMMDD。 */
const DAY_RE = /^20[0-9]{6}$/;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return withCors(new Response(null, { status: 204 }));
    }
    if (url.pathname === '/health') {
      return withCors(json({ ok: true }));
    }
    if ((url.pathname === '/v1/report' || url.pathname === '/v1/install') && request.method === 'POST') {
      return withCors(await handleReport(request, env, ctx));
    }
    if (url.pathname === '/badge' && request.method === 'GET') {
      return withCors(await handleBadge(env));
    }
    if (url.pathname === '/stats' && request.method === 'GET') {
      return withCors(await handleStats(url, env));
    }
    return withCors(json({ error: 'not_found' }, 404));
  },
};

/* ── 上报 ───────────────────────────────────────────── */

async function handleReport(request, env, ctx) {
  const now = Math.floor(Date.now() / 1000);

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

  // 基础字段校验。
  const id = typeof body.id === 'string' ? body.id.trim() : '';
  const version = typeof body.ver === 'string' ? body.ver.trim() : '';
  const model = typeof body.model === 'string' ? body.model.trim() : '';
  const os = typeof body.os === 'string' ? body.os.trim() : '';
  const installAt = toSafeInt(body.install_at, 0, 0, now + 86400);
  const day = parseDay(body.day);

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
  if (body.day !== undefined && body.day !== null && day === 0) {
    return json({ error: 'bad_day' }, 400);
  }

  // 可选的「上一次上报以来」聚合。
  const stats = parseStats(body.stats);

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
  const dayKey = Math.floor(now / DEVICE_WINDOW_SEC);
  const deviceAllowed = await bumpRate(env, `dev:${idHash}:${dayKey}`, DEVICE_DAILY_LIMIT, DEVICE_WINDOW_SEC);
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

  const today = day !== 0 ? day : dayStamp(now);

  try {
    // 1) 设备表：安装数口径，主键去重。
    await env.DB.prepare(
      `INSERT INTO devices
         (id_hash, first_version, version, model, os, install_epoch, first_seen_epoch, last_seen_epoch, report_count)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
       ON CONFLICT(id_hash) DO UPDATE SET
         version = excluded.version,
         model = excluded.model,
         os = excluded.os,
         install_epoch = COALESCE(devices.install_epoch, excluded.install_epoch),
         last_seen_epoch = excluded.last_seen_epoch,
         report_count = devices.report_count + 1`
    ).bind(idHash, version, version, model, os, installAt > 0 ? installAt : now, now, now).run();

    // 2) 日活表：每台设备每天一行。
    await env.DB.prepare(
      'INSERT OR IGNORE INTO daily_active (day, id_hash) VALUES (?, ?)'
    ).bind(today, idHash).run();

    // 3) 日聚合表：累加客户端上报的当日指标。
    //    若该日有启动次数，说明当天确实活跃过，补一条日活（让 DAU 能回溯补全）。
    if (stats !== null && stats.sessions > 0) {
      await env.DB.prepare(
        'INSERT OR IGNORE INTO daily_active (day, id_hash) VALUES (?, ?)'
      ).bind(stats.day, idHash).run();
    }
    if (stats !== null) {
      await env.DB.prepare(
        `INSERT INTO daily_stats (day, id_hash, sessions, duration_sec, vv, crash)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(day, id_hash) DO UPDATE SET
           sessions = daily_stats.sessions + excluded.sessions,
           duration_sec = daily_stats.duration_sec + excluded.duration_sec,
           vv = daily_stats.vv + excluded.vv,
           crash = daily_stats.crash + excluded.crash`
      ).bind(stats.day, idHash, stats.sessions, stats.durationSec, stats.vv, stats.crash).run();
    }
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }

  if (Math.random() < 1 / RATE_CLEANUP_EVERY) {
    ctx.waitUntil(
      env.DB.prepare('DELETE FROM rate_limits WHERE expires_at < ?').bind(now).run().catch(() => {})
    );
  }

  return json({ ok: true, counted: true }, 200);
}

/* ── 徽章（只显示安装数）───────────────────────────── */

async function handleBadge(env) {
  let total = 0;
  try {
    const row = await env.DB.prepare('SELECT COUNT(*) AS n FROM devices').first();
    total = row && typeof row.n === 'number' ? row.n : 0;
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
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
  const days = clamp(toSafeInt(url.searchParams.get('days'), 30, 1, MAX_STATS_DAYS), 1, MAX_STATS_DAYS);
  const fromDay = dayStamp(now - days * 86400);
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
      'SELECT version, COUNT(*) AS n FROM devices GROUP BY version ORDER BY n DESC LIMIT 30'
    ).all();
    const byModel = await env.DB.prepare(
      "SELECT COALESCE(NULLIF(model, ''), 'unknown') AS model, COUNT(*) AS n FROM devices GROUP BY model ORDER BY n DESC LIMIT 30"
    ).all();
    const byOs = await env.DB.prepare(
      "SELECT COALESCE(NULLIF(os, ''), 'unknown') AS os, COUNT(*) AS n FROM devices GROUP BY os ORDER BY n DESC LIMIT 20"
    ).all();

    // 按天：DAU 与聚合指标。
    // 日期集合取 daily_active 与 daily_stats 的并集——客户端可能今天才补报昨天的聚合，
    // 那时 daily_active 里没有昨天的行，只用 LEFT JOIN 会把昨天漏掉。
    const dailyRows = await env.DB.prepare(
      `SELECT d.day AS day,
              COALESCE(a.devices, 0) AS devices,
              COALESCE(s.sessions, 0) AS sessions,
              COALESCE(s.duration_sec, 0) AS duration_sec,
              COALESCE(s.vv, 0) AS vv,
              COALESCE(s.crash, 0) AS crash
         FROM (
           SELECT DISTINCT day FROM daily_active WHERE day >= ?
           UNION
           SELECT DISTINCT day FROM daily_stats WHERE day >= ?
         ) d
         LEFT JOIN (
           SELECT day, COUNT(*) AS devices FROM daily_active GROUP BY day
         ) a ON a.day = d.day
         LEFT JOIN (
           SELECT day, SUM(sessions) AS sessions, SUM(duration_sec) AS duration_sec,
                  SUM(vv) AS vv, SUM(crash) AS crash
             FROM daily_stats GROUP BY day
         ) s ON s.day = d.day
        ORDER BY d.day ASC`
    ).bind(fromDay, fromDay).all();

    const totals = await env.DB.prepare(
      `SELECT COALESCE(SUM(sessions), 0) AS sessions,
              COALESCE(SUM(duration_sec), 0) AS duration_sec,
              COALESCE(SUM(vv), 0) AS vv,
              COALESCE(SUM(crash), 0) AS crash
         FROM daily_stats WHERE day >= ?`
    ).bind(fromDay).first();

    const totalDevices = total ? total.n : 0;
    const sumSessions = totals ? totals.sessions : 0;
    const sumDuration = totals ? totals.duration_sec : 0;
    const sumVv = totals ? totals.vv : 0;

    return json({
      // 徽章口径
      devices_total: totalDevices,
      devices_active_7d: active7 ? active7.n : 0,
      devices_active_30d: active30 ? active30.n : 0,
      devices_new_7d: new7 ? new7.n : 0,
      // 矩阵
      by_version: byVersion && byVersion.results ? byVersion.results : [],
      by_model: byModel && byModel.results ? byModel.results : [],
      by_os: byOs && byOs.results ? byOs.results : [],
      // 按天
      daily: dailyRows && dailyRows.results ? dailyRows.results : [],
      // 区间累计
      totals: {
        sessions: sumSessions,
        duration_sec: sumDuration,
        vv: sumVv,
        crash: totals ? totals.crash : 0,
      },
      avg_duration_sec_per_session: sumSessions > 0 ? Math.round(sumDuration / sumSessions) : 0,
      avg_vv_per_device: totalDevices > 0 ? Math.round((sumVv / totalDevices) * 10) / 10 : 0,
      window_days: days,
      generated_at: new Date(now * 1000).toISOString(),
    });
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
}

/* ── 工具 ───────────────────────────────────────────── */

/** 解析并裁剪客户端上报的当日聚合；无有效内容返回 null。 */
function parseStats(raw) {
  if (!raw || typeof raw !== 'object') {
    return null;
  }
  const day = parseDay(raw.day);
  if (day === 0) {
    return null;
  }
  return {
    day,
    sessions: toSafeInt(raw.sessions, 0, 0, MAX_COUNTER),
    durationSec: toSafeInt(raw.duration_sec, 0, 0, MAX_COUNTER),
    vv: toSafeInt(raw.vv, 0, 0, MAX_COUNTER),
    crash: toSafeInt(raw.crash, 0, 0, MAX_COUNTER),
  };
}

/**
 * 严格解析 YYYYMMDD：非整数、越界、格式不符一律返回 0（表示无效）。
 * 注意不能用 clamp，否则 123 会被抬到 20000101 变成「合法」。
 */
function parseDay(value) {
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n) || !Number.isInteger(n) || n < 20000101 || n > 29991231) {
    return 0;
  }
  return DAY_RE.test(String(n)) ? n : 0;
}

/** 安全取整：非数字/NaN 返回 fallback，再夹到 [min, max]。 */
function toSafeInt(value, fallback, min, max) {
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n)) {
    return fallback;
  }
  return clamp(Math.trunc(n), min, max);
}

function clamp(n, min, max) {
  return n < min ? min : n > max ? max : n;
}

/** epoch 秒 → YYYYMMDD（UTC，仅用于服务端兜底；客户端会带本地时区的 day）。 */
function dayStamp(epochSec) {
  const d = new Date(epochSec * 1000);
  return d.getUTCFullYear() * 10000 + (d.getUTCMonth() + 1) * 100 + d.getUTCDate();
}

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
export { sha256Hex, timingSafeEqual, verifySignature, parseStats, parseDay, dayStamp, toSafeInt };
