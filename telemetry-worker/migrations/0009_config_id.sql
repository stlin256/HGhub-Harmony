-- 0009：配置唯一 ID（C11 / SPEC §16）
--
-- 每次 POST /admin/config 成功发布时生成新的 config_id（crypto.randomUUID()），
-- 全局唯一、永不复用；config_version 单调递增，同一 version 重发返回 409，
-- 因此同一版本的 config_id 不可变。
--
-- 对已部署的库做增量迁移；全新库直接用 schema.sql 即可，无需执行本文件。
-- 旧行（迁移前发布）的 config_id 为空串，客户端按「未下发」处理。

ALTER TABLE remote_config ADD COLUMN config_id TEXT NOT NULL DEFAULT '';
