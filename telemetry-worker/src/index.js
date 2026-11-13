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
 *   GET  /v1/config    远程配置下发（HMAC 签名 + 304 短路 + config_id）
 *   POST /admin/config 发布远程配置（需要 CONFIG_ADMIN_KEY，未配置时回落 STATS_KEY）
 *   GET  /v1/update    更新闸门（强制/灰度/普通三态判定所需数据）
 *   POST /admin/release 发布版本信息（鉴权同 /admin/config）
 *   GET  /v1/assets/manifest 资源清单（HMAC 签名）
 *   GET  /v1/assets/<name>   资源原始字节
 *   POST /admin/asset  上传资源（鉴权同 /admin/config）
 *   GET  /badge        shields.io endpoint 格式，只显示安装数
 *   GET  /stats?key=   聚合统计（需要 STATS_KEY）
 *   GET  /health       健康检查
 *
 * 远程配置（P1/P14）：
 *   GET /v1/config 从 D1 remote_config 读最新 payload，附加 HMAC-SHA256 签名后下发；
 *   未配置 CONFIG_SIGNING_KEY 时返回 503（不发未签名内容）；cfg 与服务端版本相同返回 304；
 *   响应体带 config_id（每次发布生成的唯一 ID，SPEC §16）。
 *
 * 更新闸门（P4）：
 *   GET /v1/update 从 D1 app_release 读最新版本信息，附加同样的 HMAC-SHA256 签名；
 *   客户端据 min_version / latest / rollout_pct 判定 force / soft / none 三态。
 *
 * 资源热更新（P5）：
 *   GET /v1/assets/manifest 返回资源清单（name / sha256 / size / url）并签名；
 *   GET /v1/assets/<name> 返回原始字节，客户端按清单里的 SHA-256 校验后落盘。
 */

import DASHBOARD_HTML from './dashboard.generated.js';

