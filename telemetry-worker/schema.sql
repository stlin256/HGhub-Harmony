-- HGhub Harmony 匿名设备计数（D1）
--
-- 隐私设计：
--   * 只存设备匿名 ID 的 SHA-256（id_hash），原始 UUID 永不落库；
--   * 不存 IP：rate_limits 里只存 IP 的 SHA-256 与时间窗，用于限流；
--   * 不存任何硬件标识（OAID / IMEI / SN / MAC）、账号、播放内容、行为轨迹。

CREATE TABLE IF NOT EXISTS devices (
  id_hash          TEXT PRIMARY KEY,
  version          TEXT NOT NULL,
  model            TEXT,
  os               TEXT,
  first_seen_epoch INTEGER NOT NULL,
  last_seen_epoch  INTEGER NOT NULL,
  report_count     INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_devices_first_seen ON devices(first_seen_epoch);
CREATE INDEX IF NOT EXISTS idx_devices_last_seen  ON devices(last_seen_epoch);
CREATE INDEX IF NOT EXISTS idx_devices_version    ON devices(version);

-- 限流桶：bucket = 'ip:<sha256(ip+salt)>:<小时>' 或 'dev:<id_hash>:<天>'
CREATE TABLE IF NOT EXISTS rate_limits (
  bucket     TEXT PRIMARY KEY,
  count      INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_rate_limits_expires ON rate_limits(expires_at);
