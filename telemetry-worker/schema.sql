-- HGhub Harmony 匿名统计（D1）
--
-- 隐私设计：
--   * 只存设备匿名 ID 的 SHA-256（id_hash），原始 UUID 永不落库；
--   * 不存 IP：rate_limits 里只存 IP 的 SHA-256 与时间窗，用于限流；
--   * 不存任何硬件标识（OAID / IMEI / SN / MAC）、账号、播放内容、行为轨迹。
--
-- 三张表：
--   devices      每台设备一行（安装数口径 = COUNT(*)）
--   daily_active 每台设备每天一行（DAU 口径）
--   daily_stats  每台设备每天的聚合指标（VV / 时长 / 启动次数 / 崩溃数）

CREATE TABLE IF NOT EXISTS devices (
  id_hash          TEXT PRIMARY KEY,
  first_version    TEXT,
  version          TEXT NOT NULL,
  model            TEXT,
  os               TEXT,
  install_epoch    INTEGER,
  first_seen_epoch INTEGER NOT NULL,
  last_seen_epoch  INTEGER NOT NULL,
  report_count     INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_devices_first_seen ON devices(first_seen_epoch);
CREATE INDEX IF NOT EXISTS idx_devices_last_seen  ON devices(last_seen_epoch);
CREATE INDEX IF NOT EXISTS idx_devices_version    ON devices(version);

CREATE TABLE IF NOT EXISTS daily_active (
  day      INTEGER NOT NULL,
  id_hash  TEXT NOT NULL,
  PRIMARY KEY (day, id_hash)
);

CREATE INDEX IF NOT EXISTS idx_daily_active_day ON daily_active(day);

CREATE TABLE IF NOT EXISTS daily_stats (
  day          INTEGER NOT NULL,
  id_hash      TEXT NOT NULL,
  -- 基础
  sessions     INTEGER NOT NULL DEFAULT 0,
  duration_sec INTEGER NOT NULL DEFAULT 0,
  vv           INTEGER NOT NULL DEFAULT 0,
  crash        INTEGER NOT NULL DEFAULT 0,
  -- 启动耗时（设备内 p50/p90 + 均值用 sum/count）
  startup_p50_ms   INTEGER NOT NULL DEFAULT 0,
  startup_p90_ms   INTEGER NOT NULL DEFAULT 0,
  startup_ms_sum   INTEGER NOT NULL DEFAULT 0,
  startup_ms_count INTEGER NOT NULL DEFAULT 0,
  -- 播放失败（总数 + 分桶）
  play_fail     INTEGER NOT NULL DEFAULT 0,
  fail_network  INTEGER NOT NULL DEFAULT 0,
  fail_auth     INTEGER NOT NULL DEFAULT 0,
  fail_notfound INTEGER NOT NULL DEFAULT 0,
  fail_server   INTEGER NOT NULL DEFAULT 0,
  fail_other    INTEGER NOT NULL DEFAULT 0,
  -- 超分 / 画质 / 完播
  sr_on          INTEGER NOT NULL DEFAULT 0,
  sr_supported   INTEGER NOT NULL DEFAULT 0,
  quality_hd     INTEGER NOT NULL DEFAULT 0,
  quality_sd     INTEGER NOT NULL DEFAULT 0,
  play_complete  INTEGER NOT NULL DEFAULT 0,
  -- 页面访问分布
  page_home      INTEGER NOT NULL DEFAULT 0,
  page_search    INTEGER NOT NULL DEFAULT 0,
  page_category  INTEGER NOT NULL DEFAULT 0,
  page_profile   INTEGER NOT NULL DEFAULT 0,
  page_player    INTEGER NOT NULL DEFAULT 0,
  -- 设备侧指标（内存 / 磁盘 / 功耗）
  mem_pss_kb        INTEGER NOT NULL DEFAULT 0,
  mem_peak_kb       INTEGER NOT NULL DEFAULT 0,
  mem_vss_kb        INTEGER NOT NULL DEFAULT 0,
  disk_app_bytes    INTEGER NOT NULL DEFAULT 0,
  disk_cache_bytes  INTEGER NOT NULL DEFAULT 0,
  disk_data_bytes   INTEGER NOT NULL DEFAULT 0,
  soc_start         INTEGER NOT NULL DEFAULT 0,
  soc_end           INTEGER NOT NULL DEFAULT 0,
  temp_max_c        REAL    NOT NULL DEFAULT 0,
  charging          INTEGER NOT NULL DEFAULT 0,
  -- 线路指标（主站/镜像请求成败、换线次数、探测延迟）
  line_primary_ok   INTEGER NOT NULL DEFAULT 0,
  line_primary_fail INTEGER NOT NULL DEFAULT 0,
  line_mirror_ok    INTEGER NOT NULL DEFAULT 0,
  line_mirror_fail  INTEGER NOT NULL DEFAULT 0,
  line_switches     INTEGER NOT NULL DEFAULT 0,
  line_latency_avg_ms INTEGER NOT NULL DEFAULT 0,
  line_latency_p90_ms INTEGER NOT NULL DEFAULT 0,
  -- 功耗与性能
  cpu_pct        INTEGER NOT NULL DEFAULT 0,
  cpu_peak_pct   INTEGER NOT NULL DEFAULT 0,
  thermal_level  INTEGER NOT NULL DEFAULT 0,
  power_mw       INTEGER NOT NULL DEFAULT 0,
  -- 用户行为计数（只记次数，不记内容）
  act_share     INTEGER NOT NULL DEFAULT 0,
  act_like      INTEGER NOT NULL DEFAULT 0,
  act_unlike    INTEGER NOT NULL DEFAULT 0,
  act_fav       INTEGER NOT NULL DEFAULT 0,
  act_unfav     INTEGER NOT NULL DEFAULT 0,
  act_search    INTEGER NOT NULL DEFAULT 0,
  act_ep_switch INTEGER NOT NULL DEFAULT 0,
  act_rate      INTEGER NOT NULL DEFAULT 0,
  act_cast      INTEGER NOT NULL DEFAULT 0,
  act_pip       INTEGER NOT NULL DEFAULT 0,
  act_comment   INTEGER NOT NULL DEFAULT 0,
  act_follow    INTEGER NOT NULL DEFAULT 0,
  act_topic     INTEGER NOT NULL DEFAULT 0,
  act_user      INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, id_hash)
);