/** 旧客户端（不带 config_apply）的请求体上限：保持不变，避免改变现有行为。 */
const MAX_BODY_BYTES = 2048;
/** 带 config_apply 的新客户端请求体上限（20 条变化 + 完整日聚合，留足余量）。 */
const MAX_REPORT_BODY_BYTES = 16384;
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
/** 远程配置下发：响应体上限 16 KB、缓存 5 分钟、版本上限、管理端请求体上限 32 KB。 */
const CONFIG_MAX_BYTES = 16384;
const CONFIG_CACHE_CONTROL = 'public, max-age=300';
const CONFIG_ROW_ID = 'global';
const MAX_CONFIG_VERSION = 2147483647;
const MAX_ADMIN_BODY_BYTES = 32768;
/** 配置应用回报（SPEC §15）：单次最多 20 条，字段长度上限防止异常客户端把库撑大。 */
const MAX_CONFIG_APPLY = 20;
const MAX_CONFIG_ID_LEN = 64;
const MAX_CONFIG_KEY_LEN = 64;
const MAX_CONFIG_VALUE_LEN = 128;
/** 更新闸门（P4）：缓存 5 分钟、响应体上限 8 KB、notes/url 长度上限。 */
const UPDATE_CACHE_CONTROL = 'public, max-age=300';
const UPDATE_MAX_BYTES = 8192;
const RELEASE_ROW_ID = 'global';
const MAX_RELEASE_NOTES_LEN = 800;
const MAX_RELEASE_URL_LEN = 512;
const DEFAULT_RELEASE_URL = 'https://github.com/stlin256/HGhub-Harmony/releases';
/** 资源热更新（P5）：单文件 512 KB、总量 4 MB、清单条数上限、管理端请求体上限 1 MB。 */
const ASSET_MAX_FILE_BYTES = 512 * 1024;
const ASSET_MAX_TOTAL_BYTES = 4 * 1024 * 1024;
const ASSET_MAX_COUNT = 100;
const ASSET_CACHE_CONTROL = 'public, max-age=300';
const MAX_ASSET_ADMIN_BODY_BYTES = 1048576;
const ASSET_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/;
const ASSET_SHA_RE = /^[0-9a-f]{64}$/;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const VERSION_RE = /^[0-9]{1,3}(\.[0-9]{1,3}){0,3}$/;
const MODEL_RE = /^[A-Za-z0-9 _\-.]{0,32}$/;
const OS_RE = /^[A-Za-z0-9 ._\-]{0,24}$/;
/** YYYYMMDD。 */
const DAY_RE = /^20[0-9]{6}$/;
/** 配置应用 key：小写 snake_case（与客户端 ConfigRegistry 的 ConfigKey 一致）。 */
const CONFIG_KEY_RE = /^[a-z][a-z0-9_]{0,63}$/;
/** config_id：UUID 或未来格式的短标识；空串表示「无远程配置时的本地变化」。 */
const CONFIG_ID_RE = /^[A-Za-z0-9_-]{0,64}$/;
/** 变化来源白名单（SPEC §15.2）。 */
const CONFIG_SOURCES = new Set(['remote', 'local_override', 'default']);

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
    if (url.pathname === '/v1/config' && request.method === 'GET') {
      return withCors(await handleConfig(url, env));
    }
    if (url.pathname === '/admin/config' && request.method === 'POST') {
      // 管理写端点**不套 CORS**：它不需要浏览器跨域调用，
      // 套上 Access-Control-Allow-Origin: * 会让任意网页在知道 key 时跨域写配置。
      return await handleAdminConfig(request, env);
    }
    if (url.pathname === '/v1/update' && request.method === 'GET') {
      return withCors(await handleUpdate(env));
    }
    if (url.pathname === '/admin/release' && request.method === 'POST') {
      // 同 /admin/config：管理写端点不套 CORS。
      return await handleAdminRelease(request, env);
    }
    if (url.pathname === '/v1/assets/manifest' && request.method === 'GET') {
      return withCors(await handleAssetsManifest(env));
    }
    if (url.pathname.startsWith('/v1/assets/') && request.method === 'GET') {
      return withCors(await handleAssetDownload(url, env));
    }
    if (url.pathname === '/admin/asset' && request.method === 'POST') {
      // 同 /admin/config：管理写端点不套 CORS。
      return await handleAdminAsset(request, env);
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
  if (declared > MAX_REPORT_BODY_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }
  let raw;
  try {
    raw = await request.text();
  } catch {
    return json({ error: 'bad_body' }, 400);
  }
  if (raw.length === 0 || raw.length > MAX_REPORT_BODY_BYTES) {
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

  // 配置应用回报（SPEC §15）：旧客户端不带该字段，行为完全不变。
  const configApplies = parseConfigApplies(body.config_apply, now);
  // 兼容旧行为：不带 config_apply 的请求仍按 2 KB 限制，避免放宽刷量面。
  if (raw.length > MAX_BODY_BYTES && configApplies.length === 0) {
    return json({ error: 'payload_too_large' }, 413);
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
           page_home, page_search, page_category, page_profile, page_player,
           mem_pss_kb, mem_peak_kb, mem_vss_kb,
           disk_app_bytes, disk_cache_bytes, disk_data_bytes,
           soc_start, soc_end, temp_max_c, charging,
           line_primary_ok, line_primary_fail, line_mirror_ok, line_mirror_fail,
           line_switches, line_latency_avg_ms, line_latency_p90_ms,
           cpu_pct, cpu_peak_pct, thermal_level, power_mw,
           act_share, act_like, act_unlike, act_fav, act_unfav, act_search,
           act_ep_switch, act_rate, act_cast, act_pip, act_comment, act_follow,
           act_topic, act_user)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                 ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                 ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
           page_player = daily_stats.page_player + excluded.page_player,
           mem_pss_kb = excluded.mem_pss_kb,
           mem_peak_kb = MAX(daily_stats.mem_peak_kb, excluded.mem_peak_kb),
           mem_vss_kb = excluded.mem_vss_kb,
           disk_app_bytes = excluded.disk_app_bytes,
           disk_cache_bytes = excluded.disk_cache_bytes,
           disk_data_bytes = excluded.disk_data_bytes,
           soc_start = CASE WHEN daily_stats.soc_start = 0 THEN excluded.soc_start ELSE daily_stats.soc_start END,
           soc_end = excluded.soc_end,
           temp_max_c = MAX(daily_stats.temp_max_c, excluded.temp_max_c),
           charging = excluded.charging,
           line_primary_ok = daily_stats.line_primary_ok + excluded.line_primary_ok,
           line_primary_fail = daily_stats.line_primary_fail + excluded.line_primary_fail,
           line_mirror_ok = daily_stats.line_mirror_ok + excluded.line_mirror_ok,
           line_mirror_fail = daily_stats.line_mirror_fail + excluded.line_mirror_fail,
           line_switches = daily_stats.line_switches + excluded.line_switches,
           line_latency_avg_ms = excluded.line_latency_avg_ms,
           line_latency_p90_ms = excluded.line_latency_p90_ms,
           cpu_pct = excluded.cpu_pct,
           cpu_peak_pct = MAX(daily_stats.cpu_peak_pct, excluded.cpu_peak_pct),
           thermal_level = MAX(daily_stats.thermal_level, excluded.thermal_level),
           power_mw = excluded.power_mw,
           act_share = daily_stats.act_share + excluded.act_share,
           act_like = daily_stats.act_like + excluded.act_like,
           act_unlike = daily_stats.act_unlike + excluded.act_unlike,
           act_fav = daily_stats.act_fav + excluded.act_fav,
           act_unfav = daily_stats.act_unfav + excluded.act_unfav,
           act_search = daily_stats.act_search + excluded.act_search,
           act_ep_switch = daily_stats.act_ep_switch + excluded.act_ep_switch,
           act_rate = daily_stats.act_rate + excluded.act_rate,
           act_cast = daily_stats.act_cast + excluded.act_cast,
           act_pip = daily_stats.act_pip + excluded.act_pip,
           act_comment = daily_stats.act_comment + excluded.act_comment,
           act_follow = daily_stats.act_follow + excluded.act_follow,
           act_topic = daily_stats.act_topic + excluded.act_topic,
           act_user = daily_stats.act_user + excluded.act_user`
      ).bind(
        stats.day, idHash, stats.sessions, stats.durationSec, stats.vv, stats.crash,
        stats.startupP50, stats.startupP90, stats.startupSum, stats.startupCount,
        stats.playFail, stats.failNetwork, stats.failAuth, stats.failNotFound, stats.failServer, stats.failOther,
        stats.srOn, stats.srSupported, stats.qualityHd, stats.qualitySd, stats.playComplete,
        stats.pageHome, stats.pageSearch, stats.pageCategory, stats.pageProfile, stats.pagePlayer,
        stats.memPssKb, stats.memPeakKb, stats.memVssKb,
        stats.diskAppBytes, stats.diskCacheBytes, stats.diskDataBytes,
        stats.socStart, stats.socEnd, stats.tempMaxC, stats.charging,
        stats.linePrimaryOk, stats.linePrimaryFail, stats.lineMirrorOk, stats.lineMirrorFail,
        stats.lineSwitches, stats.lineLatencyAvgMs, stats.lineLatencyP90Ms,
        stats.cpuPct, stats.cpuPeakPct, stats.thermalLevel, stats.powerMw,
        stats.actShare, stats.actLike, stats.actUnlike, stats.actFav, stats.actUnfav, stats.actSearch,
        stats.actEpSwitch, stats.actRate, stats.actCast, stats.actPip, stats.actComment, stats.actFollow,
        stats.actTopic, stats.actUser
      ).run();
    }
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }

  // 配置应用回报（SPEC §15）：独立 try/catch——config_applies 表缺失或写入失败
  // 不应影响既有上报链路（迁移未执行时旧客户端仍能正常上报）。
  if (configApplies.length > 0) {
    try {
      await writeConfigApplies(env, configApplies);
    } catch {
    }
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

/* ── 远程配置下发 ──────────────────────────────────── */

/**
 * GET /v1/config?ver=&bucket=&platform=&cfg=
 *
 * 从 D1 读最新一条配置包，附加 HMAC 签名后下发。
 * - 未配置 CONFIG_SIGNING_KEY → 503（宁可不发，也不发未签名内容）
 * - cfg 与服务端版本相同 → 304 空 body
 * - 响应体带 config_id（配置唯一 ID，SPEC §16）
 * - 响应体超过 16 KB → 500
 *
 * ver / bucket / platform 预留给后续灰度定向；P1 阶段配置包对所有客户端一致，
 * 灰度比例由 payload 里的 rollout 字段交给客户端判定。
 */
async function handleConfig(url, env) {
  const signingKey = env.CONFIG_SIGNING_KEY || '';
  // 密钥过短会静默弱化签名，直接拒绝下发。
  if (signingKey.length > 0 && signingKey.length < 32) {
    return json({ error: 'config_unavailable', reason: 'signing_key_too_short' }, 503);
  }
  if (signingKey.length === 0) {
    return json({ error: 'config_unavailable' }, 503);
  }

  let row;
  try {
    row = await env.DB.prepare(
      'SELECT version, payload, updated_at, config_id FROM remote_config WHERE id = ? ORDER BY version DESC LIMIT 1'
    ).bind(CONFIG_ROW_ID).first();
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
  if (!row) {
    return json({ error: 'config_not_found' }, 404);
  }

  const version = toSafeInt(row.version, 0, 0, MAX_CONFIG_VERSION);
  if (version <= 0) {
    return json({ error: 'storage_failed' }, 500);
  }

  // 304 短路：客户端已是最新版本，省流量。
  const clientCfg = toSafeInt(url.searchParams.get('cfg'), 0, 0, MAX_CONFIG_VERSION);
  if (clientCfg === version) {
    return new Response(null, {
      status: 304,
      headers: { 'cache-control': CONFIG_CACHE_CONTROL },
    });
  }

  let parsed;
  try {
    parsed = JSON.parse(row.payload);
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return json({ error: 'storage_failed' }, 500);
  }

  // 只透传 payload 字段；版本、下发时间与 config_id 以 DB 为准，避免 payload 自相矛盾。
  const config = { ...parsed };
  delete config.sig;
  config.config_version = version;
  config.issued_at = toSafeInt(row.updated_at, 0, 0, Number.MAX_SAFE_INTEGER);
  // 配置唯一 ID（SPEC §16）：每次发布生成，全局唯一、永不复用。
  // 旧库（0009 迁移前）没有该列时为空串，客户端按「未下发」处理。
  config.config_id = typeof row.config_id === 'string' ? row.config_id : '';

  // 签名覆盖「去掉 sig 的完整响应体」，客户端删掉 sig 后重新序列化即可校验。
  const unsigned = JSON.stringify(config);
  const sig = (await hmacSha256Hex(signingKey, unsigned)).slice(0, 32);
  const body = JSON.stringify({ ...config, sig });
  if (new TextEncoder().encode(body).length > CONFIG_MAX_BYTES) {
    return json({ error: 'config_too_large' }, 500);
  }

  return new Response(body, {
    status: 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': CONFIG_CACHE_CONTROL,
    },
  });
}

/**
 * 管理写端点鉴权：x-admin-key 必须等于 CONFIG_ADMIN_KEY（未配置时回落 STATS_KEY）。
 * 返回 null 表示通过；否则返回可直接下发的错误响应。
 *
 * 写权限优先用独立的 CONFIG_ADMIN_KEY：STATS_KEY 是只读统计口令，曾出现在
 * /dashboard?key= 的 URL 里，复用它做写权限会把「读统计」的泄漏面放大成「写配置」。
 */
function adminAuthError(request, env) {
  const adminKey = (env.CONFIG_ADMIN_KEY || '').length > 0 ? env.CONFIG_ADMIN_KEY : (env.STATS_KEY || '');
  if (adminKey.length === 0) {
    return json({ error: 'admin_unavailable' }, 503);
  }
  if (!timingSafeEqual(request.headers.get('x-admin-key') || '', adminKey)) {
    return json({ error: 'forbidden' }, 401);
  }
  return null;
}

/**
 * POST /admin/config
 * header: x-admin-key = CONFIG_ADMIN_KEY（未配置时回落 STATS_KEY）
 * body: { version: 12, payload: { ... } }
 *
 * version 必须严格大于当前版本（防回滚）；payload 只要求是 JSON 对象，
 * 字段不做深度校验（客户端负责合并与类型/范围校验）。
 * 每次成功发布生成新的 config_id（crypto.randomUUID()），全局唯一、永不复用；
 * 同一 version 重发返回 409，因此同一版本的 config_id 不可变（SPEC §16）。
 */
async function handleAdminConfig(request, env) {
  const authError = adminAuthError(request, env);
  if (authError !== null) {
    return authError;
  }

  const declared = Number(request.headers.get('content-length') || '0');
  if (declared > MAX_ADMIN_BODY_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }
  let raw;
  try {
    raw = await request.text();
  } catch {
    return json({ error: 'bad_body' }, 400);
  }
  if (raw.length === 0 || raw.length > MAX_ADMIN_BODY_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }

  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: 'bad_json' }, 400);
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return json({ error: 'bad_json' }, 400);
  }

  const version = body.version;
  if (typeof version !== 'number' || !Number.isSafeInteger(version) ||
      version <= 0 || version > MAX_CONFIG_VERSION) {
    return json({ error: 'bad_version' }, 400);
  }
  const payload = body.payload;
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    return json({ error: 'bad_payload' }, 400);
  }

  const now = Math.floor(Date.now() / 1000);
  // 配置唯一 ID（SPEC §16）：每次发布生成，全局唯一、永不复用。
  // 用 UUID 而不是自增序号：多实例/重试时也不会撞号，且不泄露发布次数。
  const configId = crypto.randomUUID();
  // config_version / issued_at 由服务端注入，payload 里的同名字段与 sig 一律忽略。
  const stored = { config_version: version, issued_at: now };
  for (const key of Object.keys(payload)) {
    if (key === 'sig' || key === 'config_version' || key === 'issued_at') {
      continue;
    }
    stored[key] = payload[key];
  }
  const payloadText = JSON.stringify(stored);

  // 写入前按最终响应体（含 sig 与 config_id）校验 16 KB，避免存进去却永远发不出去。
  const finalBytes = new TextEncoder().encode(
    JSON.stringify({ ...stored, config_id: configId, sig: '0'.repeat(32) })
  ).length;
  if (finalBytes > CONFIG_MAX_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }

  // 版本单调：先读当前版本给出明确 409；写入时再用 WHERE 兜住并发竞争。
  let current = 0;
  try {
    const row = await env.DB.prepare(
      'SELECT MAX(version) AS max_version FROM remote_config WHERE id = ?'
    ).bind(CONFIG_ROW_ID).first();
    current = row && typeof row.max_version === 'number' ? row.max_version : 0;
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
  if (version <= current) {
    return json({ error: 'version_conflict' }, 409);
  }

  let changes = 1;
  try {
    const res = await env.DB.prepare(
      `INSERT INTO remote_config (id, version, payload, updated_at, config_id)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         version = excluded.version,
         payload = excluded.payload,
         updated_at = excluded.updated_at,
         config_id = excluded.config_id
       WHERE excluded.version > remote_config.version`
    ).bind(CONFIG_ROW_ID, version, payloadText, now, configId).run();
    changes = res && res.meta && typeof res.meta.changes === 'number' ? res.meta.changes : 1;
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
  if (changes === 0) {
    return json({ error: 'version_conflict' }, 409);
  }

  return json({ ok: true, version, config_id: configId, updated_at: now }, 200,
    { 'cache-control': 'no-store' });
}

/* ── 更新闸门（P4）──────────────────────────────────── */

/** 下载地址白名单：只接受 https 外链，其余回落官方 Release 页。 */
function releaseUrlOf(value) {
  const url = typeof value === 'string' ? value.trim() : '';
  if (url.length === 0 || url.length > MAX_RELEASE_URL_LEN || !url.startsWith('https://')) {
    return DEFAULT_RELEASE_URL;
  }
  return url;
}

/**
 * GET /v1/update?ver=&bucket=
 *
 * 从 D1 app_release 读最新版本信息，附加 HMAC-SHA256 签名后下发。
 * 客户端据 min_version / latest / rollout_pct 判定 force / soft / none 三态：
 *   force = current < min_version（强制更新）
 *   soft  = current < latest && bucket < rollout_pct（灰度提示）
 * 未配置 CONFIG_SIGNING_KEY → 503（不发未签名内容）；无发布记录 → 404。
 *
 * ver / bucket 由客户端带上，服务端当前不做定向（rollout_pct 原样下发，客户端分桶判定）。
 */
async function handleUpdate(env) {
  const signingKey = env.CONFIG_SIGNING_KEY || '';
  if (signingKey.length === 0) {
    return json({ error: 'update_unavailable' }, 503);
  }
  if (signingKey.length < 32) {
    return json({ error: 'update_unavailable', reason: 'signing_key_too_short' }, 503);
  }

  let row;
  try {
    row = await env.DB.prepare(
      'SELECT latest, min_version, rollout_pct, notes, url, updated_at FROM app_release WHERE id = ? ORDER BY updated_at DESC LIMIT 1'
    ).bind(RELEASE_ROW_ID).first();
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
  if (!row) {
    return json({ error: 'release_not_found' }, 404);
  }

  const latest = typeof row.latest === 'string' ? row.latest.trim() : '';
  const minVersion = typeof row.min_version === 'string' ? row.min_version.trim() : '';
  if (!VERSION_RE.test(latest) || !VERSION_RE.test(minVersion)) {
    return json({ error: 'storage_failed' }, 500);
  }
  const rolloutPct = toSafeInt(row.rollout_pct, 0, 0, 100);
  const body = {
    latest,
    min_version: minVersion,
    rollout_pct: rolloutPct,
    notes: clipText(row.notes, MAX_RELEASE_NOTES_LEN),
    url: releaseUrlOf(row.url),
  };

  // 签名覆盖「去掉 sig 的完整响应体」，客户端删掉 sig 后重新序列化即可校验。
  const unsigned = JSON.stringify(body);
  const sig = (await hmacSha256Hex(signingKey, unsigned)).slice(0, 32);
  const out = JSON.stringify({ ...body, sig });
  if (new TextEncoder().encode(out).length > UPDATE_MAX_BYTES) {
    return json({ error: 'update_too_large' }, 500);
  }

  return new Response(out, {
    status: 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': UPDATE_CACHE_CONTROL,
    },
  });
}

/**
 * POST /admin/release
 * header: x-admin-key = CONFIG_ADMIN_KEY（未配置时回落 STATS_KEY）
 * body: { latest: "2.3.0", min_version: "2.1.0", rollout_pct: 20, notes?: "...", url?: "https://..." }
 *
 * 覆盖式写入（单行 id='global'）：版本信息不是配置，没有单调版本语义，
 * 每次发布直接覆盖；rollout_pct 限制 0-100，url 只接受 https。
 */
async function handleAdminRelease(request, env) {
  const authError = adminAuthError(request, env);
  if (authError !== null) {
    return authError;
  }

  const declared = Number(request.headers.get('content-length') || '0');
  if (declared > MAX_ADMIN_BODY_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }
  let raw;
  try {
    raw = await request.text();
  } catch {
    return json({ error: 'bad_body' }, 400);
  }
  if (raw.length === 0 || raw.length > MAX_ADMIN_BODY_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }

  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: 'bad_json' }, 400);
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return json({ error: 'bad_json' }, 400);
  }

  const latest = typeof body.latest === 'string' ? body.latest.trim() : '';
  const minVersion = typeof body.min_version === 'string' ? body.min_version.trim() : '';
  if (!VERSION_RE.test(latest) || !VERSION_RE.test(minVersion)) {
    return json({ error: 'bad_version' }, 400);
  }
  const rolloutPct = body.rollout_pct;
  if (typeof rolloutPct !== 'number' || !Number.isSafeInteger(rolloutPct) ||
      rolloutPct < 0 || rolloutPct > 100) {
    return json({ error: 'bad_rollout_pct' }, 400);
  }
  const notes = clipText(body.notes, MAX_RELEASE_NOTES_LEN);
  const rawUrl = typeof body.url === 'string' ? body.url.trim() : '';
  if (rawUrl.length > 0 && (rawUrl.length > MAX_RELEASE_URL_LEN || !rawUrl.startsWith('https://'))) {
    return json({ error: 'bad_url' }, 400);
  }
  const url = rawUrl.length > 0 ? rawUrl : DEFAULT_RELEASE_URL;

  const now = Math.floor(Date.now() / 1000);
  try {
    await env.DB.prepare(
      `INSERT INTO app_release (id, latest, min_version, rollout_pct, notes, url, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET
         latest = excluded.latest,
         min_version = excluded.min_version,
         rollout_pct = excluded.rollout_pct,
         notes = excluded.notes,
         url = excluded.url,
         updated_at = excluded.updated_at`
    ).bind(RELEASE_ROW_ID, latest, minVersion, rolloutPct, notes, url, now).run();
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }

  return json({ ok: true, latest, min_version: minVersion, rollout_pct: rolloutPct, updated_at: now },
    200, { 'cache-control': 'no-store' });
}

/* ── 资源热更新（P5）────────────────────────────────── */

/**
 * GET /v1/assets/manifest
 *
 * 返回当前全部远程资源清单：{ version, assets: [{ name, sha256, size, url }], sig }。
 * version = 所有资源里的最大版本（每次 /admin/asset 上传都会 +1），客户端据此判断是否有更新。
 * 未配置 CONFIG_SIGNING_KEY → 503（不发未签名清单）；无资源时返回空清单（version=0）。
 */
async function handleAssetsManifest(env) {
  const signingKey = env.CONFIG_SIGNING_KEY || '';
  if (signingKey.length === 0) {
    return json({ error: 'assets_unavailable' }, 503);
  }
  if (signingKey.length < 32) {
    return json({ error: 'assets_unavailable', reason: 'signing_key_too_short' }, 503);
  }

  let rows;
  try {
    rows = await env.DB.prepare(
      'SELECT name, version, sha256, size FROM remote_assets ORDER BY name ASC'
    ).all();
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }

  const list = rows && Array.isArray(rows.results) ? rows.results : [];
  let version = 0;
  const assets = [];
  for (let i = 0; i < list.length && assets.length < ASSET_MAX_COUNT; i++) {
    const row = list[i];
    if (!row || typeof row !== 'object') {
      continue;
    }
    const name = typeof row.name === 'string' ? row.name : '';
    if (!ASSET_NAME_RE.test(name)) {
      continue;
    }
    const sha = typeof row.sha256 === 'string' ? row.sha256.toLowerCase() : '';
    if (!ASSET_SHA_RE.test(sha)) {
      continue;
    }
    const size = toSafeInt(row.size, 0, 0, ASSET_MAX_FILE_BYTES);
    if (size <= 0) {
      continue;
    }
    const rowVersion = toSafeInt(row.version, 0, 0, MAX_CONFIG_VERSION);
    if (rowVersion > version) {
      version = rowVersion;
    }
    assets.push({ name, sha256: sha, size, url: '/v1/assets/' + name });
  }

  const body = { version, assets };
  // 签名覆盖「去掉 sig 的完整响应体」，客户端删掉 sig 后重新序列化即可校验。
  const unsigned = JSON.stringify(body);
  const sig = (await hmacSha256Hex(signingKey, unsigned)).slice(0, 32);
  const out = JSON.stringify({ ...body, sig });

  return new Response(out, {
    status: 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': ASSET_CACHE_CONTROL,
    },
  });
}

/**
 * GET /v1/assets/<name>
 *
 * 返回资源原始字节（application/octet-stream）。完整性由客户端按清单里的
 * SHA-256 校验，服务端不重复计算；name 只允许白名单字符，非法/不存在统一 404。
 */
async function handleAssetDownload(url, env) {
  const prefix = '/v1/assets/';
  const name = url.pathname.slice(prefix.length);
  if (!ASSET_NAME_RE.test(name)) {
    return json({ error: 'asset_not_found' }, 404);
  }

  let row;
  try {
    row = await env.DB.prepare(
      'SELECT content, size, sha256 FROM remote_assets WHERE name = ?'
    ).bind(name).first();
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
  if (!row || !row.content) {
    return json({ error: 'asset_not_found' }, 404);
  }

  const headers = {
    'content-type': 'application/octet-stream',
    'cache-control': ASSET_CACHE_CONTROL,
  };
  const sha = typeof row.sha256 === 'string' ? row.sha256.toLowerCase() : '';
  if (ASSET_SHA_RE.test(sha)) {
    headers['x-content-sha256'] = sha;
  }
  // D1 的 BLOB 在不同运行时下可能返回 ArrayBuffer / Uint8Array / 普通数组，
  // 直接丢给 Response 在部分情况下会得到空 body（实测线上返回 0 字节）。
  // 统一转成 Uint8Array 再返回。
  const body = toBytes(row.content);
  if (body === null) {
    return json({ error: 'asset_corrupt' }, 500);
  }
  return new Response(body, { status: 200, headers });
}

/** 把 D1 返回的 BLOB 统一成 Uint8Array；无法识别返回 null。 */
function toBytes(value) {
  if (value === null || value === undefined) {
    return null;
  }
  if (value instanceof Uint8Array) {
    return value;
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  if (Array.isArray(value)) {
    return new Uint8Array(value);
  }
  return null;
}

/**
 * POST /admin/asset
 * header: x-admin-key = CONFIG_ADMIN_KEY（未配置时回落 STATS_KEY）
 * body: { name: "home_banner", content_base64: "..." }
 *
 * 服务端计算 SHA-256 并落库；单文件 ≤ 512 KB，全部资源总量 ≤ 4 MB。
 * 每次上传把 manifest 版本推进 1（同名覆盖也推进），客户端据此重新拉取。
 */
async function handleAdminAsset(request, env) {
  const authError = adminAuthError(request, env);
  if (authError !== null) {
    return authError;
  }

  const declared = Number(request.headers.get('content-length') || '0');
  if (declared > MAX_ASSET_ADMIN_BODY_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }
  let raw;
  try {
    raw = await request.text();
  } catch {
    return json({ error: 'bad_body' }, 400);
  }
  if (raw.length === 0 || raw.length > MAX_ASSET_ADMIN_BODY_BYTES) {
    return json({ error: 'payload_too_large' }, 413);
  }

  let body;
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: 'bad_json' }, 400);
  }
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return json({ error: 'bad_json' }, 400);
  }

  const name = typeof body.name === 'string' ? body.name.trim() : '';
  if (!ASSET_NAME_RE.test(name)) {
    return json({ error: 'bad_name' }, 400);
  }
  const contentBase64 = typeof body.content_base64 === 'string' ? body.content_base64 : '';
  if (contentBase64.length === 0) {
    return json({ error: 'bad_content' }, 400);
  }
  let bytes;
  try {
    bytes = base64ToBytes(contentBase64);
  } catch {
    return json({ error: 'bad_content' }, 400);
  }
  if (bytes.length === 0) {
    return json({ error: 'bad_content' }, 400);
  }
  if (bytes.length > ASSET_MAX_FILE_BYTES) {
    return json({ error: 'asset_too_large' }, 413);
  }

  // 总量上限：排除同名旧文件（覆盖上传只增加差值）。
  let total = 0;
  try {
    const row = await env.DB.prepare(
      'SELECT COALESCE(SUM(size), 0) AS total FROM remote_assets WHERE name != ?'
    ).bind(name).first();
    total = row && typeof row.total === 'number' ? row.total : 0;
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
  if (total + bytes.length > ASSET_MAX_TOTAL_BYTES) {
    return json({ error: 'assets_too_large' }, 413);
  }

  // 条数上限：manifest 一次最多下发 ASSET_MAX_COUNT 条，超出会导致部分资源永远不可见。
  let count = 0;
  try {
    const row = await env.DB.prepare(
      'SELECT COUNT(*) AS n FROM remote_assets WHERE name != ?'
    ).bind(name).first();
    count = row && typeof row.n === 'number' ? row.n : 0;
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
  if (count >= ASSET_MAX_COUNT) {
    return json({ error: 'too_many_assets' }, 413);
  }

  // manifest 版本 = 当前最大版本 + 1（每次上传单调递增）。
  let maxVersion = 0;
  try {
    const row = await env.DB.prepare(
      'SELECT COALESCE(MAX(version), 0) AS max_version FROM remote_assets'
    ).first();
    maxVersion = row && typeof row.max_version === 'number' ? row.max_version : 0;
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }
  const version = maxVersion + 1;
  if (version > MAX_CONFIG_VERSION) {
    return json({ error: 'storage_failed' }, 500);
  }

  const sha = await sha256BytesHex(bytes);
  const now = Math.floor(Date.now() / 1000);
  try {
    await env.DB.prepare(
      `INSERT INTO remote_assets (name, version, sha256, size, content, updated_at)
       VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT(name) DO UPDATE SET
         version = excluded.version,
         sha256 = excluded.sha256,
         size = excluded.size,
         content = excluded.content,
         updated_at = excluded.updated_at`
    ).bind(name, version, sha, bytes.length, bytes.buffer, now).run();
  } catch {
    return json({ error: 'storage_failed' }, 500);
  }

  return json({ ok: true, name, version, sha256: sha, size: bytes.length, updated_at: now },
    200, { 'cache-control': 'no-store' });
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
              COALESCE(AVG(NULLIF(mem_pss_kb, 0)), 0) AS avg_mem_pss,
              COALESCE(MAX(mem_peak_kb), 0) AS max_mem_peak,
              COALESCE(AVG(NULLIF(mem_vss_kb, 0)), 0) AS avg_mem_vss,
              COALESCE(AVG(NULLIF(disk_app_bytes, 0)), 0) AS avg_disk_app,
              COALESCE(AVG(NULLIF(disk_cache_bytes, 0)), 0) AS avg_disk_cache,
              COALESCE(AVG(NULLIF(disk_data_bytes, 0)), 0) AS avg_disk_data,
              COALESCE(SUM(CASE WHEN charging = 0 AND soc_start > 0 AND soc_end > 0
                                THEN MAX(soc_start - soc_end, 0) ELSE 0 END), 0) AS soc_drain_sum,
              COALESCE(SUM(CASE WHEN charging = 0 AND soc_start > 0 AND soc_end > 0
                                THEN 1 ELSE 0 END), 0) AS soc_drain_samples,
              COALESCE(AVG(NULLIF(temp_max_c, 0)), 0) AS avg_temp,
              COALESCE(MAX(temp_max_c), 0) AS max_temp,
              COALESCE(SUM(line_primary_ok), 0) AS line_primary_ok,
              COALESCE(SUM(line_primary_fail), 0) AS line_primary_fail,
              COALESCE(SUM(line_mirror_ok), 0) AS line_mirror_ok,
              COALESCE(SUM(line_mirror_fail), 0) AS line_mirror_fail,
              COALESCE(SUM(line_switches), 0) AS line_switches,
              COALESCE(AVG(NULLIF(line_latency_avg_ms, 0)), 0) AS avg_latency,
              COALESCE(AVG(NULLIF(line_latency_p90_ms, 0)), 0) AS avg_latency_p90,
              COALESCE(AVG(NULLIF(cpu_pct, 0)), 0) AS avg_cpu,
              COALESCE(MAX(cpu_peak_pct), 0) AS max_cpu_peak,
              COALESCE(MAX(thermal_level), 0) AS max_thermal,
              COALESCE(AVG(NULLIF(power_mw, 0)), 0) AS avg_power_mw,
              COALESCE(SUM(act_share), 0) AS act_share,
              COALESCE(SUM(act_like), 0) AS act_like,
              COALESCE(SUM(act_unlike), 0) AS act_unlike,
              COALESCE(SUM(act_fav), 0) AS act_fav,
              COALESCE(SUM(act_unfav), 0) AS act_unfav,
              COALESCE(SUM(act_search), 0) AS act_search,
              COALESCE(SUM(act_ep_switch), 0) AS act_ep_switch,
              COALESCE(SUM(act_rate), 0) AS act_rate,
              COALESCE(SUM(act_cast), 0) AS act_cast,
              COALESCE(SUM(act_pip), 0) AS act_pip,
              COALESCE(SUM(act_comment), 0) AS act_comment,
              COALESCE(SUM(act_follow), 0) AS act_follow,
              COALESCE(SUM(act_topic), 0) AS act_topic,
              COALESCE(SUM(act_user), 0) AS act_user,
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

    // 配置应用回报（C10 / SPEC §15）：按 (config_id, key, old, new, source) 聚合，取最近 200 行。
    // 迁移 0010 未执行时 /stats 仍可用（只是没有配置应用段），不影响既有统计。
    let configApplyRows = { results: [] };
    try {
      configApplyRows = await env.DB.prepare(
        `SELECT config_id, config_version, key, old_value, new_value, source,
                count, first_at, last_at
           FROM config_applies
          ORDER BY config_version DESC, count DESC, last_at DESC
          LIMIT 200`
      ).all();
    } catch {
    }

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

    // 配置应用：按 config_id 分组，展示「哪一次下发改了哪些 key、影响多少设备」。
    // count 是设备·天口径（每台设备每天只上报一次），没有设备标识可做精确去重。
    const configApplyConfigs = [];
    const configApplyIndex = new Map();
    let configApplyTotal = 0;
    const configApplyResultRows = configApplyRows && configApplyRows.results ?
      configApplyRows.results : [];
    for (const row of configApplyResultRows) {
      const configId = typeof row.config_id === 'string' ? row.config_id : '';
      let group = configApplyIndex.get(configId);
      if (!group) {
        group = {
          config_id: configId,
          config_version: toSafeInt(row.config_version, 0, 0, MAX_CONFIG_VERSION),
          devices: 0,
          changes: [],
        };
        configApplyIndex.set(configId, group);
        configApplyConfigs.push(group);
      }
      const count = toSafeInt(row.count, 0, 0, MAX_COUNTER);
      group.devices += count;
      configApplyTotal += count;
      group.changes.push({
        key: typeof row.key === 'string' ? row.key : '',
        old: typeof row.old_value === 'string' ? row.old_value : '',
        new: typeof row.new_value === 'string' ? row.new_value : '',
        source: typeof row.source === 'string' ? row.source : '',
        count,
        first_at: toSafeInt(row.first_at, 0, 0, Number.MAX_SAFE_INTEGER),
        last_at: toSafeInt(row.last_at, 0, 0, Number.MAX_SAFE_INTEGER),
      });
    }

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
      // 设备侧指标
      device: {
        mem_pss_avg_kb: totals ? Math.round(totals.avg_mem_pss) : 0,
        mem_peak_kb: totals ? totals.max_mem_peak : 0,
        mem_vss_avg_kb: totals ? Math.round(totals.avg_mem_vss) : 0,
        disk_app_avg_bytes: totals ? Math.round(totals.avg_disk_app) : 0,
        disk_cache_avg_bytes: totals ? Math.round(totals.avg_disk_cache) : 0,
        disk_data_avg_bytes: totals ? Math.round(totals.avg_disk_data) : 0,
        soc_drain_avg_pct: totals && totals.soc_drain_samples > 0 ?
          Math.round((totals.soc_drain_sum / totals.soc_drain_samples) * 10) / 10 : 0,
        soc_drain_samples: totals ? totals.soc_drain_samples : 0,
        temp_avg_c: totals ? Math.round(totals.avg_temp * 10) / 10 : 0,
        temp_max_c: totals ? Math.round(totals.max_temp * 10) / 10 : 0,
        cpu_avg_pct: totals ? Math.round(totals.avg_cpu) : 0,
        cpu_peak_pct: totals ? totals.max_cpu_peak : 0,
        thermal_max: totals ? totals.max_thermal : 0,
        power_mw_avg: totals ? Math.round(totals.avg_power_mw) : 0,
      },
      // 线路指标
      lines: {
        primary_ok: totals ? totals.line_primary_ok : 0,
        primary_fail: totals ? totals.line_primary_fail : 0,
        mirror_ok: totals ? totals.line_mirror_ok : 0,
        mirror_fail: totals ? totals.line_mirror_fail : 0,
        primary_fail_rate: pct(totals ? totals.line_primary_fail : 0,
          (totals ? totals.line_primary_ok + totals.line_primary_fail : 0)),
        mirror_fail_rate: pct(totals ? totals.line_mirror_fail : 0,
          (totals ? totals.line_mirror_ok + totals.line_mirror_fail : 0)),
        mirror_share: pct(totals ? totals.line_mirror_ok + totals.line_mirror_fail : 0,
          (totals ? totals.line_primary_ok + totals.line_primary_fail +
            totals.line_mirror_ok + totals.line_mirror_fail : 0)),
        switches: totals ? totals.line_switches : 0,
        latency_avg_ms: totals ? Math.round(totals.avg_latency) : 0,
        latency_p90_ms: totals ? Math.round(totals.avg_latency_p90) : 0,
      },
      // 用户行为计数（区间累计）
      actions: {
        share: totals ? totals.act_share : 0,
        like: totals ? totals.act_like : 0,
        unlike: totals ? totals.act_unlike : 0,
        fav: totals ? totals.act_fav : 0,
        unfav: totals ? totals.act_unfav : 0,
        search: totals ? totals.act_search : 0,
        ep_switch: totals ? totals.act_ep_switch : 0,
        rate: totals ? totals.act_rate : 0,
        cast: totals ? totals.act_cast : 0,
        pip: totals ? totals.act_pip : 0,
        comment: totals ? totals.act_comment : 0,
        follow: totals ? totals.act_follow : 0,
        topic: totals ? totals.act_topic : 0,
        user: totals ? totals.act_user : 0,
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
      // 配置应用回报（C10 / SPEC §15）：按 config_id 分组
      config_apply: {
        total: configApplyTotal,
        configs: configApplyConfigs,
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
    // 设备侧指标
    memPssKb: toSafeInt(raw.mem_pss_kb, 0, 0, 16 * 1024 * 1024),
    memPeakKb: toSafeInt(raw.mem_peak_kb, 0, 0, 16 * 1024 * 1024),
    memVssKb: toSafeInt(raw.mem_vss_kb, 0, 0, 64 * 1024 * 1024),
    diskAppBytes: toSafeInt(raw.disk_app_bytes, 0, 0, 1e12),
    diskCacheBytes: toSafeInt(raw.disk_cache_bytes, 0, 0, 1e12),
    diskDataBytes: toSafeInt(raw.disk_data_bytes, 0, 0, 1e12),
    socStart: toSafeInt(raw.soc_start, 0, 0, 100),
    socEnd: toSafeInt(raw.soc_end, 0, 0, 100),
    tempMaxC: toSafeFloat(raw.temp_max_c, 0, 0, 100),
    charging: toSafeInt(raw.charging, 0, 0, 1),
    // 线路指标
    linePrimaryOk: n(raw.line_primary_ok),
    linePrimaryFail: n(raw.line_primary_fail),
    lineMirrorOk: n(raw.line_mirror_ok),
    lineMirrorFail: n(raw.line_mirror_fail),
    lineSwitches: n(raw.line_switches),
    lineLatencyAvgMs: toSafeInt(raw.line_latency_avg_ms, 0, 0, 600000),
    lineLatencyP90Ms: toSafeInt(raw.line_latency_p90_ms, 0, 0, 600000),
    // 功耗与性能
    cpuPct: toSafeInt(raw.cpu_pct, 0, 0, 100),
    cpuPeakPct: toSafeInt(raw.cpu_peak_pct, 0, 0, 100),
    thermalLevel: toSafeInt(raw.thermal_level, 0, 0, 7),
    powerMw: toSafeInt(raw.power_mw, 0, 0, 100000),
    // 用户行为计数
    actShare: n(raw.act_share),
    actLike: n(raw.act_like),
    actUnlike: n(raw.act_unlike),
    actFav: n(raw.act_fav),
    actUnfav: n(raw.act_unfav),
    actSearch: n(raw.act_search),
    actEpSwitch: n(raw.act_ep_switch),
    actRate: n(raw.act_rate),
    actCast: n(raw.act_cast),
    actPip: n(raw.act_pip),
    actComment: n(raw.act_comment),
    actFollow: n(raw.act_follow),
    actTopic: n(raw.act_topic),
    actUser: n(raw.act_user),
  };
}

/**
 * 解析并裁剪客户端上报的配置应用记录（SPEC §15.2 / C10）。
 *
 * 安全与兼容约定：
 * - 非数组/缺省 → 空数组（旧客户端不带该字段，行为不变）；
 * - 单条非法（key 不是 snake_case、source 不在白名单、字段类型不符）→ 丢弃该条；
 * - old === new 不算「应用」（客户端已过滤，服务端再兜一层）；
 * - 单条字段超长裁剪，最多 MAX_CONFIG_APPLY 条（超出丢弃最旧的，保留数组末尾）；
 * - 同一批里主键 (config_id, key, old, new, source) 相同的条目合并计数，
 *   避免 UPSERT 自冲突，也避免一次上报灌出大量行。
 *
 * 返回 [{ configId, configVersion, key, oldValue, newValue, source, count, firstAt, lastAt }]。
 */
function parseConfigApplies(raw, now) {
  if (!Array.isArray(raw)) {
    return [];
  }
  const start = Math.max(0, raw.length - MAX_CONFIG_APPLY);
  const merged = new Map();
  for (let i = start; i < raw.length; i++) {
    const item = raw[i];
    if (!item || typeof item !== 'object' || Array.isArray(item)) {
      continue;
    }
    const configId = typeof item.config_id === 'string' ? item.config_id.trim() : '';
    if (configId.length > MAX_CONFIG_ID_LEN || !CONFIG_ID_RE.test(configId)) {
      continue;
    }
    const key = typeof item.key === 'string' ? item.key.trim() : '';
    if (key.length > MAX_CONFIG_KEY_LEN || !CONFIG_KEY_RE.test(key)) {
      continue;
    }
    const source = typeof item.source === 'string' ? item.source : '';
    if (!CONFIG_SOURCES.has(source)) {
      continue;
    }
    const oldValue = clipText(item.old, MAX_CONFIG_VALUE_LEN);
    const newValue = clipText(item.new, MAX_CONFIG_VALUE_LEN);
    if (oldValue === newValue) {
      continue;
    }
    const configVersion = toSafeInt(item.config_version, 0, 0, MAX_CONFIG_VERSION);
    // applied_at 缺省/为 0 时按服务端收到的时间计；未来时间最多容忍 1 天（客户端时钟偏差）。
    const appliedAt = toSafeInt(item.applied_at, now, 0, now + 86400) || now;
    const mergeKey = `${configId}\u0000${key}\u0000${oldValue}\u0000${newValue}\u0000${source}`;
    const cur = merged.get(mergeKey);
    if (cur) {
      cur.count += 1;
      cur.firstAt = Math.min(cur.firstAt, appliedAt);
      cur.lastAt = Math.max(cur.lastAt, appliedAt);
      if (configVersion > cur.configVersion) {
        cur.configVersion = configVersion;
      }
    } else {
      merged.set(mergeKey, {
        configId,
        configVersion,
        key,
        oldValue,
        newValue,
        source,
        count: 1,
        firstAt: appliedAt,
        lastAt: appliedAt,
      });
    }
  }
  return [...merged.values()];
}

/**
 * 写入配置应用聚合表（SPEC §15.3）：按主键累加计数，只存聚合值、不存设备标识。
 * 调用方负责 try/catch：写失败不能影响主统计上报。
 */
async function writeConfigApplies(env, applies) {
  for (const apply of applies) {
    await env.DB.prepare(
      `INSERT INTO config_applies
         (config_id, config_version, key, old_value, new_value, source, count, first_at, last_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(config_id, key, old_value, new_value, source) DO UPDATE SET
         count = config_applies.count + excluded.count,
         last_at = MAX(config_applies.last_at, excluded.last_at)`
    ).bind(
      apply.configId, apply.configVersion, apply.key, apply.oldValue, apply.newValue,
      apply.source, apply.count, apply.firstAt, apply.lastAt
    ).run();
  }
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

/** 安全取浮点：缺省/非数字/NaN 返回 fallback，再夹到 [min, max]。 */
function toSafeFloat(value, fallback, min, max) {
  if (value === null || value === undefined || value === '') {
    return fallback;
  }
  const n = typeof value === 'number' ? value : Number(value);
  if (!Number.isFinite(n)) {
    return fallback;
  }
  return clamp(n, min, max);
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

/** HMAC-SHA256(secret, text) → 64 位小写十六进制。 */
async function hmacSha256Hex(secret, text) {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    'raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']
  );
  const mac = await crypto.subtle.sign('HMAC', key, enc.encode(text));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Base64 → 字节数组；非法输入抛异常（调用方转 400）。 */
function base64ToBytes(text) {
  const binary = atob(text);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/** 字节数组的 SHA-256 → 64 位小写十六进制。 */
async function sha256BytesHex(bytes) {
  const buf = await crypto.subtle.digest('SHA-256', bytes);
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
export { sha256Hex, hmacSha256Hex, timingSafeEqual, verifySignature, parseStats, parseDay, dayStamp, toSafeInt };
