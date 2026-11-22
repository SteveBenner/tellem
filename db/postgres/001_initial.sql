CREATE TABLE IF NOT EXISTS tellem_meta (
  key TEXT PRIMARY KEY,
  value TEXT
);

CREATE TABLE IF NOT EXISTS scopes (
  scope_id TEXT PRIMARY KEY,
  root TEXT NOT NULL,
  kind TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS observations (
  scope_id TEXT NOT NULL,
  id TEXT NOT NULL,
  session_key TEXT,
  agent_key TEXT,
  kind TEXT NOT NULL,
  ts TEXT NOT NULL,
  "schema" TEXT NOT NULL,
  supersedes TEXT,
  body JSONB NOT NULL,
  PRIMARY KEY (scope_id, id)
);

CREATE TABLE IF NOT EXISTS usage (
  scope_id TEXT NOT NULL,
  id TEXT NOT NULL,
  request_key TEXT,
  session_key TEXT,
  agent_key TEXT,
  subagent_type TEXT,
  model TEXT,
  effort TEXT,
  persona TEXT,
  repository_id TEXT,
  place_id TEXT,
  day TEXT,
  input_tokens BIGINT,
  output_tokens BIGINT,
  cache_read_input_tokens BIGINT,
  cache_creation_input_tokens BIGINT,
  reasoning_tokens BIGINT,
  total_tokens BIGINT,
  superseded BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (scope_id, id)
);

CREATE TABLE IF NOT EXISTS places (
  place_id TEXT PRIMARY KEY,
  kind TEXT,
  host TEXT,
  real_path TEXT,
  repository_id TEXT
);

CREATE TABLE IF NOT EXISTS sync_cursors (
  scope_id TEXT NOT NULL,
  file TEXT NOT NULL,
  inode BIGINT,
  "offset" BIGINT,
  PRIMARY KEY (scope_id, file)
);

CREATE INDEX IF NOT EXISTS observations_session_kind ON observations (session_key, kind);
CREATE INDEX IF NOT EXISTS observations_ts ON observations (ts);
CREATE INDEX IF NOT EXISTS usage_model ON usage (model);
CREATE INDEX IF NOT EXISTS usage_day ON usage (day);
CREATE INDEX IF NOT EXISTS usage_repository ON usage (repository_id);
