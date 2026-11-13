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

import DASHBOARD_HTML from './dashboard.generated.js';

const MAX_BODY_BYTES = 2048;
const IP_HOURLY_LIMIT = 30;
const IP_WINDOW_SEC = 3600;
const SIG_WINDOW_SEC = 300;
const BADGE_CACHE_SEC = 21600;
const RATE_CLEANUP_EVERY = 200;
const MAX_STATS_DAYS = 90;
/** 崩溃上报单批上限与堆栈长度上限。 */
const MAX_CRASH_BATCH = 10;
const MAX_STACK_LEN = 2000;
const MAX_CRASH_BODY_BYTES = 32768;
/** 面板登录 cookie 名与有效期（180 天）。 */
const DASH_COOKIE = 'hg_dash';
const DASH_COOKIE_MAX_AGE = 180 * 86400;
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
    if (url.pathname === '/v1/crash' && request.method === 'POST') {
      return withCors(await handleCrash(request, env));
    }
    if (url.pathname === '/badge' && request.method === 'GET') {
      return withCors(await handleBadge(env));
    }
    if (url.pathname === '/stats' && request.method === 'GET') {
      return withCors(await handleStats(url, env));
    }
    if (url.pathname === '/dashboard' && request.method === 'GET') {
      return await handleDashboard(url, request, env);
    }
    if (url.pathname === '/api/stats' && request.method === 'GET') {
      return await handleApiStats(url, request, env);
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

  const today = day !== 0 ? day : dayStamp(now);

  // 去重闸门：daily_active 主键 (day, id_hash)。
  // 同一天重复上报时 changes=0，直接短路返回——不写 devices、不写 daily_stats、不计限流桶，
  // 把每次重复上报的 D1 写操作从 5 次压到 1 次（且被忽略的那次不产生新行）。
  let fresh = false;
  try {
    const res = await env.DB.prepare(
      'INSERT OR IGNORE INTO daily_active (day, id_hash) VALUES (?, ?)'
    ).bind(today, idHash).run();
    fresh = !!(res && res.meta && res.meta.changes > 0);
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
  if (!fresh) {
    return json({ ok: true, counted: false, reason: 'already_today' }, 200);
  }

  // 限流：单 IP 每小时 30 次（防随机 UUID 刷量；正常设备一天只上报一次，几乎不会命中）。
  const ip = request.headers.get('cf-connecting-ip') || '';
  if (ip.length > 0) {
    const ipHash = await sha256Hex(`${ip}:${salt}`);
    const hour = Math.floor(now / IP_WINDOW_SEC);
    const ipAllowed = await bumpRate(env, `ip:${ipHash}:${hour}`, IP_HOURLY_LIMIT, IP_WINDOW_SEC);
    if (!ipAllowed) {
      return json({ error: 'rate_limited' }, 429);
    }
  }

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

    // 2) 日聚合表：累加客户端上报的当日指标。
    //    若该日有启动次数，说明当天确实活跃过，补一条日活（让 DAU 能回溯补全）。
    if (stats !== null && stats.sessions > 0) {
      await env.DB.prepare(
        'INSERT OR IGNORE INTO daily_active (day, id_hash) VALUES (?, ?)'
      ).bind(stats.day, idHash).run();
    }
    if (stats !== null) {
      await env.DB.prepare(
        `INSERT INTO daily_stats (
           day, id_hash, sessions, duration_sec, vv, crash,
           startup_p50_ms, startup_p90_ms, startup_ms_sum, startup_ms_count,
           play_fail, fail_network, fail_auth, fail_notfound, fail_server, fail_other,
           sr_on, sr_supported, quality_hd, quality_sd, play_complete,
           page_home, page_search, page_category, page_profile, page_player)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(day, id_hash) DO UPDATE SET
           sessions = daily_stats.sessions + excluded.sessions,
           duration_sec = daily_stats.duration_sec + excluded.duration_sec,
           vv = daily_stats.vv + excluded.vv,
           crash = daily_stats.crash + excluded.crash,
           startup_p50_ms = excluded.startup_p50_ms,
           startup_p90_ms = excluded.startup_p90_ms,
           startup_ms_sum = daily_stats.startup_ms_sum + excluded.startup_ms_sum,
           startup_ms_count = daily_stats.startup_ms_count + excluded.startup_ms_count,
           play_fail = daily_stats.play_fail + excluded.play_fail,
           fail_network = daily_stats.fail_network + excluded.fail_network,
           fail_auth = daily_stats.fail_auth + excluded.fail_auth,
           fail_notfound = daily_stats.fail_notfound + excluded.fail_notfound,
           fail_server = daily_stats.fail_server + excluded.fail_server,
           fail_other = daily_stats.fail_other + excluded.fail_other,
           sr_on = daily_stats.sr_on + excluded.sr_on,
           sr_supported = daily_stats.sr_supported + excluded.sr_supported,
           quality_hd = daily_stats.quality_hd + excluded.quality_hd,
           quality_sd = daily_stats.quality_sd + excluded.quality_sd,
           play_complete = daily_stats.play_complete + excluded.play_complete,
           page_home = daily_stats.page_home + excluded.page_home,
           page_search = daily_stats.page_search + excluded.page_search,
           page_category = daily_stats.page_category + excluded.page_category,
           page_profile = daily_stats.page_profile + excluded.page_profile,
           page_player = daily_stats.page_player + excluded.page_player`
      ).bind(
        stats.day, idHash, stats.sessions, stats.durationSec, stats.vv, stats.crash,
        stats.startupP50, stats.startupP90, stats.startupSum, stats.startupCount,
        stats.playFail, stats.failNetwork, stats.failAuth, stats.failNotFound, stats.failServer, stats.failOther,
        stats.srOn, stats.srSupported, stats.qualityHd, stats.qualitySd, stats.playComplete,
        stats.pageHome, stats.pageSearch, stats.pageCategory, stats.pageProfile, stats.pagePlayer
      ).run();
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

/* ── 崩溃堆栈上报 ──────────────────────────────────── */

/**
 * POST /v1/crash
 * body: { id, ver, model, os, crashes: [{ type, reason, message, stack, thread, at }] }
 *
 * 服务端按「堆栈指纹」聚合：fingerprint = SHA-256(type + '|' + 规范化堆栈) 前 16 位。
 * 同一处崩溃在不同设备上只占一行，count 累加。
 */
async function handleCrash(request, env) {
  const now = Math.floor(Date.now() / 1000);

  const declared = Number(request.headers.get('content-length') || '0');
  if (declared > MAX_CRASH_BODY_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }
  let raw;
  try {
    raw = await request.text();
  } catch {
    return json({ error: 'bad_body' }, 400);
  }
  if (raw.length === 0 || raw.length > MAX_CRASH_BODY_BYTES) {
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

  const id = typeof body.id === 'string' ? body.id.trim() : '';
  const version = typeof body.ver === 'string' ? body.ver.trim() : '';
  if (!UUID_RE.test(id)) {
    return json({ error: 'bad_id' }, 400);
  }
  if (!VERSION_RE.test(version)) {
    return json({ error: 'bad_version' }, 400);
  }
  const crashes = Array.isArray(body.crashes) ? body.crashes : [];
  if (crashes.length === 0 || crashes.length > MAX_CRASH_BATCH) {
    return json({ error: 'bad_batch' }, 400);
  }

  // 限流：单 IP 每小时 30 次（崩溃上报不频繁，正常远低于此）。
  const salt = env.HASH_SALT || 'hghub-default-salt';
  const ip = request.headers.get('cf-connecting-ip') || '';
  if (ip.length > 0) {
    const ipHash = await sha256Hex(`${ip}:${salt}`);
    const hour = Math.floor(now / IP_WINDOW_SEC);
    const allowed = await bumpRate(env, `ip:${ipHash}:${hour}`, IP_HOURLY_LIMIT, IP_WINDOW_SEC);
    if (!allowed) {
      return json({ error: 'rate_limited' }, 429);
    }
  }

  let accepted = 0;
  try {
    for (let i = 0; i < crashes.length; i++) {
      const c = crashes[i];
      if (!c || typeof c !== 'object') {
        continue;
      }
      const type = clipText(c.type, 32) || 'unknown';
      const reason = clipText(c.reason, 200);
      const message = clipText(c.message, 300);
      const stack = clipText(c.stack, MAX_STACK_LEN);
      const thread = clipText(c.thread, 64);

      // 指纹：优先用堆栈；没有堆栈时退回 type+reason+message。
      const basis = stack.length > 0 ? `${type}|${stack}` : `${type}|${reason}|${message}`;
      const fingerprint = (await sha256Hex(basis)).slice(0, 16);

      await env.DB.prepare(
        `INSERT INTO crash_groups
           (fingerprint, type, reason, message, stack, thread, count, first_seen_epoch, last_seen_epoch)
         VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
         ON CONFLICT(fingerprint) DO UPDATE SET
           count = crash_groups.count + 1,
           last_seen_epoch = excluded.last_seen_epoch,
           message = CASE WHEN length(excluded.message) > length(COALESCE(crash_groups.message, ''))
                          THEN excluded.message ELSE crash_groups.message END,
           stack = CASE WHEN length(excluded.stack) > length(COALESCE(crash_groups.stack, ''))
                        THEN excluded.stack ELSE crash_groups.stack END`
      ).bind(fingerprint, type, reason, message, stack, thread, now, now).run();

      await env.DB.prepare(
        `INSERT INTO crash_versions (fingerprint, version, count) VALUES (?, ?, 1)
         ON CONFLICT(fingerprint, version) DO UPDATE SET count = crash_versions.count + 1`
      ).bind(fingerprint, version).run();

      accepted++;
    }
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }

  return json({ ok: true, accepted }, 200);
}

/** 截断并去掉控制字符。 */
function clipText(value, max) {
  if (value === undefined || value === null) {
    return '';
  }
  let text = String(value);
  // 去掉控制字符（保留换行/制表）。
  text = text.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, '');
  return text.length > max ? text.substring(0, max) : text;
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

/* ── 可视化面板（Cookie 鉴权）───────────────────────── */

/** 面板 cookie 值：HMAC(STATS_KEY, 固定串)，无需服务端会话存储。 */
async function dashCookieValue(env) {
  const key = env.STATS_KEY || '';
  if (key.length === 0) {
    return '';
  }
  const enc = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    'raw', enc.encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const mac = await crypto.subtle.sign('HMAC', cryptoKey, enc.encode('hghub-dashboard-v1'));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function readCookie(request, name) {
  const raw = request.headers.get('cookie') || '';
  const parts = raw.split(';');
  for (let i = 0; i < parts.length; i++) {
    const item = parts[i].trim();
    const eq = item.indexOf('=');
    if (eq > 0 && item.slice(0, eq) === name) {
      return item.slice(eq + 1);
    }
  }
  return '';
}

/** 校验请求是否已通过面板鉴权（cookie 或 ?key=）。 */
async function dashAuthorized(url, request, env) {
  const expected = await dashCookieValue(env);
  if (expected.length === 0) {
    return false;
  }
  const cookie = readCookie(request, DASH_COOKIE);
  if (cookie.length > 0 && timingSafeEqual(cookie, expected)) {
    return true;
  }
  const key = url.searchParams.get('key') || '';
  const statsKey = env.STATS_KEY || '';
  return key.length > 0 && statsKey.length > 0 && timingSafeEqual(key, statsKey);
}

/** GET /dashboard：带 key 首次访问 → 种 cookie 并 302；已登录 → 返回面板 HTML。 */
async function handleDashboard(url, request, env) {
  const expected = await dashCookieValue(env);
  if (expected.length === 0) {
    return html(loginPage('服务端未配置 STATS_KEY，面板不可用'), 503);
  }

  const key = url.searchParams.get('key') || '';
  if (key.length > 0) {
    if (!timingSafeEqual(key, env.STATS_KEY || '')) {
      return html(loginPage('口令不正确'), 401);
    }
    // 口令正确：种 cookie 后把 URL 里的 key 去掉。
    return new Response(null, {
      status: 302,
      headers: {
        'location': '/dashboard',
        'set-cookie': `${DASH_COOKIE}=${expected}; Path=/; Max-Age=${DASH_COOKIE_MAX_AGE}; ` +
          'HttpOnly; Secure; SameSite=Strict',
        'cache-control': 'no-store',
      },
    });
  }

  const cookie = readCookie(request, DASH_COOKIE);
  if (cookie.length === 0 || !timingSafeEqual(cookie, expected)) {
    return html(loginPage('请输入访问口令'), 401);
  }
  return html(DASHBOARD_HTML, 200, {
    'cache-control': 'no-store',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer',
  });
}

/** GET /api/stats：面板数据接口，cookie 或 ?key= 鉴权。 */
async function handleApiStats(url, request, env) {
  const ok = await dashAuthorized(url, request, env);
  if (!ok) {
    return json({ error: 'forbidden' }, 401);
  }
  return await handleStats(url, env, true);
}

/** 极简登录页（瑞士风格，无依赖）。 */
function loginPage(message) {
  return `<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><title>HGhub · Telemetry</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,"PingFang SC",sans-serif;
 background:#fff;color:#0a0a0a;font-size:14px;line-height:1.45;-webkit-font-smoothing:antialiased}
.gate{max-width:420px;margin:18vh auto 0;padding:0 24px}
h1{font-size:24px;font-weight:700;letter-spacing:-.02em}
.sub{font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:#6b6b6b;margin-top:6px}
p{font-size:12px;color:#6b6b6b;margin-top:20px}
form{display:flex;gap:8px;margin-top:20px}
input{flex:1;font:inherit;font-size:13px;padding:9px 12px;border:1px solid #0a0a0a;outline:none}
input:focus{border-color:#4d6bfe}
button{font:inherit;font-size:13px;padding:9px 18px;cursor:pointer;background:#0a0a0a;color:#fff;border:1px solid #0a0a0a}
.err{color:#e63946;font-size:12px;margin-top:12px}
</style></head>
<body><div class="gate">
<h1>HGhub</h1><div class="sub">Telemetry · 匿名聚合</div>
<p>${message}</p>
<form method="get" action="/dashboard">
<input type="password" name="key" placeholder="访问口令" autocomplete="current-password" autofocus>
<button type="submit">进入</button>
</form>
${message === '请输入访问口令' ? '' : '<div class="err">' + message + '</div>'}
</div></body></html>`;
}

function html(body, status = 200, extraHeaders = {}) {
  return new Response(body, {
    status,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'x-content-type-options': 'nosniff',
      ...extraHeaders,
    },
  });
}

/* ── 统计 ───────────────────────────────────────────── */

async function handleStats(url, env, preAuthorized) {
  if (preAuthorized !== true) {
    const key = url.searchParams.get('key') || '';
    const expected = env.STATS_KEY || '';
    if (expected.length === 0 || !timingSafeEqual(key, expected)) {
      return json({ error: 'forbidden' }, 403);
    }
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
              COALESCE(s.crash, 0) AS crash,
              COALESCE(s.play_fail, 0) AS play_fail,
              COALESCE(s.play_complete, 0) AS play_complete,
              COALESCE(s.quality_hd, 0) AS quality_hd,
              COALESCE(s.quality_sd, 0) AS quality_sd,
              COALESCE(s.sr_on, 0) AS sr_on,
              COALESCE(s.sr_supported, 0) AS sr_supported,
              CASE WHEN COALESCE(s.startup_ms_count, 0) > 0
                   THEN CAST(s.startup_ms_sum / s.startup_ms_count AS INTEGER) ELSE 0 END AS avg_startup_ms
         FROM (
           SELECT DISTINCT day FROM daily_active WHERE day >= ?
           UNION
           SELECT DISTINCT day FROM daily_stats WHERE day >= ?
         ) d
         LEFT JOIN (
           SELECT day, COUNT(*) AS devices FROM daily_active GROUP BY day
         ) a ON a.day = d.day
         LEFT JOIN (
           SELECT day,
                  SUM(sessions) AS sessions, SUM(duration_sec) AS duration_sec,
                  SUM(vv) AS vv, SUM(crash) AS crash,
                  SUM(play_fail) AS play_fail, SUM(play_complete) AS play_complete,
                  SUM(quality_hd) AS quality_hd, SUM(quality_sd) AS quality_sd,
                  SUM(sr_on) AS sr_on, SUM(sr_supported) AS sr_supported,
                  SUM(startup_ms_sum) AS startup_ms_sum, SUM(startup_ms_count) AS startup_ms_count
             FROM daily_stats GROUP BY day
         ) s ON s.day = d.day
        ORDER BY d.day ASC`
    ).bind(fromDay, fromDay).all();

    const totals = await env.DB.prepare(
      `SELECT COALESCE(SUM(sessions), 0) AS sessions,
              COALESCE(SUM(duration_sec), 0) AS duration_sec,
              COALESCE(SUM(vv), 0) AS vv,
              COALESCE(SUM(crash), 0) AS crash,
              COALESCE(SUM(play_fail), 0) AS play_fail,
              COALESCE(SUM(fail_network), 0) AS fail_network,
              COALESCE(SUM(fail_auth), 0) AS fail_auth,
              COALESCE(SUM(fail_notfound), 0) AS fail_notfound,
              COALESCE(SUM(fail_server), 0) AS fail_server,
              COALESCE(SUM(fail_other), 0) AS fail_other,
              COALESCE(SUM(sr_on), 0) AS sr_on,
              COALESCE(SUM(sr_supported), 0) AS sr_supported,
              COALESCE(SUM(quality_hd), 0) AS quality_hd,
              COALESCE(SUM(quality_sd), 0) AS quality_sd,
              COALESCE(SUM(play_complete), 0) AS play_complete,
              COALESCE(SUM(startup_ms_sum), 0) AS startup_ms_sum,
              COALESCE(SUM(startup_ms_count), 0) AS startup_ms_count,
              COALESCE(AVG(NULLIF(startup_p50_ms, 0)), 0) AS avg_p50,
              COALESCE(AVG(NULLIF(startup_p90_ms, 0)), 0) AS avg_p90,
              COALESCE(SUM(page_home), 0) AS page_home,
              COALESCE(SUM(page_search), 0) AS page_search,
              COALESCE(SUM(page_category), 0) AS page_category,
              COALESCE(SUM(page_profile), 0) AS page_profile,
              COALESCE(SUM(page_player), 0) AS page_player
         FROM daily_stats WHERE day >= ?`
    ).bind(fromDay).first();

    // 新增设备按天（首见日）——增长曲线，不需要新采集。
    const newDaily = await env.DB.prepare(
      `SELECT CAST(strftime('%Y%m%d', first_seen_epoch, 'unixepoch') AS INTEGER) AS day,
              COUNT(*) AS devices
         FROM devices
        WHERE first_seen_epoch >= ?
        GROUP BY day ORDER BY day ASC`
    ).bind(now - days * day).all();

    // 最近一天的回访率：当天活跃设备中，过去 7 天也活跃过的比例。
    const latest = dailyRows && dailyRows.results && dailyRows.results.length > 0 ?
      dailyRows.results[dailyRows.results.length - 1].day : 0;
    let returning7 = 0;
    if (latest > 0) {
      const row = await env.DB.prepare(
        `SELECT COUNT(*) AS n FROM daily_active a
          WHERE a.day = ?
            AND EXISTS (SELECT 1 FROM daily_active b
                         WHERE b.id_hash = a.id_hash AND b.day < a.day AND b.day >= ?)`
      ).bind(latest, latest - 7).first();
      returning7 = row ? row.n : 0;
    }

    // 崩溃聚合：按指纹分组，取 top 20。
    const crashTotal = await env.DB.prepare(
      'SELECT COALESCE(SUM(count), 0) AS n FROM crash_groups'
    ).first();
    const crashGroups = await env.DB.prepare(
      `SELECT fingerprint, type, reason, message, stack, thread, count,
              first_seen_epoch, last_seen_epoch
         FROM crash_groups
        ORDER BY count DESC, last_seen_epoch DESC
        LIMIT 20`
    ).all();
    const crashVersions = await env.DB.prepare(
      'SELECT fingerprint, version, count FROM crash_versions'
    ).all();

    const totalDevices = total ? total.n : 0;
    const sumSessions = totals ? totals.sessions : 0;
    const sumDuration = totals ? totals.duration_sec : 0;
    const sumVv = totals ? totals.vv : 0;
    const sumFail = totals ? totals.play_fail : 0;
    const sumHd = totals ? totals.quality_hd : 0;
    const sumSd = totals ? totals.quality_sd : 0;
    const sumComplete = totals ? totals.play_complete : 0;
    const startupCount = totals ? totals.startup_ms_count : 0;
    const startupSum = totals ? totals.startup_ms_sum : 0;
    const pct = (a, b) => (b > 0 ? Math.round((a / b) * 1000) / 10 : 0);

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
      new_devices_daily: newDaily && newDaily.results ? newDaily.results : [],
      returning_7d: returning7,
      returning_7d_ratio: latest > 0 && dailyRows.results.length > 0 &&
        dailyRows.results[dailyRows.results.length - 1].devices > 0 ?
        Math.round((returning7 / dailyRows.results[dailyRows.results.length - 1].devices) * 1000) / 10 : 0,
      // 区间累计
      totals: {
        sessions: sumSessions,
        duration_sec: sumDuration,
        vv: sumVv,
        crash: totals ? totals.crash : 0,
      },
      // 启动耗时
      startup: {
        avg_ms: startupCount > 0 ? Math.round(startupSum / startupCount) : 0,
        avg_p50_ms: totals ? Math.round(totals.avg_p50) : 0,
        avg_p90_ms: totals ? Math.round(totals.avg_p90) : 0,
        samples: startupCount,
      },
      // 播放质量
      playback: {
        vv: sumVv,
        play_fail: sumFail,
        play_fail_rate: pct(sumFail, sumVv + sumFail),
        play_complete: sumComplete,
        play_complete_rate: pct(sumComplete, sumVv),
        fail_breakdown: {
          network: totals ? totals.fail_network : 0,
          auth: totals ? totals.fail_auth : 0,
          notfound: totals ? totals.fail_notfound : 0,
          server: totals ? totals.fail_server : 0,
          other: totals ? totals.fail_other : 0,
        },
      },
      // 画质与超分
      quality: {
        hd: sumHd,
        sd: sumSd,
        hd_ratio: pct(sumHd, sumHd + sumSd),
        sr_on: totals ? totals.sr_on : 0,
        sr_supported: totals ? totals.sr_supported : 0,
        sr_support_rate: pct(totals ? totals.sr_supported : 0, totalDevices),
        sr_on_rate: pct(totals ? totals.sr_on : 0, totalDevices),
      },
      // 崩溃聚合
      crash: {
        total: crashTotal ? crashTotal.n : 0,
        groups: (crashGroups && crashGroups.results ? crashGroups.results : []).map((g) => ({
          fingerprint: g.fingerprint,
          type: g.type,
          reason: g.reason,
          message: g.message,
          stack: g.stack,
          thread: g.thread,
          count: g.count,
          first_seen: g.first_seen_epoch,
          last_seen: g.last_seen_epoch,
          versions: (crashVersions && crashVersions.results ? crashVersions.results : [])
            .filter((v) => v.fingerprint === g.fingerprint)
            .map((v) => ({ version: v.version, count: v.count })),
        })),
      },
      // 页面访问分布
      pages: {
        home: totals ? totals.page_home : 0,
        search: totals ? totals.page_search : 0,
        category: totals ? totals.page_category : 0,
        profile: totals ? totals.page_profile : 0,
        player: totals ? totals.page_player : 0,
      },
      avg_duration_sec_per_session: sumSessions > 0 ? Math.round(sumDuration / sumSessions) : 0,
      avg_vv_per_device: totalDevices > 0 ? Math.round((sumVv / totalDevices) * 10) / 10 : 0,
      window_days: days,
      generated_at: new Date(now * 1000).toISOString(),
    }, 200, { 'cache-control': 'private, max-age=60' });
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
  const n = (v) => toSafeInt(v, 0, 0, MAX_COUNTER);
  return {
    day,
    sessions: n(raw.sessions),
    durationSec: n(raw.duration_sec),
    vv: n(raw.vv),
    crash: n(raw.crash),
    // 启动耗时：设备内 p50/p90 + 均值用的 sum/count
    startupP50: toSafeInt(raw.startup_p50_ms, 0, 0, 600000),
    startupP90: toSafeInt(raw.startup_p90_ms, 0, 0, 600000),
    startupSum: toSafeInt(raw.startup_ms_sum, 0, 0, 600000 * MAX_COUNTER),
    startupCount: n(raw.startup_ms_count),
    // 播放失败
    playFail: n(raw.play_fail),
    failNetwork: n(raw.fail_network),
    failAuth: n(raw.fail_auth),
    failNotFound: n(raw.fail_notfound),
    failServer: n(raw.fail_server),
    failOther: n(raw.fail_other),
    // 超分 / 画质 / 完播
    srOn: n(raw.sr_on),
    srSupported: n(raw.sr_supported),
    qualityHd: n(raw.quality_hd),
    qualitySd: n(raw.quality_sd),
    playComplete: n(raw.play_complete),
    // 页面分布
    pageHome: n(raw.page_home),
    pageSearch: n(raw.page_search),
    pageCategory: n(raw.page_category),
    pageProfile: n(raw.page_profile),
    pagePlayer: n(raw.page_player),
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

/** 安全取整：缺省/非数字/NaN 返回 fallback，再夹到 [min, max]。 */
function toSafeInt(value, fallback, min, max) {
  // 注意 Number(null) === 0、Number('') === 0，必须先把「没传」和「传了 0」区分开，
  // 否则 ?days 缺省时会被夹成 min（1 天）而不是默认值。
  if (value === null || value === undefined || value === '') {
    return fallback;
  }
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
