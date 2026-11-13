-- 0004：崩溃堆栈聚合
--
-- 按「堆栈指纹」聚合：同一处崩溃在不同设备/不同构建路径下归到同一行。
-- 客户端只上报规范化后的堆栈（已去掉绝对路径、行号、内存地址）。

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
