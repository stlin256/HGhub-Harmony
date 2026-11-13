-- 0012：资源热更新（P5 / SPEC §5.3 / §7）
--
-- 远程资源按 name 单行存储，content 存 BLOB；POST /admin/asset 上传时服务端计算
-- sha256 并推进 version，GET /v1/assets/manifest 下发清单（带 HMAC 签名），
-- GET /v1/assets/<name> 下发原始字节，客户端按清单里的 SHA-256 校验后落盘。
-- 单文件 ≤ 512 KB、总量 ≤ 4 MB，由 Worker 应用层校验。
--
-- 对已部署的库做增量迁移；全新库直接用 schema.sql 即可，无需执行本文件。

CREATE TABLE IF NOT EXISTS remote_assets (
  name TEXT PRIMARY KEY,
  version INTEGER NOT NULL,
  sha256 TEXT NOT NULL,
  size INTEGER NOT NULL,
  content BLOB NOT NULL,
  updated_at INTEGER NOT NULL
);
