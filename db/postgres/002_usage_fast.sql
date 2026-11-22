ALTER TABLE usage ADD COLUMN IF NOT EXISTS ts TEXT;
ALTER TABLE usage ADD COLUMN IF NOT EXISTS shared BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE usage ADD COLUMN IF NOT EXISTS cost_usd BIGINT;

UPDATE usage u SET ts = o.ts FROM observations o WHERE o.scope_id = u.scope_id AND o.id = u.id AND u.ts IS NULL;
UPDATE usage SET shared = TRUE WHERE id IN (SELECT id FROM usage GROUP BY id HAVING COUNT(*) > 1);

DROP INDEX IF EXISTS usage_model;
DROP INDEX IF EXISTS usage_day;
DROP INDEX IF EXISTS usage_repository;

CREATE INDEX IF NOT EXISTS usage_id ON usage (id);
CREATE INDEX IF NOT EXISTS usage_request ON usage (scope_id, request_key);
CREATE INDEX IF NOT EXISTS usage_shared ON usage (scope_id, id) WHERE shared;
CREATE INDEX IF NOT EXISTS usage_unshared_ts ON usage (scope_id, ts) WHERE NOT shared AND NOT superseded;
CREATE INDEX IF NOT EXISTS observations_supersedes ON observations (scope_id, supersedes) WHERE supersedes IS NOT NULL;

CREATE TABLE IF NOT EXISTS usage_rollup (
  scope_id TEXT NOT NULL,
  hour TEXT NOT NULL,
  group_key TEXT NOT NULL,
  agent_key TEXT,
  session_key TEXT,
  model TEXT,
  effort TEXT,
  persona TEXT,
  repository_id TEXT,
  place_id TEXT,
  day TEXT,
  subagent_type TEXT,
  requests BIGINT NOT NULL,
  input_tokens BIGINT NOT NULL,
  output_tokens BIGINT NOT NULL,
  cache_read_input_tokens BIGINT NOT NULL,
  cache_creation_input_tokens BIGINT NOT NULL,
  reasoning_tokens BIGINT NOT NULL,
  total_tokens BIGINT NOT NULL,
  input_tokens_n BIGINT NOT NULL,
  output_tokens_n BIGINT NOT NULL,
  cache_read_input_tokens_n BIGINT NOT NULL,
  cache_creation_input_tokens_n BIGINT NOT NULL,
  reasoning_tokens_n BIGINT NOT NULL,
  total_tokens_n BIGINT NOT NULL,
  cost_usd BIGINT NOT NULL,
  cost_usd_n BIGINT NOT NULL,
  PRIMARY KEY (scope_id, hour, group_key)
);

CREATE TABLE IF NOT EXISTS usage_dirty (
  scope_id TEXT NOT NULL,
  hour TEXT NOT NULL,
  PRIMARY KEY (scope_id, hour)
);

CREATE OR REPLACE FUNCTION tellem_usage_dirty_new() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO usage_dirty (scope_id, hour) SELECT DISTINCT scope_id, SUBSTR(ts, 1, 13) FROM tellem_new ON CONFLICT DO NOTHING;
  RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION tellem_usage_dirty_old() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO usage_dirty (scope_id, hour) SELECT DISTINCT scope_id, SUBSTR(ts, 1, 13) FROM tellem_old ON CONFLICT DO NOTHING;
  RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION tellem_usage_dirty_both() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO usage_dirty (scope_id, hour)
    SELECT scope_id, SUBSTR(ts, 1, 13) FROM tellem_old UNION SELECT scope_id, SUBSTR(ts, 1, 13) FROM tellem_new
    ON CONFLICT DO NOTHING;
  RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS usage_dirty_insert ON usage;
CREATE TRIGGER usage_dirty_insert AFTER INSERT ON usage REFERENCING NEW TABLE AS tellem_new
  FOR EACH STATEMENT EXECUTE FUNCTION tellem_usage_dirty_new();
DROP TRIGGER IF EXISTS usage_dirty_update ON usage;
CREATE TRIGGER usage_dirty_update AFTER UPDATE ON usage REFERENCING OLD TABLE AS tellem_old NEW TABLE AS tellem_new
  FOR EACH STATEMENT EXECUTE FUNCTION tellem_usage_dirty_both();
DROP TRIGGER IF EXISTS usage_dirty_delete ON usage;
CREATE TRIGGER usage_dirty_delete AFTER DELETE ON usage REFERENCING OLD TABLE AS tellem_old
  FOR EACH STATEMENT EXECUTE FUNCTION tellem_usage_dirty_old();