CREATE INDEX IF NOT EXISTS idx_daily_stats_day ON daily_stats(day);

-- 崩溃堆栈聚合（按指纹去重）
CREATE TABLE IF NOT EXISTS crash_groups (
  fingerprint      TEXT PRIMARY KEY,
  type             TEXT NOT NULL,
  reason           TEXT,
  message          TEXT,
  stack            TEXT,
  thread           TEXT,
  count            INTEGER NOT NULL DEFAULT 1,
  first_seen_epoch INTEGER NOT NULL,
  last_seen_epoch  INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_crash_groups_count     ON crash_groups(count);
CREATE INDEX IF NOT EXISTS idx_crash_groups_last_seen ON crash_groups(last_seen_epoch);

CREATE TABLE IF NOT EXISTS crash_versions (
  fingerprint TEXT NOT NULL,
  version     TEXT NOT NULL,
  count       INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (fingerprint, version)
);

-- 限流桶：bucket = 'ip:<sha256(ip+salt)>:<小时>' 或 'dev:<id_hash>:<天>'
CREATE TABLE IF NOT EXISTS rate_limits (
  bucket     TEXT PRIMARY KEY,
  count      INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_expires ON rate_limits(expires_at);

-- 远程配置下发（GET /v1/config）：单行配置，version 单调递增
CREATE TABLE IF NOT EXISTS remote_config (
  id TEXT PRIMARY KEY,
  version INTEGER NOT NULL,
  payload TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  -- 配置唯一 ID（C11 / SPEC §16）：每次发布生成，全局唯一、永不复用
  config_id TEXT NOT NULL DEFAULT ''
);

-- 配置应用回报（C10 / SPEC §15）：按 (config_id, key, old, new, source) 聚合计数，
-- 不存设备标识；count 是设备·天口径（每台设备每天只上报一次日聚合）
CREATE TABLE IF NOT EXISTS config_applies (
  config_id      TEXT NOT NULL,
  config_version INTEGER NOT NULL,
  key            TEXT NOT NULL,
  old_value      TEXT,
  new_value      TEXT,
  source         TEXT,
  count          INTEGER NOT NULL DEFAULT 1,
  first_at       INTEGER NOT NULL,
  last_at        INTEGER NOT NULL,
  PRIMARY KEY (config_id, key, old_value, new_value, source)
);

CREATE INDEX IF NOT EXISTS idx_config_applies_version ON config_applies(config_version);
CREATE INDEX IF NOT EXISTS idx_config_applies_last_at ON config_applies(last_at);
