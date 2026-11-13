-- 0002：从「只数安装」扩展到「安装 + DAU + VV + 时长」
--
-- 对已部署的 v1 库做增量迁移；全新库直接用 schema.sql 即可，无需执行本文件。

ALTER TABLE devices ADD COLUMN first_version TEXT;
ALTER TABLE devices ADD COLUMN install_epoch INTEGER;

CREATE TABLE IF NOT EXISTS daily_active (
  day      INTEGER NOT NULL,
  id_hash  TEXT NOT NULL,
  PRIMARY KEY (day, id_hash)
);
CREATE INDEX IF NOT EXISTS idx_daily_active_day ON daily_active(day);

CREATE TABLE IF NOT EXISTS daily_stats (
  day          INTEGER NOT NULL,
  id_hash      TEXT NOT NULL,
  sessions     INTEGER NOT NULL DEFAULT 0,
  duration_sec INTEGER NOT NULL DEFAULT 0,
  vv           INTEGER NOT NULL DEFAULT 0,
  crash        INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, id_hash)
);
CREATE INDEX IF NOT EXISTS idx_daily_stats_day ON daily_stats(day);
