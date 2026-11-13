-- 0005：设备侧指标（内存 / 磁盘 / 功耗）与线路指标（请求成败 / 延迟）
--
-- 全部是设备聚合数值，不含任何标识或内容。

ALTER TABLE daily_stats ADD COLUMN mem_pss_kb        INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN mem_peak_kb       INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN mem_vss_kb        INTEGER NOT NULL DEFAULT 0;

ALTER TABLE daily_stats ADD COLUMN disk_app_bytes    INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN disk_cache_bytes  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN disk_data_bytes   INTEGER NOT NULL DEFAULT 0;

ALTER TABLE daily_stats ADD COLUMN soc_start         INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN soc_end           INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN temp_max_c        REAL    NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN charging          INTEGER NOT NULL DEFAULT 0;

ALTER TABLE daily_stats ADD COLUMN line_primary_ok   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN line_primary_fail INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN line_mirror_ok    INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN line_mirror_fail  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN line_switches     INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN line_latency_avg_ms INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN line_latency_p90_ms INTEGER NOT NULL DEFAULT 0;
