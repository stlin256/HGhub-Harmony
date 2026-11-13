-- 0013：灰度 / A-B 上报（P7 / SPEC §6）
--
-- 客户端日聚合上报新增：
--   ab_bucket = install_id 的 SHA-256 分桶（0-99）
--   ab_group  = bucket % 2（0-1）
-- -1 表示旧客户端未上报，统计时排除（不落到 bucket 0 / A 组，避免污染分布）。
--
-- 对已部署的库做增量迁移；全新库直接用 schema.sql 即可，无需执行本文件。

ALTER TABLE daily_stats ADD COLUMN ab_bucket INTEGER NOT NULL DEFAULT -1;
ALTER TABLE daily_stats ADD COLUMN ab_group INTEGER NOT NULL DEFAULT -1;
