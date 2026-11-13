-- 0003：扩展日聚合指标（启动耗时 / 播放失败 / 超分 / 画质 / 完播 / 页面分布）
--
-- 全部是「当日聚合计数」，不含逐条事件，服务端看不到具体看了什么内容。

ALTER TABLE daily_stats ADD COLUMN startup_p50_ms   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN startup_p90_ms   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN startup_ms_sum   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN startup_ms_count INTEGER NOT NULL DEFAULT 0;

ALTER TABLE daily_stats ADD COLUMN play_fail     INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN fail_network  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN fail_auth     INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN fail_notfound INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN fail_server   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN fail_other    INTEGER NOT NULL DEFAULT 0;

ALTER TABLE daily_stats ADD COLUMN sr_on          INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN sr_supported   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN quality_hd     INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN quality_sd     INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN play_complete  INTEGER NOT NULL DEFAULT 0;

ALTER TABLE daily_stats ADD COLUMN page_home      INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN page_search    INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN page_category  INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN page_profile   INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_stats ADD COLUMN page_player    INTEGER NOT NULL DEFAULT 0;
