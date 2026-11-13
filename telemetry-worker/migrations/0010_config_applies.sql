-- 0010：配置应用回报（C10 / SPEC §15）
--
-- 客户端在 /v1/report 的日聚合里带 config_apply 数组，服务端按
-- (config_id, key, old_value, new_value, source) 聚合计数。
--
-- 隐私：只存聚合计数与时间范围，不存设备标识；count 是「设备·天」口径
-- （每台设备每天只上报一次日聚合）。
--
-- 对已部署的库做增量迁移；全新库直接用 schema.sql 即可，无需执行本文件。

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
