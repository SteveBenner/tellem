ALTER TABLE usage ADD COLUMN ts TEXT;
ALTER TABLE usage ADD COLUMN shared INTEGER NOT NULL DEFAULT 0;
ALTER TABLE usage ADD COLUMN cost_usd INTEGER;

UPDATE usage SET ts = (SELECT o.ts FROM observations o WHERE o.scope_id = usage.scope_id AND o.id = usage.id) WHERE ts IS NULL;
UPDATE usage SET shared = 1 WHERE id IN (SELECT id FROM usage GROUP BY id HAVING COUNT(*) > 1);

DROP INDEX IF EXISTS usage_model;
DROP INDEX IF EXISTS usage_day;
DROP INDEX IF EXISTS usage_repository;

CREATE INDEX IF NOT EXISTS usage_id ON usage (id);
CREATE INDEX IF NOT EXISTS usage_request ON usage (scope_id, request_key);
CREATE INDEX IF NOT EXISTS usage_shared ON usage (scope_id, id) WHERE shared = 1;
CREATE INDEX IF NOT EXISTS usage_unshared_ts ON usage (scope_id, ts) WHERE shared = 0 AND superseded = 0;
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
  requests INTEGER NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  cache_read_input_tokens INTEGER NOT NULL,
  cache_creation_input_tokens INTEGER NOT NULL,
  reasoning_tokens INTEGER NOT NULL,
  total_tokens INTEGER NOT NULL,
  input_tokens_n INTEGER NOT NULL,
  output_tokens_n INTEGER NOT NULL,
  cache_read_input_tokens_n INTEGER NOT NULL,
  cache_creation_input_tokens_n INTEGER NOT NULL,
  reasoning_tokens_n INTEGER NOT NULL,
  total_tokens_n INTEGER NOT NULL,
  cost_usd INTEGER NOT NULL,
  cost_usd_n INTEGER NOT NULL,
  PRIMARY KEY (scope_id, hour, group_key)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS usage_dirty (
  scope_id TEXT NOT NULL,
  hour TEXT NOT NULL,
  PRIMARY KEY (scope_id, hour)
) WITHOUT ROWID;

CREATE TRIGGER IF NOT EXISTS usage_dirty_insert AFTER INSERT ON usage BEGIN
  INSERT INTO usage_dirty (scope_id, hour) SELECT NEW.scope_id, SUBSTR(NEW.ts, 1, 13) WHERE NOT EXISTS (SELECT 1 FROM usage_dirty WHERE scope_id = NEW.scope_id AND hour = SUBSTR(NEW.ts, 1, 13));
END;

CREATE TRIGGER IF NOT EXISTS usage_dirty_update AFTER UPDATE ON usage BEGIN
  INSERT INTO usage_dirty (scope_id, hour) SELECT OLD.scope_id, SUBSTR(OLD.ts, 1, 13) WHERE NOT EXISTS (SELECT 1 FROM usage_dirty WHERE scope_id = OLD.scope_id AND hour = SUBSTR(OLD.ts, 1, 13));
  INSERT INTO usage_dirty (scope_id, hour) SELECT NEW.scope_id, SUBSTR(NEW.ts, 1, 13) WHERE NOT EXISTS (SELECT 1 FROM usage_dirty WHERE scope_id = NEW.scope_id AND hour = SUBSTR(NEW.ts, 1, 13));
END;

CREATE TRIGGER IF NOT EXISTS usage_dirty_delete AFTER DELETE ON usage BEGIN
  INSERT INTO usage_dirty (scope_id, hour) SELECT OLD.scope_id, SUBSTR(OLD.ts, 1, 13) WHERE NOT EXISTS (SELECT 1 FROM usage_dirty WHERE scope_id = OLD.scope_id AND hour = SUBSTR(OLD.ts, 1, 13));
END;
