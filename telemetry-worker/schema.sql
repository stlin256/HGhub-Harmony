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
  PRIMARY KEY (day, id_hash)
);

CREATE INDEX IF NOT EXISTS idx_daily_stats_day ON daily_stats(day);

-- 限流桶：bucket = 'ip:<sha256(ip+salt)>:<小时>' 或 'dev:<id_hash>:<天>'
CREATE TABLE IF NOT EXISTS rate_limits (
  bucket     TEXT PRIMARY KEY,
  count      INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_expires ON rate_limits(expires_at);
