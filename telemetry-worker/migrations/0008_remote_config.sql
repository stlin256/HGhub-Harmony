-- 0008：远程配置下发（GET /v1/config）
--
-- 单行配置（id 固定为 'global'），version 单调递增，payload 是去掉 sig 的完整响应体 JSON。
-- 服务端只透传 payload 字段，不做深度校验；客户端负责合并与类型/范围校验。

CREATE TABLE IF NOT EXISTS remote_config (
  id TEXT PRIMARY KEY,
  version INTEGER NOT NULL,
  payload TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
