-- 0006：功耗与性能指标（CPU 占用 / 热等级 / 瞬时功率）
ALTER TABLE daily_stats ADD COLUMN cpu_pct      INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN cpu_peak_pct INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN thermal_level INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN power_mw     INTEGER NOT NULL DEFAULT 0;
