import assert from 'node:assert/strict';
import { test } from 'node:test';

import worker, { sha256Hex, hmacSha256Hex, timingSafeEqual, verifySignature, parseStats, parseDay, dayStamp, toSafeInt } from '../src/index.js';

/** 极简 D1 内存替身：只实现 Worker 实际用到的几条 SQL。 */
function makeDB() {
  const devices = new Map();
  const rates = new Map();
  const dailyActive = new Set();
  const dailyStats = new Map();
  const crashGroups = new Map();
  const crashVersions = new Map();
  const remoteConfig = new Map();
  return {
    devices,
    rates,
    dailyActive,
    dailyStats,
    crashGroups,
    crashVersions,
    remoteConfig,
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
          if (sql.includes('SUM(count)') && sql.includes('FROM crash_groups')) {
            let n = 0;
            for (const g of crashGroups.values()) n += g.count;
            return { n };
          }
          if (sql.includes('SUM(sessions)')) {
            const acc = {
              sessions: 0, duration_sec: 0, vv: 0, crash: 0,
              play_fail: 0, fail_network: 0, fail_auth: 0, fail_notfound: 0,
              fail_server: 0, fail_other: 0, sr_on: 0, sr_supported: 0,
              quality_hd: 0, quality_sd: 0, play_complete: 0,
              startup_ms_sum: 0, startup_ms_count: 0, avg_p50: 0, avg_p90: 0,
              page_home: 0, page_search: 0, page_category: 0, page_profile: 0, page_player: 0,
              line_primary_ok: 0, line_primary_fail: 0, line_mirror_ok: 0, line_mirror_fail: 0,
              line_switches: 0, soc_drain_sum: 0, soc_drain_samples: 0,
              avg_mem_pss: 0, max_mem_peak: 0, avg_mem_vss: 0,
              avg_disk_app: 0, avg_disk_cache: 0, avg_disk_data: 0,
              avg_temp: 0, max_temp: 0, avg_latency: 0, avg_latency_p90: 0,
              avg_cpu: 0, max_cpu_peak: 0, max_thermal: 0, avg_power_mw: 0,
              act_share: 0,
              act_like: 0,
              act_unlike: 0,
              act_fav: 0,
              act_unfav: 0,
              act_search: 0,
              act_ep_switch: 0,
              act_rate: 0,
              act_cast: 0,
              act_pip: 0,
              act_comment: 0,
              act_follow: 0,
              act_topic: 0,
              act_user: 0,
            };
            let p50Sum = 0, p50N = 0, p90Sum = 0, p90N = 0;
            for (const v of dailyStats.values()) {
              for (const k of Object.keys(acc)) {
                if (typeof v[k] === 'number') acc[k] += v[k];
              }
              if (v.startup_p50_ms > 0) { p50Sum += v.startup_p50_ms; p50N += 1; }
              if (v.startup_p90_ms > 0) { p90Sum += v.startup_p90_ms; p90N += 1; }
            }
            acc.avg_p50 = p50N > 0 ? p50Sum / p50N : 0;
            acc.avg_p90 = p90N > 0 ? p90Sum / p90N : 0;

            // 设备/线路派生量
            let memSum = 0, memN = 0, vssSum = 0, vssN = 0;
            let appSum = 0, appN = 0, cacheSum = 0, cacheN = 0, dataSum = 0, dataN = 0;
            let tempSum = 0, tempN = 0, latSum = 0, latN = 0, latP90Sum = 0, latP90N = 0;
            for (const v of dailyStats.values()) {
              if (v.mem_pss_kb > 0) { memSum += v.mem_pss_kb; memN += 1; }
              if (v.mem_vss_kb > 0) { vssSum += v.mem_vss_kb; vssN += 1; }
              if (v.disk_app_bytes > 0) { appSum += v.disk_app_bytes; appN += 1; }
              if (v.disk_cache_bytes > 0) { cacheSum += v.disk_cache_bytes; cacheN += 1; }
              if (v.disk_data_bytes > 0) { dataSum += v.disk_data_bytes; dataN += 1; }
              if (v.temp_max_c > 0) { tempSum += v.temp_max_c; tempN += 1; }
              if (v.line_latency_avg_ms > 0) { latSum += v.line_latency_avg_ms; latN += 1; }
              if (v.line_latency_p90_ms > 0) { latP90Sum += v.line_latency_p90_ms; latP90N += 1; }
              if (v.charging === 0 && v.soc_start > 0 && v.soc_end > 0) {
                acc.soc_drain_sum += Math.max(v.soc_start - v.soc_end, 0);
                acc.soc_drain_samples += 1;
              }
            }
            for (const v of dailyStats.values()) {
              if (v.mem_peak_kb > acc.max_mem_peak) acc.max_mem_peak = v.mem_peak_kb;
              if (v.temp_max_c > acc.max_temp) acc.max_temp = v.temp_max_c;
            }
            let cpuSum = 0, cpuN = 0, powerSum = 0, powerN = 0;
            for (const v of dailyStats.values()) {
              if (v.cpu_pct > 0) { cpuSum += v.cpu_pct; cpuN += 1; }
              if (v.cpu_peak_pct > acc.max_cpu_peak) acc.max_cpu_peak = v.cpu_peak_pct;
              if (v.thermal_level > acc.max_thermal) acc.max_thermal = v.thermal_level;
              if (v.power_mw > 0) { powerSum += v.power_mw; powerN += 1; }
            }
            acc.avg_cpu = cpuN > 0 ? cpuSum / cpuN : 0;
            acc.avg_power_mw = powerN > 0 ? powerSum / powerN : 0;
            acc.avg_mem_pss = memN > 0 ? memSum / memN : 0;
            acc.avg_mem_vss = vssN > 0 ? vssSum / vssN : 0;
            acc.avg_disk_app = appN > 0 ? appSum / appN : 0;
            acc.avg_disk_cache = cacheN > 0 ? cacheSum / cacheN : 0;
            acc.avg_disk_data = dataN > 0 ? dataSum / dataN : 0;
            acc.avg_temp = tempN > 0 ? tempSum / tempN : 0;
            acc.avg_latency = latN > 0 ? latSum / latN : 0;
            acc.avg_latency_p90 = latP90N > 0 ? latP90Sum / latP90N : 0;
            return acc;
          }
          if (sql.includes('SELECT count, expires_at FROM rate_limits')) {
            const r = rates.get(args[0]);
            return r ? { count: r.count, expires_at: r.expires_at } : null;
          }
          if (sql.includes('SELECT version, payload, updated_at, config_id FROM remote_config')) {
            let latest = null;
            for (const row of remoteConfig.values()) {
              if (latest === null || row.version > latest.version) latest = row;
            }
            return latest ? { ...latest } : null;
          }
          if (sql.includes('SELECT MAX(version) AS max_version FROM remote_config')) {
            let max = null;
            for (const row of remoteConfig.values()) {
              if (max === null || row.version > max) max = row.version;
            }
            return { max_version: max };
          }
          return null;
        },
        async all() {
          if (sql.includes('FROM crash_groups')) {
            const rows = [...crashGroups.values()].sort((a, b) => b.count - a.count);
            return { results: rows };
          }
          if (sql.includes('FROM crash_versions')) {
            return { results: [...crashVersions.values()] };
          }
          if (sql.includes('FROM daily_active')) {
            const from = args[0];
            const byDay = new Map();
            for (const key of dailyActive) {
              const d = Number(key.split(':')[0]);
              if (d < from) continue;
              byDay.set(d, (byDay.get(d) || 0) + 1);
            }
            const results = [...byDay.entries()].sort((a, b) => a[0] - b[0]).map(([d, n]) => ({
              day: d, devices: n, sessions: 0, duration_sec: 0, vv: 0, crash: 0,
            }));
            return { results };
          }
          return { results: [] };
        },
        async run() {
          if (sql.includes('INSERT OR IGNORE INTO daily_active')) {
            const k = `${args[0]}:${args[1]}`;
            const existed = dailyActive.has(k);
            dailyActive.add(k);
            // 模拟 D1：被 IGNORE 时 changes = 0
            return { success: true, meta: { changes: existed ? 0 : 1 } };
          }
          if (sql.includes('INSERT INTO daily_stats')) {
            const k = `${args[0]}:${args[1]}`;
            const cur = dailyStats.get(k) || {};
            const fields = [
              'sessions', 'duration_sec', 'vv', 'crash',
              'startup_p50_ms', 'startup_p90_ms', 'startup_ms_sum', 'startup_ms_count',
              'play_fail', 'fail_network', 'fail_auth', 'fail_notfound', 'fail_server', 'fail_other',
              'sr_on', 'sr_supported', 'quality_hd', 'quality_sd', 'play_complete',
              'page_home', 'page_search', 'page_category', 'page_profile', 'page_player',
              'mem_pss_kb', 'mem_peak_kb', 'mem_vss_kb',
              'disk_app_bytes', 'disk_cache_bytes', 'disk_data_bytes',
              'soc_start', 'soc_end', 'temp_max_c', 'charging',
              'line_primary_ok', 'line_primary_fail', 'line_mirror_ok', 'line_mirror_fail',
              'line_switches', 'line_latency_avg_ms', 'line_latency_p90_ms',
              'cpu_pct', 'cpu_peak_pct', 'thermal_level', 'power_mw',
              'act_share',
              'act_like',
              'act_unlike',
              'act_fav',
              'act_unfav',
              'act_search',
              'act_ep_switch',
              'act_rate',
              'act_cast',
              'act_pip',
              'act_comment',
              'act_follow',
              'act_topic',
              'act_user',
            ];
            const next = { ...cur };
            fields.forEach((f, i) => {
              const v = args[2 + i] || 0;
              // p50/p90 是设备级快照，覆盖；其余累加
              next[f] = (f === 'startup_p50_ms' || f === 'startup_p90_ms') ? v : (cur[f] || 0) + v;
            });
            dailyStats.set(k, next);
            return { success: true, meta: { changes: 1 } };
          }
          if (sql.includes('INSERT INTO crash_groups')) {
            const [fp, type, reason, message, stack, thread, first, last] = args;
            const cur = crashGroups.get(fp);
            crashGroups.set(fp, {
              fingerprint: fp, type, reason, message, stack, thread,
              count: (cur ? cur.count : 0) + 1,
              first_seen_epoch: cur ? cur.first_seen_epoch : first,
              last_seen_epoch: last,
            });
            return { success: true, meta: { changes: 1 } };
          }
          if (sql.includes('INSERT INTO crash_versions')) {
            const k = `${args[0]}:${args[1]}`;
            const cur = crashVersions.get(k) || { fingerprint: args[0], version: args[1], count: 0 };
            cur.count += 1;
            crashVersions.set(k, cur);
            return { success: true, meta: { changes: 1 } };
          }
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
          if (sql.includes('INSERT INTO remote_config')) {
            const [id, version, payload, updatedAt, configId] = args;
            const cur = remoteConfig.get(id);
            // 模拟 D1 的 ON CONFLICT ... WHERE excluded.version > version：旧版本不覆盖。
            if (cur && version <= cur.version) {
              return { success: true, meta: { changes: 0 } };
            }
            remoteConfig.set(id, {
              id, version, payload, updated_at: updatedAt, config_id: configId || '',
            });
            return { success: true, meta: { changes: 1 } };
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

/* ── 新增：安装日期 / 日活 / VV / 时长 ─────────────── */

function todayStamp() {
  const d = new Date();
  return d.getFullYear() * 10000 + (d.getMonth() + 1) * 100 + d.getDate();
}

test('上报 install_at 与 day 后，日活表有记录', async () => {
  const e = env();
  const day = todayStamp();
  const res = await worker.fetch(
    post({ id: UUID, ver: '2.3.0', model: 'ALN-AL00', os: 'HarmonyOS 7.0', install_at: 1731600000, day }), e, ctx);
  assert.equal(res.status, 200);
  assert.equal(e.DB.devices.size, 1);
  assert.equal(e.DB.dailyActive.size, 1);
  assert.ok(e.DB.dailyActive.has(`${day}:`.length > 0 ? [...e.DB.dailyActive][0] : ''));
});

test('上报当日聚合后，daily_stats 累加', async () => {
  const e = env();
  const day = todayStamp();
  const stats = { day, sessions: 3, duration_sec: 1800, vv: 12, crash: 1 };
  await worker.fetch(post({ id: UUID, ver: '2.3.0', day, stats }), e, ctx);
  const row = [...e.DB.dailyStats.values()][0];
  assert.equal(row.sessions, 3);
  assert.equal(row.duration_sec, 1800);
  assert.equal(row.vv, 12);
  assert.equal(row.crash, 1);
});

test('同一设备同一天重复上报被配额拦截，不再累加', async () => {
  const e = env();
  const day = todayStamp();
  const payload = { id: UUID, ver: '2.3.0', day, stats: { day, sessions: 1, duration_sec: 60, vv: 1, crash: 0 } };
  await worker.fetch(post(payload), e, ctx);
  const second = await worker.fetch(post(payload), e, ctx);
  const body = await second.json();
  assert.equal(body.counted, false);
  const row = [...e.DB.dailyStats.values()][0];
  assert.equal(row.sessions, 1);
});

test('非法 day 与超大计数被裁剪/拒绝', async () => {
  const e = env();
  // day 不是 YYYYMMDD → 400
  assert.equal((await worker.fetch(post({ id: UUID, ver: '2.3.0', day: 123 }), e, ctx)).status, 400);
  // 超大计数被裁剪到 MAX_COUNTER，不报错
  const day = todayStamp();
  const res = await worker.fetch(
    post({ id: UUID, ver: '2.3.0', day, stats: { day, sessions: 9e12, duration_sec: -5, vv: 1, crash: 0 } }), e, ctx);
  assert.equal(res.status, 200);
  const row = [...e.DB.dailyStats.values()][0];
  assert.equal(row.sessions, 1000000);
  assert.equal(row.duration_sec, 0);
});

test('parseStats 对无效输入返回 null', () => {
  assert.equal(parseStats(null), null);
  assert.equal(parseStats({}), null);
  assert.equal(parseStats({ day: 123 }), null);
  const ok = parseStats({ day: 20261113, sessions: 2, duration_sec: 100, vv: 5, crash: 0 });
  assert.equal(ok.day, 20261113);
  assert.equal(ok.sessions, 2);
});

test('dayStamp 生成 YYYYMMDD', () => {
  assert.match(String(dayStamp(1731600000)), /^20[0-9]{6}$/);
});

test('/stats 返回 daily 数组与 totals', async () => {
  const e = env();
  const day = todayStamp();
  await worker.fetch(
    post({ id: UUID, ver: '2.3.0', day, stats: { day, sessions: 2, duration_sec: 600, vv: 4, crash: 0 } }), e, ctx);
  const res = await worker.fetch(new Request('https://w/stats?key=k'), e, ctx);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.devices_total, 1);
  assert.ok(Array.isArray(body.daily));
  assert.equal(body.daily.length, 1);
  assert.equal(body.daily[0].devices, 1);
  assert.equal(body.totals.sessions, 2);
  assert.equal(body.totals.vv, 4);
  assert.equal(body.avg_duration_sec_per_session, 300);
});

test('toSafeInt：缺省值走 fallback，不传 0', () => {
  assert.equal(toSafeInt(null, 30, 1, 90), 30);
  assert.equal(toSafeInt(undefined, 30, 1, 90), 30);
  assert.equal(toSafeInt('', 30, 1, 90), 30);
  assert.equal(toSafeInt('0', 30, 1, 90), 1);
  assert.equal(toSafeInt('7', 30, 1, 90), 7);
  assert.equal(toSafeInt('abc', 30, 1, 90), 30);
  assert.equal(toSafeInt(999, 30, 1, 90), 90);
});

/* ── 新增：启动耗时 / 播放失败 / 超分 / 画质 / 完播 / 页面 ── */

test('扩展指标写入并聚合', async () => {
  const e = env();
  const day = todayStamp();
  const stats = {
    day, sessions: 1, duration_sec: 600, vv: 10, crash: 0,
    startup_p50_ms: 500, startup_p90_ms: 1200, startup_ms_sum: 5000, startup_ms_count: 5,
    play_fail: 2, fail_network: 1, fail_auth: 1, fail_notfound: 0, fail_server: 0, fail_other: 0,
    sr_on: 1, sr_supported: 1, quality_hd: 7, quality_sd: 3, play_complete: 6,
    page_home: 5, page_search: 2, page_category: 1, page_profile: 1, page_player: 10,
  };
  const res = await worker.fetch(post({ id: UUID, ver: '2.3.0', day, stats }), e, ctx);
  assert.equal(res.status, 200);

  const row = [...e.DB.dailyStats.values()][0];
  assert.equal(row.startup_p50_ms, 500);
  assert.equal(row.play_fail, 2);
  assert.equal(row.sr_on, 1);
  assert.equal(row.quality_hd, 7);
  assert.equal(row.play_complete, 6);
  assert.equal(row.page_player, 10);

  const sres = await worker.fetch(new Request('https://w/stats?key=k'), e, ctx);
  const body = await sres.json();
  assert.equal(body.startup.avg_ms, 1000);
  assert.equal(body.startup.avg_p50_ms, 500);
  assert.equal(body.playback.vv, 10);
  assert.equal(body.playback.play_fail, 2);
  assert.equal(body.playback.fail_breakdown.network, 1);
  assert.equal(body.playback.fail_breakdown.auth, 1);
  assert.equal(body.playback.play_complete_rate, 60);
  assert.equal(body.quality.hd, 7);
  assert.equal(body.quality.sd, 3);
  assert.equal(body.quality.hd_ratio, 70);
  assert.equal(body.quality.sr_support_rate, 100);
  assert.equal(body.pages.home, 5);
  assert.equal(body.pages.player, 10);
});

test('扩展指标缺省时安全为 0', async () => {
  const e = env();
  const day = todayStamp();
  await worker.fetch(post({ id: UUID, ver: '2.3.0', day, stats: { day, sessions: 1 } }), e, ctx);
  const sres = await worker.fetch(new Request('https://w/stats?key=k'), e, ctx);
  const body = await sres.json();
  assert.equal(body.startup.avg_ms, 0);
  assert.equal(body.playback.play_fail, 0);
  assert.equal(body.quality.hd_ratio, 0);
  assert.equal(body.pages.home, 0);
});

test('扩展指标超上限被裁剪', async () => {
  const e = env();
  const day = todayStamp();
  await worker.fetch(post({
    id: UUID, ver: '2.3.0', day,
    stats: { day, sessions: 1, startup_p50_ms: 9e9, play_fail: 9e12, page_home: -5 },
  }), e, ctx);
  const row = [...e.DB.dailyStats.values()][0];
  assert.equal(row.startup_p50_ms, 600000);
  assert.equal(row.play_fail, 1000000);
  assert.equal(row.page_home, 0);
});

/* ── 可视化面板：Cookie 鉴权 ───────────────────────── */

async function dashCookie(env) {
  const enc = new TextEncoder();
  const k = await crypto.subtle.importKey('raw', enc.encode(env.STATS_KEY), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = await crypto.subtle.sign('HMAC', k, enc.encode('hghub-dashboard-v1'));
  return [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

test('面板：无凭证返回登录页 401', async () => {
  const e = env();
  const res = await worker.fetch(new Request('https://w/dashboard'), e, ctx);
  assert.equal(res.status, 401);
  const body = await res.text();
  assert.ok(body.includes('访问口令'));
  assert.ok(body.includes('<form'));
});

test('面板：错误口令返回 401', async () => {
  const e = env();
  const res = await worker.fetch(new Request('https://w/dashboard?key=wrong'), e, ctx);
  assert.equal(res.status, 401);
  assert.ok((await res.text()).includes('口令不正确'));
});

test('面板：正确口令种 cookie 并 302 到 /dashboard', async () => {
  const e = env();
  const res = await worker.fetch(new Request('https://w/dashboard?key=k'), e, ctx);
  assert.equal(res.status, 302);
  assert.equal(res.headers.get('location'), '/dashboard');
  const cookie = res.headers.get('set-cookie') || '';
  assert.ok(cookie.startsWith('hg_dash='));
  assert.ok(cookie.includes('HttpOnly'));
  assert.ok(cookie.includes('Secure'));
  assert.ok(cookie.includes('SameSite=Strict'));
  // 180 天 = 15552000 秒
  assert.ok(cookie.includes('Max-Age=15552000'), cookie);
});

test('面板：带有效 cookie 返回 HTML', async () => {
  const e = env();
  const value = await dashCookie(e);
  const res = await worker.fetch(
    new Request('https://w/dashboard', { headers: { cookie: `hg_dash=${value}` } }), e, ctx);
  assert.equal(res.status, 200);
  assert.ok((res.headers.get('content-type') || '').includes('text/html'));
  assert.equal(res.headers.get('x-frame-options'), 'DENY');
  const body = await res.text();
  assert.ok(body.includes('Telemetry'));
  assert.ok(body.includes('/api/stats'));
});

test('面板：伪造 cookie 被拒', async () => {
  const e = env();
  const res = await worker.fetch(
    new Request('https://w/dashboard', { headers: { cookie: 'hg_dash=deadbeef' } }), e, ctx);
  assert.equal(res.status, 401);
});

test('面板：未配置 STATS_KEY 时返回 503', async () => {
  const e = env({ STATS_KEY: '' });
  const res = await worker.fetch(new Request('https://w/dashboard'), e, ctx);
  assert.equal(res.status, 503);
});

test('/api/stats：无凭证 401，带 cookie 200', async () => {
  const e = env();
  const no = await worker.fetch(new Request('https://w/api/stats?days=7'), e, ctx);
  assert.equal(no.status, 401);

  const value = await dashCookie(e);
  const ok = await worker.fetch(
    new Request('https://w/api/stats?days=7', { headers: { cookie: `hg_dash=${value}` } }), e, ctx);
  assert.equal(ok.status, 200);
  const body = await ok.json();
  assert.equal(body.window_days, 7);
  assert.ok(Array.isArray(body.daily));
});

test('/api/stats：也接受 ?key=', async () => {
  const e = env();
  const res = await worker.fetch(new Request('https://w/api/stats?key=k&days=30'), e, ctx);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).window_days, 30);
});

/* ── 崩溃堆栈聚合 ──────────────────────────────────── */

function crashPost(body, headers = {}) {
  return new Request('https://w/v1/crash', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

const STACK_A = 'TypeError: undefined is not a function\n    at foo (entry/src/main/ets/pages/A.ets:12:5)\n    at bar (entry/src/main/ets/pages/B.ets:34:9)';
const STACK_B = 'RangeError: invalid array length\n    at baz (entry/src/main/ets/pages/C.ets:7:1)';

test('崩溃上报：首次写入一个分组', async () => {
  const e = env();
  const res = await worker.fetch(crashPost({
    id: UUID, ver: '2.3.0', model: 'ALN-AL00', os: 'HarmonyOS 7.0',
    crashes: [{ type: 'app_crash', reason: 'TypeError', message: 'boom', stack: STACK_A, thread: 'main', at: 1731600000 }],
  }), e, ctx);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.accepted, 1);
  assert.equal(e.DB.crashGroups.size, 1);
  assert.equal(e.DB.crashVersions.size, 1);
});

test('崩溃上报：同一堆栈聚合到同一分组，count 累加', async () => {
  const e = env();
  const payload = {
    id: UUID, ver: '2.3.0',
    crashes: [{ type: 'app_crash', reason: 'TypeError', message: 'boom', stack: STACK_A, thread: 'main', at: 1 }],
  };
  await worker.fetch(crashPost(payload), e, ctx);
  await worker.fetch(crashPost(payload), e, ctx);
  await worker.fetch(crashPost(payload), e, ctx);
  assert.equal(e.DB.crashGroups.size, 1);
  const g = [...e.DB.crashGroups.values()][0];
  assert.equal(g.count, 3);
});

test('崩溃上报：不同堆栈分成不同分组', async () => {
  const e = env();
  await worker.fetch(crashPost({
    id: UUID, ver: '2.3.0',
    crashes: [
      { type: 'app_crash', reason: 'TypeError', stack: STACK_A, at: 1 },
      { type: 'app_crash', reason: 'RangeError', stack: STACK_B, at: 2 },
    ],
  }), e, ctx);
  assert.equal(e.DB.crashGroups.size, 2);
});

test('崩溃上报：无堆栈时按 type+reason+message 归组', async () => {
  const e = env();
  const payload = {
    id: UUID, ver: '2.3.0',
    crashes: [{ type: 'app_freeze', reason: 'THREAD_BLOCK_6S', message: 'main thread blocked', at: 1 }],
  };
  await worker.fetch(crashPost(payload), e, ctx);
  await worker.fetch(crashPost(payload), e, ctx);
  assert.equal(e.DB.crashGroups.size, 1);
  assert.equal([...e.DB.crashGroups.values()][0].count, 2);
});

test('崩溃上报：非法 id / 版本 / 空批次被拒', async () => {
  const e = env();
  assert.equal((await worker.fetch(crashPost({ id: 'bad', ver: '2.3.0', crashes: [{ type: 'x' }] }), e, ctx)).status, 400);
  assert.equal((await worker.fetch(crashPost({ id: UUID, ver: 'x', crashes: [{ type: 'x' }] }), e, ctx)).status, 400);
  assert.equal((await worker.fetch(crashPost({ id: UUID, ver: '2.3.0', crashes: [] }), e, ctx)).status, 400);
  assert.equal((await worker.fetch(crashPost({ id: UUID, ver: '2.3.0' }), e, ctx)).status, 400);
});

test('崩溃上报：超大请求体被拒', async () => {
  const e = env();
  const big = JSON.stringify({
    id: UUID, ver: '2.3.0',
    crashes: [{ type: 'x', stack: 'A'.repeat(40000) }],
  });
  const res = await worker.fetch(crashPost(big), e, ctx);
  assert.equal(res.status, 413);
});

test('/stats 返回崩溃聚合', async () => {
  const e = env();
  await worker.fetch(crashPost({
    id: UUID, ver: '2.3.0',
    crashes: [
      { type: 'app_crash', reason: 'TypeError', stack: STACK_A, at: 1 },
      { type: 'app_crash', reason: 'TypeError', stack: STACK_A, at: 2 },
      { type: 'app_crash', reason: 'RangeError', stack: STACK_B, at: 3 },
    ],
  }), e, ctx);
  const res = await worker.fetch(new Request('https://w/stats?key=k'), e, ctx);
  const body = await res.json();
  assert.equal(body.crash.total, 3);
  assert.equal(body.crash.groups.length, 2);
  assert.equal(body.crash.groups[0].count, 2);
  assert.ok(Array.isArray(body.crash.groups[0].versions));
  assert.equal(body.crash.groups[0].versions[0].version, '2.3.0');
});

/* ── 设备侧指标（内存/磁盘/功耗）与线路指标 ────────── */

test('设备与线路指标写入并聚合', async () => {
  const e = env();
  const day = todayStamp();
  const stats = {
    day, sessions: 1, duration_sec: 600, vv: 5, crash: 0,
    mem_pss_kb: 180000, mem_peak_kb: 240000, mem_vss_kb: 900000,
    disk_app_bytes: 52000000, disk_cache_bytes: 12000000, disk_data_bytes: 3000000,
    soc_start: 80, soc_end: 76, temp_max_c: 36.5, charging: 0,
    line_primary_ok: 40, line_primary_fail: 2,
    line_mirror_ok: 10, line_mirror_fail: 1,
    line_switches: 1,
    line_latency_avg_ms: 120, line_latency_p90_ms: 260,
  };
  const res = await worker.fetch(post({ id: UUID, ver: '2.3.0', day, stats }), e, ctx);
  assert.equal(res.status, 200);

  const row = [...e.DB.dailyStats.values()][0];
  assert.equal(row.mem_pss_kb, 180000);
  assert.equal(row.disk_app_bytes, 52000000);
  assert.equal(row.soc_start, 80);
  assert.equal(row.temp_max_c, 36.5);
  assert.equal(row.line_primary_ok, 40);

  const sres = await worker.fetch(new Request('https://w/stats?key=k'), e, ctx);
  const body = await sres.json();

  assert.equal(body.device.mem_pss_avg_kb, 180000);
  assert.equal(body.device.mem_peak_kb, 240000);
  assert.equal(body.device.disk_app_avg_bytes, 52000000);
  assert.equal(body.device.soc_drain_avg_pct, 4);
  assert.equal(body.device.soc_drain_samples, 1);
  assert.equal(body.device.temp_max_c, 36.5);

  assert.equal(body.lines.primary_ok, 40);
  assert.equal(body.lines.primary_fail, 2);
  assert.equal(body.lines.primary_fail_rate, 4.8);
  assert.equal(body.lines.mirror_ok, 10);
  assert.equal(body.lines.switches, 1);
  assert.equal(body.lines.latency_avg_ms, 120);
  assert.equal(body.lines.latency_p90_ms, 260);
});

test('充电中的会话不计入耗电统计', async () => {
  const e = env();
  const day = todayStamp();
  await worker.fetch(post({
    id: UUID, ver: '2.3.0', day,
    stats: { day, sessions: 1, soc_start: 50, soc_end: 62, charging: 1 },
  }), e, ctx);
  const sres = await worker.fetch(new Request('https://w/stats?key=k'), e, ctx);
  const body = await sres.json();
  assert.equal(body.device.soc_drain_samples, 0);
  assert.equal(body.device.soc_drain_avg_pct, 0);
});

test('设备指标缺省时安全为 0', async () => {
  const e = env();
  const day = todayStamp();
  await worker.fetch(post({ id: UUID, ver: '2.3.0', day, stats: { day, sessions: 1 } }), e, ctx);
  const sres = await worker.fetch(new Request('https://w/stats?key=k'), e, ctx);
  const body = await sres.json();
  assert.equal(body.device.mem_pss_avg_kb, 0);
  assert.equal(body.device.disk_app_avg_bytes, 0);
  assert.equal(body.lines.primary_ok, 0);
  assert.equal(body.lines.latency_avg_ms, 0);
});

test('设备指标超上限被裁剪', async () => {
  const e = env();
  const day = todayStamp();
  await worker.fetch(post({
    id: UUID, ver: '2.3.0', day,
    stats: { day, sessions: 1, mem_pss_kb: 9e12, soc_start: 999, temp_max_c: -5 },
  }), e, ctx);
  const row = [...e.DB.dailyStats.values()][0];
  assert.equal(row.mem_pss_kb, 16 * 1024 * 1024);
  assert.equal(row.soc_start, 100);
  assert.equal(row.temp_max_c, 0);
});

/* ── 功耗与性能指标（CPU / 热等级 / 瞬时功率）────────── */

test('CPU / 热等级 / 功率写入并聚合', async () => {
  const e = env();
  const day = todayStamp();
  const stats = {
    day, sessions: 1,
    cpu_pct: 18, cpu_peak_pct: 42,
    thermal_level: 3, power_mw: 1850,
  };
  const res = await worker.fetch(post({ id: UUID, ver: '2.3.0', day, stats }), e, ctx);
  assert.equal(res.status, 200);

  const row = [...e.DB.dailyStats.values()][0];
  assert.equal(row.cpu_pct, 18);
  assert.equal(row.cpu_peak_pct, 42);
  assert.equal(row.thermal_level, 3);
  assert.equal(row.power_mw, 1850);

  const sres = await worker.fetch(new Request('https://w/stats?key=k'), e, ctx);
  const body = await sres.json();
  assert.equal(body.device.cpu_avg_pct, 18);
  assert.equal(body.device.cpu_peak_pct, 42);
  assert.equal(body.device.thermal_max, 3);
  assert.equal(body.device.power_mw_avg, 1850);
});

test('CPU / 热等级 / 功率超范围被裁剪', async () => {
  const e = env();
  const day = todayStamp();
  await worker.fetch(post({
    id: UUID, ver: '2.3.0', day,
    stats: { day, sessions: 1, cpu_pct: 999, thermal_level: 99, power_mw: 9e9 },
  }), e, ctx);
  const row = [...e.DB.dailyStats.values()][0];
  assert.equal(row.cpu_pct, 100);
  assert.equal(row.thermal_level, 7);
  assert.equal(row.power_mw, 100000);
});

test('CPU / 热等级 / 功率缺省为 0', async () => {
  const e = env();
  const day = todayStamp();
  await worker.fetch(post({ id: UUID, ver: '2.3.0', day, stats: { day, sessions: 1 } }), e, ctx);
  const sres = await worker.fetch(new Request('https://w/stats?key=k'), e, ctx);
  const body = await sres.json();
  assert.equal(body.device.cpu_avg_pct, 0);
  assert.equal(body.device.thermal_max, 0);
  assert.equal(body.device.power_mw_avg, 0);
});

/* ── 用户行为计数 ──────────────────────────────────── */

test('行为计数写入并聚合', async () => {
  const e = env();
  const day = todayStamp();
  const stats = {
    day, sessions: 1,
    act_share: 3, act_like: 12, act_unlike: 2, act_fav: 5, act_unfav: 1,
    act_search: 8, act_ep_switch: 20, act_rate: 4, act_cast: 1, act_pip: 2,
    act_comment: 1, act_follow: 2, act_topic: 3, act_user: 4,
  };
  const res = await worker.fetch(post({ id: UUID, ver: '2.3.0', day, stats }), e, ctx);
  assert.equal(res.status, 200);

  const row = [...e.DB.dailyStats.values()][0];
  assert.equal(row.act_share, 3);
  assert.equal(row.act_search, 8);
  assert.equal(row.act_ep_switch, 20);

  const sres = await worker.fetch(new Request('https://w/stats?key=k'), e, ctx);
  const body = await sres.json();
  assert.equal(body.actions.share, 3);
  assert.equal(body.actions.like, 12);
  assert.equal(body.actions.search, 8);
  assert.equal(body.actions.ep_switch, 20);
  assert.equal(body.actions.topic, 3);
  assert.equal(body.actions.user, 4);
});

test('行为计数缺省为 0', async () => {
  const e = env();
  const day = todayStamp();
  await worker.fetch(post({ id: UUID, ver: '2.3.0', day, stats: { day, sessions: 1 } }), e, ctx);
  const sres = await worker.fetch(new Request('https://w/stats?key=k'), e, ctx);
  const body = await sres.json();
  assert.equal(body.actions.share, 0);
  assert.equal(body.actions.search, 0);
  assert.equal(body.actions.ep_switch, 0);
});

test('行为计数超上限被裁剪', async () => {
  const e = env();
  const day = todayStamp();
  await worker.fetch(post({
    id: UUID, ver: '2.3.0', day,
    stats: { day, sessions: 1, act_share: 9e12, act_search: -5 },
  }), e, ctx);
  const row = [...e.DB.dailyStats.values()][0];
  assert.equal(row.act_share, 1000000);
  assert.equal(row.act_search, 0);
});

/* ── 远程配置下发（/v1/config）────────────────────── */

const CONFIG_KEY = 'test-config-signing-key-0123456789abcdef';

/** 带签名密钥的环境（STATS_KEY 沿用 env() 的 'k'）。 */
function configEnv(extra = {}) {
  return env({ CONFIG_SIGNING_KEY: CONFIG_KEY, ...extra });
}

/** 直接向 mock D1 写入一条配置（等价于一次成功的 POST /admin/config）。 */
function seedConfig(db, version, payload, updatedAt = 1731600000,
  configId = '0f8fad5b-d9cb-469f-a165-70867728950e') {
  db.remoteConfig.set('global', {
    id: 'global',
    version,
    payload: JSON.stringify({ config_version: version, issued_at: updatedAt, ...payload }),
    updated_at: updatedAt,
    config_id: configId,
  });
}

const CONFIG_PAYLOAD = {
  min_client_ver: '2.0.0',
  flags: { super_resolution: true, inplace_search: false },
  thresholds: { retry_max: 4, sr_battery_min: 20 },
  rollout: { inplace_search: 20 },
  ab: { search_page_size: { A: 20, B: 30 } },
  copy: {},
  assets: {},
};

function configGet(query = '') {
  return new Request(`https://w/v1/config?${query}`);
}

function adminPost(body, headers = {}) {
  return new Request('https://w/admin/config', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

test('/v1/config：返回 payload 字段 + config_version + sig', async () => {
  const e = configEnv();
  seedConfig(e.DB, 12, CONFIG_PAYLOAD);
  const res = await worker.fetch(configGet('ver=2.3.0&bucket=37&platform=harmonyos&cfg=11'), e, ctx);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'public, max-age=300');
  assert.equal(res.headers.get('access-control-allow-origin'), '*');
  const body = await res.json();
  assert.equal(body.config_version, 12);
  assert.equal(body.issued_at, 1731600000);
  assert.equal(body.min_client_ver, '2.0.0');
  assert.equal(body.flags.super_resolution, true);
  assert.equal(body.flags.inplace_search, false);
  assert.equal(body.thresholds.retry_max, 4);
  assert.equal(body.rollout.inplace_search, 20);
  assert.equal(body.ab.search_page_size.B, 30);
  assert.match(body.sig, /^[0-9a-f]{32}$/);
});

test('/v1/config：cfg 与服务端版本相同返回 304 空 body', async () => {
  const e = configEnv();
  seedConfig(e.DB, 12, CONFIG_PAYLOAD);
  const res = await worker.fetch(configGet('cfg=12'), e, ctx);
  assert.equal(res.status, 304);
  assert.equal(await res.text(), '');
  assert.equal(res.headers.get('cache-control'), 'public, max-age=300');
});

test('/v1/config：sig 是 body_without_sig 的 HMAC-SHA256 前 32 hex', async () => {
  const e = configEnv();
  seedConfig(e.DB, 12, CONFIG_PAYLOAD);
  const body = await (await worker.fetch(configGet('cfg=0'), e, ctx)).json();
  const unsigned = { ...body };
  delete unsigned.sig;
  const expected = (await hmacSha256Hex(CONFIG_KEY, JSON.stringify(unsigned))).slice(0, 32);
  assert.equal(body.sig, expected);
});

test('/v1/config：payload 被篡改后原签名不再匹配', async () => {
  const e = configEnv();
  seedConfig(e.DB, 12, CONFIG_PAYLOAD);
  const body = await (await worker.fetch(configGet(), e, ctx)).json();
  const tampered = { ...body, flags: { ...body.flags, inplace_search: true } };
  delete tampered.sig;
  const tamperedSig = (await hmacSha256Hex(CONFIG_KEY, JSON.stringify(tampered))).slice(0, 32);
  assert.notEqual(tamperedSig, body.sig);
});

test('/v1/config：存储的 payload 超过 16 KB 返回 500', async () => {
  const e = configEnv();
  seedConfig(e.DB, 12, { copy: { big: 'A'.repeat(17000) } });
  const res = await worker.fetch(configGet(), e, ctx);
  assert.equal(res.status, 500);
  assert.equal((await res.json()).error, 'config_too_large');
});

test('/v1/config：未配置 CONFIG_SIGNING_KEY 返回 503', async () => {
  const e = env();
  seedConfig(e.DB, 12, CONFIG_PAYLOAD);
  const res = await worker.fetch(configGet(), e, ctx);
  assert.equal(res.status, 503);
  assert.equal((await res.json()).error, 'config_unavailable');
});

test('/v1/config：未发布配置返回 404', async () => {
  const e = configEnv();
  const res = await worker.fetch(configGet(), e, ctx);
  assert.equal(res.status, 404);
  assert.equal((await res.json()).error, 'config_not_found');
});

test('/v1/config：D1 故障返回 500', async () => {
  const e = configEnv();
  e.DB = { prepare() { throw new Error('d1 down'); } };
  const res = await worker.fetch(configGet(), e, ctx);
  assert.equal(res.status, 500);
  assert.equal((await res.json()).error, 'storage_failed');
});

test('/admin/config：鉴权通过后写入并可被 /v1/config 读取', async () => {
  const e = configEnv();
  const res = await worker.fetch(adminPost(
    { version: 12, payload: { flags: { pip: true }, thresholds: { retry_max: 5 } } },
    { 'x-admin-key': 'k' }), e, ctx);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('cache-control'), 'no-store');
  const body = await res.json();
  assert.equal(body.ok, true);
  assert.equal(body.version, 12);
  assert.equal(e.DB.remoteConfig.get('global').version, 12);

  const got = await worker.fetch(configGet('cfg=11'), e, ctx);
  assert.equal(got.status, 200);
  const cfg = await got.json();
  assert.equal(cfg.config_version, 12);
  assert.equal(cfg.flags.pip, true);
  assert.equal(cfg.thresholds.retry_max, 5);
  // issued_at 由服务端注入，与 DB 的 updated_at 一致
  assert.equal(cfg.issued_at, e.DB.remoteConfig.get('global').updated_at);
});

test('/admin/config：缺少或错误 x-admin-key 返回 401，未配置 STATS_KEY 返回 503', async () => {
  const e = configEnv();
  assert.equal((await worker.fetch(adminPost({ version: 1, payload: {} }), e, ctx)).status, 401);
  assert.equal((await worker.fetch(
    adminPost({ version: 1, payload: {} }, { 'x-admin-key': 'wrong' }), e, ctx)).status, 401);

  const noKey = configEnv({ STATS_KEY: '' });
  assert.equal((await worker.fetch(
    adminPost({ version: 1, payload: {} }, { 'x-admin-key': '' }), noKey, ctx)).status, 503);
});

test('/admin/config：version 必须严格递增，否则 409', async () => {
  const e = configEnv();
  const h = { 'x-admin-key': 'k' };
  assert.equal((await worker.fetch(adminPost({ version: 12, payload: { flags: { pip: true } } }, h), e, ctx)).status, 200);
  assert.equal((await worker.fetch(adminPost({ version: 12, payload: { flags: { pip: false } } }, h), e, ctx)).status, 409);
  assert.equal((await worker.fetch(adminPost({ version: 11, payload: {} }, h), e, ctx)).status, 409);
  assert.equal((await worker.fetch(adminPost({ version: 13, payload: { flags: { pip: false } } }, h), e, ctx)).status, 200);
  assert.equal(e.DB.remoteConfig.get('global').version, 13);
});

test('/admin/config：非法版本 / payload 被拒', async () => {
  const e = configEnv();
  const h = { 'x-admin-key': 'k' };
  assert.equal((await worker.fetch(adminPost({ version: 0, payload: {} }, h), e, ctx)).status, 400);
  assert.equal((await worker.fetch(adminPost({ version: 1.5, payload: {} }, h), e, ctx)).status, 400);
  assert.equal((await worker.fetch(adminPost({ version: '12', payload: {} }, h), e, ctx)).status, 400);
  assert.equal((await worker.fetch(adminPost({ version: 12, payload: [] }, h), e, ctx)).status, 400);
  assert.equal((await worker.fetch(adminPost({ version: 12 }, h), e, ctx)).status, 400);
  assert.equal((await worker.fetch(adminPost('{bad', h), e, ctx)).status, 400);
});

test('/admin/config：payload 超过 16 KB 被拒 413', async () => {
  const e = configEnv();
  const res = await worker.fetch(adminPost(
    { version: 12, payload: { copy: { big: 'A'.repeat(17000) } } },
    { 'x-admin-key': 'k' }), e, ctx);
  assert.equal(res.status, 413);
  assert.equal(e.DB.remoteConfig.size, 0);
});

test('/admin/config：payload 里的 config_version / issued_at / sig 被服务端权威值覆盖', async () => {
  const e = configEnv();
  await worker.fetch(adminPost({
    version: 12,
    payload: { config_version: 99, issued_at: 1, sig: 'deadbeef', flags: { pip: true } },
  }, { 'x-admin-key': 'k' }), e, ctx);
  const cfg = await (await worker.fetch(configGet('cfg=0'), e, ctx)).json();
  assert.equal(cfg.config_version, 12);
  assert.notEqual(cfg.issued_at, 1);
  assert.match(cfg.sig, /^[0-9a-f]{32}$/);
  assert.notEqual(cfg.sig, 'deadbeef');
});

/* ── 配置唯一 ID（config_id / SPEC §16）────────────── */

const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

test('/v1/config：下发 config_id（与 D1 中最新一条一致）', async () => {
  const e = configEnv();
  seedConfig(e.DB, 12, CONFIG_PAYLOAD, 1731600000, '5f0c2a11-7d4e-4a3b-9c8d-1e2f3a4b5c6d');
  const body = await (await worker.fetch(configGet('cfg=11'), e, ctx)).json();
  assert.equal(body.config_id, '5f0c2a11-7d4e-4a3b-9c8d-1e2f3a4b5c6d');
});

test('/v1/config：旧库无 config_id 时下发空串（客户端按未下发处理）', async () => {
  const e = configEnv();
  seedConfig(e.DB, 12, CONFIG_PAYLOAD, 1731600000, '');
  const body = await (await worker.fetch(configGet(), e, ctx)).json();
  assert.equal(body.config_id, '');
});

test('/admin/config：每次发布生成合法且不重复的 config_id', async () => {
  const e = configEnv();
  const h = { 'x-admin-key': 'k' };
  const first = await (await worker.fetch(
    adminPost({ version: 12, payload: { flags: { pip: true } } }, h), e, ctx)).json();
  assert.equal(first.ok, true);
  assert.match(first.config_id, UUID_V4_RE);

  const second = await (await worker.fetch(
    adminPost({ version: 13, payload: { flags: { pip: false } } }, h), e, ctx)).json();
  assert.match(second.config_id, UUID_V4_RE);
  assert.notEqual(second.config_id, first.config_id);
  assert.equal(e.DB.remoteConfig.get('global').config_id, second.config_id);

  // 下发的是最新一次的 config_id。
  const cfg = await (await worker.fetch(configGet('cfg=12'), e, ctx)).json();
  assert.equal(cfg.config_id, second.config_id);
});

test('/admin/config：同 version 重发 409 且 config_id 不变', async () => {
  const e = configEnv();
  const h = { 'x-admin-key': 'k' };
  const first = await (await worker.fetch(
    adminPost({ version: 12, payload: { flags: { pip: true } } }, h), e, ctx)).json();
  const conflict = await worker.fetch(
    adminPost({ version: 12, payload: { flags: { pip: false } } }, h), e, ctx);
  assert.equal(conflict.status, 409);
  assert.equal(e.DB.remoteConfig.get('global').config_id, first.config_id);
  const cfg = await (await worker.fetch(configGet('cfg=0'), e, ctx)).json();
  assert.equal(cfg.config_id, first.config_id);
  assert.equal(cfg.flags.pip, true);
});

test('/v1/config：config_id 参与签名，篡改后签名不再匹配', async () => {
  const e = configEnv();
  seedConfig(e.DB, 12, CONFIG_PAYLOAD);
  const body = await (await worker.fetch(configGet(), e, ctx)).json();
  const unsigned = { ...body };
  delete unsigned.sig;
  const expected = (await hmacSha256Hex(CONFIG_KEY, JSON.stringify(unsigned))).slice(0, 32);
  assert.equal(body.sig, expected);

  const tampered = { ...unsigned, config_id: 'ffffffff-ffff-4fff-8fff-ffffffffffff' };
  const tamperedSig = (await hmacSha256Hex(CONFIG_KEY, JSON.stringify(tampered))).slice(0, 32);
  assert.notEqual(tamperedSig, body.sig);
});
