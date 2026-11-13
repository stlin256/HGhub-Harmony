-- 0011：更新闸门（P4 / SPEC §5.2）
--
-- 单行版本信息（id 固定为 'global'）：POST /admin/release 覆盖式写入，
-- GET /v1/update 读取后附加 HMAC 签名下发；客户端据 latest / min_version / rollout_pct
-- 判定 force（强制更新）/ soft（灰度提示）/ none（不提示）三态。
--
-- 对已部署的库做增量迁移；全新库直接用 schema.sql 即可，无需执行本文件。

CREATE TABLE IF NOT EXISTS app_release (
  id TEXT PRIMARY KEY,
  latest TEXT NOT NULL,
  min_version TEXT NOT NULL,
  rollout_pct INTEGER NOT NULL DEFAULT 0,
  notes TEXT,
  url TEXT,
  updated_at INTEGER NOT NULL
);
