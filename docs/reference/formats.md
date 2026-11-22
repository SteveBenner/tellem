# tellem record formats

This is the reference for every file tellem writes. It restates `data_model` of
`specs/tellem.impl.yml` 0.2.0 and names the concrete choices the foundation code
(`lib/tellem/record/`, `lib/tellem/ids.rb`) makes where the spec leaves the
spelling open. `lib/tellem/record/formats.rb` and `lib/tellem/record/kinds.rb`
are the executable form of this page.

## Layout

```
<root>/.tellem/                          root = main working tree of a repository, or <state_dir>/user
  .gitignore                              "*", or in a repository declared private only the volatile files
  scope.json                              tellem.scope/v1
  config.yml                              optional per-scope settings
  capture.off                             optional; presence disables capture for this scope
  sessions/<session_key>/
    raw/<agent_key>.jsonl                 tellem.raw/v1, appended by the hook
    derived.jsonl                         tellem.derived/v1, appended by the deriver
    bodies/<agent_key>.jsonl              redacted lines taken from the body spool, native entry shape
    bodies/sideband.jsonl                 counters of title, suggestion, and compaction requests
    transcripts/<base>.md                 main transcript; <base> = YYYY-MM-DD_HH-MM-SS±ZZZZ-<slug>
    transcripts/<base>--subagent-<agent_id>.md
  pointers/<session_key>.json             tellem.pointer/v1, sessions homed elsewhere
  views/TOKENS.jsonl                      projection
  prune.jsonl                             tellem.prune/v1 receipts
  derive.lock  derive.dirty  derive.cursor.json
  mirror.sqlite3                          optional scope-level SQLite mirror

<state_dir> = TELLEM_STATE_HOME, else Rplugin::Paths.state_home/tellem
  capture.enabled                         presence enables capture
  capture.fsync                           presence makes every hook fsync before it exits
  scope.exclude_roots                     one resolved excluded root per line, mirrored from the setting; absent when the setting is empty
  homes/<session_key>                     tellem.home/v1, created exclusively by the first hook
  hook-gaps.jsonl                         content-free hook failures
  bodies/                                 Claude Code body spool: index.jsonl, *.request.json, *.response.json
  registry.jsonl                          SDK state port stream "registry"
  user/.tellem/                           the user scope
  mirror.sqlite3                          optional user-level SQLite mirror
  backend-breaker.json
  cutover/<plan_id>/                      plan.json, apply.patch, rollback.patch, backup/
```

Directories are created mode 0700 and files mode 0600. Every record file is
opened with `O_NOFOLLOW`; a symlinked `.tellem` directory, a symlinked directory
below it, or a symlinked record file is refused with `Tellem::SymlinkRefused`.
## Repository visibility

A repository's visibility is the `visibility` setting of its scope, `public` or
`private`, declared in `.tellem/config.yml` and read through tellem's one
config resolver. A repository with no declaration is public. tellem never asks
a remote, a host API, or a credential (app D-17).

- Public: `.tellem/.gitignore` holds the single line `*`, so git ignores the
  whole scope, the `.gitignore` included. Once `.specstory/history/` exists,
  `.specstory/history/.gitignore` holds `*` too.
- Private: `.tellem/.gitignore` lists only the volatile files, `derive.lock`,
  `derive.dirty`, `derive.cursor.json`, `mirror.sqlite3` with its `-wal`,
  `-shm`, and `-journal` files, and tellem's temporary `*.tmp` files, so the
  record, transcripts, views, and config may be committed. A
  `.specstory/history/.gitignore` whose bytes are exactly `*` and a newline is
  removed.
- A `.specstory/history/.gitignore` with any other bytes is not tellem's and is
  left alone in either case; in a public repository `tellem doctor` reports it
  when it does not ignore tellem's copies.
- The user scope is never a repository and always keeps `*`.
- The setting is read and written at scope level only. A user-level value is
  ignored and `tellem doctor` reports it; `tellem config set visibility`
  without a repository scope is a usage error.

The hook never reads the setting: `Record::Scope.open` creates a new scope's
`.gitignore` as `*`, so a new scope stays ignored until the deriver reconciles
it. `Tellem::Record::Visibility.reconcile` runs in every derive pass for the
scope derived and every scope a pointer was written into, before the SpecStory
writer's first copy, and at once on `tellem config set visibility`. It writes an
ignore file only when its bytes differ, through a temporary file and a rename,
and refuses a symlinked directory or ignore file. tellem never runs `git add`,
`git rm`, or `git commit`, and never edits a repository's own `.gitignore` or
`.git/info/exclude`.

## Locating a scope

`Tellem::Record::Scope.locate(cwd)` resolves the real path of `cwd` (or of its
deepest existing ancestor) and walks up to the first directory holding `.git`:

- `.git` is a directory: that directory is the root.
- `.git` is a file (`gitdir: <path>`): the common directory is `<gitdir>/commondir`
  when present, else the gitdir. The root is the parent of the common directory
  when it is named `.git` (a linked worktree folds into its main working tree),
  else the directory holding the `.git` file (a submodule).
- No `.git` up to `/`: the user scope root `<state_dir>/user`.

No git process runs; the hook can afford this walk.

## Timestamps

Every `ts` (RFC 3339 ms) and every other RFC 3339 field is UTC with a `Z`
suffix. Records with an offset are rejected, so string order is time order and
the first ten characters of `ts` are the UTC day.

## Identifiers

| Identifier | Rule |
| --- | --- |
| `session_key` | `<harness>-<session_id>`, harness in `claude`, `codex`; `session_id` matches `[A-Za-z0-9_-]{1,200}`, otherwise the session is recorded under the user scope with a gap |
| `agent_key` | `main` for the main agent, else the harness agent id with every character outside `[A-Za-z0-9_-]` removed, cut to 128 characters |
| `scope_id` | first 16 hex of `sha256(host + NUL + real root path)` |
| `place_id` | first 24 hex of `sha256(canonical JSON of the place identity)` |
| `repository_id` | first 24 hex of `sha256(canonical JSON of [host, common git dir])` |
| derived `id` | first 32 hex of `sha256(canonical JSON of [schema, kind, identity fields in table order])` |
| raw `id` | first 32 hex of `sha256(canonical JSON of [harness, session_id, agent_key, event, tool_use_id or "", ts_ns, pid])` |
| usage `counters_digest` | first 32 hex of `sha256(canonical JSON of the counter fields present)` |

Canonical JSON: keys sorted, no insignificant whitespace, UTF-8, integers as
integers, and no floats in identity fields (`Tellem::Ids.canonical_json`
refuses them). `host` is `/proc/sys/kernel/hostname`, else `Socket.gethostname`.

## Append protocol

`Tellem::Record::HookCore.append(path, line, sync: sync_requested?)` follows
ADR-2:

1. Open with `O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW`, mode 0600.
2. `flock(LOCK_EX)`.
3. Read the last byte. When it is not a newline, a killed writer left a torn
   tail; prefix the write with a newline so the fragment becomes its own
   (unparseable) line.
4. One write of the record line and its newline.
5. `flock(LOCK_UN)`.
6. Only when `sync` is true: `fsync` the file, then `fsync` the directory when
   the file was empty. The call returns, and the observation is acknowledged,
   after this step.

`sync_requested?` is true when `<state_dir>/capture.fsync` exists. The hook gap
stream (`HookCore.hook_gap`) uses the same rule. Without the flag the hook does
not fsync: the write is in the kernel when `append` returns, so no process crash
loses it, and only a power loss or kernel crash before the next derive can.

The deriver makes raw files durable before it persists a cursor with
`Tellem::Record::FS.fsync_file(path)` (opens the file `O_RDONLY | O_NOFOLLOW`
and fsyncs it; false when the file is missing) and `FS.fsync_dir(dir)` for the
directory of a file it has not flushed before. `FS.flush(path, new_file:)` does
both in that order.

A raw line is at most 65536 bytes including the newline; a derived line at most
8388608 bytes. `Tellem::Record::Reader.each(path, from: cursor)` reads only
complete lines, counts every non-empty line that does not parse as a JSON object
as torn, never consumes an unterminated tail, and returns the cursor
`{"inode", "offset"}` with `torn`, `records`, and `partial_tail` counts beside
it. A cursor whose inode differs from the file's, or whose offset is past the
end, restarts at 0.

The derived writer (`Tellem::Record::Writer.append_derived`) takes the lock,
reads the ids already present, appends only records with new ids, and fsyncs the
file (and the directory of a new file) before it releases the lock, so a replay
appends nothing. `replace_atomic` writes a temporary file in the same
directory, fsyncs it, renames it over the target, and fsyncs the directory.

## Files

### scope.json (`tellem.scope/v1`)

| Field | Type | Notes |
| --- | --- | --- |
| schema | string | `tellem.scope/v1` |
| scope_id | string | see identifiers |
| kind | string | `repository` or `user` |
| root | string | real path |
| host | string | |
| created_at | RFC 3339 | |

Written once by whichever process creates the scope, through a temporary file
and an exclusive `link`; never rewritten.

### raw/<agent_key>.jsonl (`tellem.raw/v1`)

Every line carries every key below, in this order, with `null` for what the
payload did not supply. `Tellem::Record::Formats.raw` refuses any other key, so
no content field can enter the schema.

The hooks for `session_start`, `prompt_submit`, `post_tool`, the failed-call
hook, `subagent_start`, and `subagent_stop` run in the background (rplugin
`async: true`, Claude Code `async`) with a 30 s timeout, so their lines can land
after later events and can be lost when the harness exits. `stop` and
`session_end` run synchronously with a 2 s timeout. Harnesses without background
hooks run every hook synchronously.

A failed tool call (Claude Code `PostToolUseFailure`, rplugin
`post_tool_failure`) is recorded as `event` `post_tool` with `harness_event`
`PostToolUseFailure`, its `tool`, `tool_use_id`, `paths`, `program`, and
`url_host` as for a successful call, and `outcome` `error`. The payload's
`error` text is not recorded.

The deriver treats an expected line as missing only once it is overdue: more
than 35 s (the largest background timeout plus 5 s) after the transcript time
it follows, which is the tool call's result time for `post_tool` and the spawn
call's time for `subagent_start`. A session with an expectation not yet overdue
stays unsettled in the cursor and is derived again until it settles.

| Field | Type | Notes |
| --- | --- | --- |
| schema | string | `tellem.raw/v1` |
| id | string | raw id rule |
| ts | RFC 3339 ms | from `ts_ns` |
| harness | string | `claude`, `codex` |
| harness_event | string | the payload's `hook_event_name` |
| event | string | `session_start`, `prompt_submit`, `post_tool`, `stop`, `session_end`, `subagent_start`, `subagent_stop` |
| session_id | string | |
| agent_id | string | null for the main agent |
| agent_type | string | |
| cwd | string | as reported |
| tool | string | |
| tool_use_id | string | |
| paths | list of strings | at most 16, each at most 4096 bytes, from `tool_input` `file_path`, `path`, `notebook_path` |
| program | string | basename of the first token after leading `VAR=value` assignments; shell tools only |
| url_host | string | host only; URL tools only |
| transcript_path | string | trusted only because it came from the hook payload |
| agent_transcript_path | string | `subagent_stop` only; the subagent's own native transcript, from the hook payload |
| start_source | string | `session_start` only |
| permission_mode | string | from the hook payload when it carries one; Claude's `SessionStart` and `SessionEnd` payloads do not |
| billing | string | `session_start` only, from the hook's own environment: Claude `api` when `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` is set, `bedrock` for `CLAUDE_CODE_USE_BEDROCK=1`, `vertex` for `CLAUDE_CODE_USE_VERTEX=1`, else `subscription` when the harness credentials path exists (an lstat; the file is never opened), else `unknown`; Codex `api` when `OPENAI_API_KEY` is set, else `unknown` |
| outcome | string | `ok`, `error`, or null when unknown |
| payload_bytes | integer | |
| over_limit | boolean | |
| shape | string | `known`, `unrecognized` |
| missing_keys | list of strings | |
| hook_ms | integer | process start to pre-write from `/proc/self/stat`; null off Linux |
| tellem_version | string | |

### derived.jsonl (`tellem.derived/v1`)

| Field | Type | Notes |
| --- | --- | --- |
| schema | string | `tellem.derived/v1` |
| id | string | derived id rule |
| kind | string | one of the kinds below |
| ts | RFC 3339 ms | time of the thing observed, or the sample time for samples |
| session_key | string | |
| agent_key | string | |
| supersedes | string | null or an earlier id |
| body | object | kind-specific fields |

`session_key` and `agent_key` identity fields are read from the top level; every
other identity field is read from `body`. A body may carry fields beyond those
listed; enumerated fields are checked when present.

| Kind | Identity | Body |
| --- | --- | --- |
| session | session_key | harness, harness_version, host, home_place_id, started_at, ended_at |
| agent | session_key, agent_key | parent_agent_key, spawn_tool_use_id, agent_type, model, effort, isolation (`shared`, `worktree`), home_place_id, evidence (`transcript_link` when the parent's transcript names the child from a spawn call, `parent_thread_id` when only a Codex child's `session_meta` names its parent, `subagent_start`, `none`) |
| place | place_id | kind (`local`, `host`, `container`, `cluster`, `domain`, `remote_repository`), host, real_path, resolved (`full`, `partial`, `missing`), repository_id, attributes |
| repository | repository_id | host, common_dir, remotes (sanitized) |
| stands_in | session_key, agent_key, place_id, first_raw_id | from, to |
| works_in | source_id (raw id or transcript tool_use id), place_id | op (`read`, `search`, `write`), tool |
| shells_out | tool_use_id | place_id, program, command (only with `commands.full`) |
| reaches | tool_use_id, place_id | via_program, evidence (`argument`, `url`, `git_remote`) |
| spawn | session_key (the parent session), spawn_tool_use_id | parent_agent_key, child_agent_key, spawned_at_place_id, requested_type, isolation |
| lifecycle | session_key, agent_key, state, source_id | state (`started`, `running`, `waiting_on_user`, `stopped`, `failed`) |
| context | session_key, agent_key, source_id | model, effort, standing_place_id, branch |
| message | session_key, agent_key, channel, message_key | message_key, channel (`spawn`, `send`, `handback`, `receive`), from_agent_key, to_agent_key (agent keys of the session, else null), from_address, to_address (the raw sender or target when it is not an agent of the session, or the requested type of a spawn with no linked child), from_name, summary (the sender's summary, `send` only), head (the first 200 bytes of the redacted text on a character boundary), bytes (size of the unredacted text), digest (SHA-256 hex of the whole redacted text, so both sides of one message agree), source_id (the entry ref of the call, result, or turn that holds the whole text), delivered_at (`spawn`: the call's result time), is_error (`handback`). `agent_key` is the sender for `spawn`, `send`, and `handback`, and the receiver for `receive`. `message_key` is the tool_use_id for `spawn` and `send`, `<tool_use_id>:handback` for `handback`, and the earliest copy's ref for `receive`. A tool the transcript policy withholds gives null head, digest, and summary and keeps bytes (D-33) |
| workspace | place_id, sampled_at | status (`ok`, `unknown`), cause, branch, dirty, worktree, ahead, behind, duration_ms |
| usage | harness, request_key, counters_digest | model, input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, reasoning_tokens, total_tokens, service_tier; for Claude also stop_reason, cache_creation_ephemeral_1h_input_tokens, cache_creation_ephemeral_5m_input_tokens, server_tool_use_web_search_requests, server_tool_use_web_fetch_requests (null when not reported, outside counters_digest); ledger fields for the TOKENS view, outside counters_digest: first_line_at, first_line_uuid (the request's first transcript line), inference_geo and speed (Claude usage), permission_mode, billing, ledger_id (the Codex `token_count` fallback's incumbent id), cwd (the Codex turn's `turn_context` cwd, else the session's); attribution filled by the deriver from what it knows when it derives the request: subagent_type, effort, persona (members digest, lead, authority), persona_key, repository_id, place_id (the agent's standing place) |
| usage_line | harness, request_key, line_uuid, line_at | harness, request_key, line_uuid, line_at: one request's last transcript line as a derive saw it; the deriver appends one whenever that line is one it has not recorded, so a request read mid-message gains a later record instead of keeping a stale line |
| usage_detail | harness, request_key | harness, request_key, effort, cost_usd (US dollars as Claude Code reports them), ttft_ms, duration_ms, query_source, agent_name, source (`otel`): one Claude Code `api_request` OpenTelemetry event (D-16, ADR-11), joined to usage by `request_key`. The deriver matches the event's `request_id` to the transcript's `requestId` of a usage observation of the same session and writes the detail under that usage's `request_key` and agent; the first event per request wins; an event whose model or four token counters differ from the usage is dropped with an `otel_mismatch` gap once the request is older than SETTLE_S; an event whose `request_id` no usage carries writes nothing. It never creates usage or changes a counter; reports and the mirror take `effort` from it only when the usage body has none |
| request_start | harness, request_key | harness, request_key, started_at (the transcript time of the entry immediately preceding the request's first line in the same agent thread: a prompt, a tool result, or a resume message; no observation when nothing precedes it) |
| tool_call | session_key, tool_use_id | tool_use_id, agent_key, tool, started_at (the call's transcript time), ended_at (the tool result's transcript time), duration_ms (null without started_at), is_error (the tool result's flag, null when the transcript carries none): one answered tool call, written once its result is in the transcript, so a call with no result yet has no observation |
| persona | session_key, revision, authority, effective_at | members [{name, version, digest}], lead, speaker, authority (`transcript_observed`, `sampled`, `unknown`) |
| transcript | session_key, agent_key, native_inode, native_size | path, sha256, source (`native`, `specstory_lossy`, `ledger`), final |
| task | id, state_digest | name, repo, started (epoch seconds of the first prompt), opened_by {via (the rule that opened it: `workflow`, `score`, `stale`, `no_task`, `after_done`, `fault`, `marker_new`, `split`), decision}, sessions, attached, turns [{session_id, prompt_id, at, head (at most 120 redacted characters), decision, spans [[start, end or null]], closing}], subagents [{agent_id, agent_type, session_id, start, end or null}], fingerprint (redacted words, at most 600), first_tokens, wip_counts, last_activity, closed ({at, reason} or null), merged_into, and state_digest (the first 32 hex characters of the SHA-256 of the task as JSON without it, so that each state of a task is its own observation and a later state supersedes the one before; D-18; derived by one engine from the session record under tasks.mode, equal in shape to the task clock's task file) |
| gap | cause, location (the scope location of the loss; `align/<agent_key>/<tool_use_id>` for `unmatched_tool_call`, one gap with count 1 per overdue call, so the cause's total rises as later calls go overdue; `harness/<call>` for `harness_unreadable`, a harness lookup that failed on missing, unreadable, or non-directory paths or a typed harness-port error, with `error_class` in detail) | harness, harness_version, detail (content-free), count |

### pointers/<session_key>.json (`tellem.pointer/v1`)

| Field | Type | Notes |
| --- | --- | --- |
| schema | string | `tellem.pointer/v1` |
| session_key | string | |
| home_scope_id | string | |
| home_root | string | |
| first_at | RFC 3339 | |
| last_at | RFC 3339 | |
| kinds | list of strings | subset of `works_in`, `shells_out_from`, `stands_in`, sorted |
| agents | list of strings | sorted |

Written only by the home scope's deriver, replaced atomically, and never
contains observations. A pointer whose home scope or session directory is gone
reports the session as gone (`Tellem::Record::Pointers.gone?`).

### homes/<session_key> (`tellem.home/v1`)

| Field | Type | Notes |
| --- | --- | --- |
| schema | string | `tellem.home/v1` |
| root | string | scope root |
| scope_id | string | |
| kind | string | `repository` or `user` |
| inferred | boolean | true when the first hook was not `session_start` of the main agent |

Created by the first hook of a session: the entry is written to an exclusively
created temporary file and linked into place, so the first writer wins and no
reader sees a partial entry. Later hooks read it.

### registry.jsonl

One line per scope: `scope_id`, `root`, `kind`, `first_seen` (RFC 3339). The
first line per `scope_id` wins. It is the SDK state port stream `registry`; when
`TELLEM_STATE_HOME` is set the same lines go to `<state_dir>/registry.jsonl`
through the append protocol, so isolated runs never touch the SDK state.

### hook-gaps.jsonl

One content-free line per hook failure: `ts`, `cause`, and only these optional
keys: `harness`, `harness_event`, `event`, `session_key`, `error_class`,
`errno`, `payload_bytes`, `over_limit`, `missing_keys`, `tellem_version`.
Strings are cut to 200 bytes. Two causes belong to `scope.exclude_roots`:
`home_moved_excluded` (a session whose recorded home is covered moved to the
user scope) and `exclude_roots_unreadable` (the mirror file exists but cannot be
read, so every repository is treated as excluded).

### otel/claude-<session_id>.jsonl

The OpenTelemetry spool, written only by `bin/tellem-otel serve` under the state
directory (directory 0700, files 0600) with the append protocol. One line per
received `claude_code.api_request` event, holding only `ts` (the event's
`event.timestamp`), `session_id`, `request_id`, `model`, `effort`, `cost_usd`,
`ttft_ms`, `duration_ms`, `query_source`, `agent_name`, and the four counters
`input_tokens`, `output_tokens`, `cache_read_tokens`, and
`cache_creation_tokens`, kept only for the consistency check. Every other
attribute is dropped before the write. The deriver reads it for the session
whose key names the file and writes `usage_detail` observations from it.
`otel/receiver.pid`, `otel/receiver.lock`, and `otel/receiver.json` (state,
port, counters of kept, ignored, and refused events by cause) sit beside it.

### bodies/ (body spool)

`<state_dir>/bodies` is the directory Claude Code writes when
`OTEL_LOG_RAW_API_BODIES=file:<dir>` names it. It holds raw prompts and account
data, so the deriver and `tellem parity bodies` read it only while it is a real
directory, owned by the running user, at mode 0700. Anything else is a
`spool_unsafe` gap naming the reason, and nothing in it is read or removed. A
file name in an index line is reduced to its basename and must match the
request or response pattern, so a path inside an event cannot reach outside the
directory.

The deriver reads the spool only for a session with no native main transcript.
Each request becomes lines under `sessions/<session_key>/bodies/`:

- `<agent_key>.jsonl` holds one line per content block in the native entry shape
  `Ingest::Claude` reads, with `bodyRequest` and `bodySource` added. Text, tool
  input, and tool results are redacted before the write. No system prompt, tool
  schema, or `metadata` value is kept. A thinking block is stored as an empty
  `thinking` with `unavailable: redacted_by_harness`, which reaches entries as a
  `reasoning` entry with that note and no text. Native transcripts may hold reasoning
  text on some models (`reasoning_text_only_in_native`).
- `sideband.jsonl` holds only `bodyRequest`, `timestamp`, `query_source`, `model`,
  and the numeric usage fields of a `generate_session_title`, `prompt_suggestion`,
  or `compact` request. These requests reach no transcript or usage record.

A held file is replaced atomically and kept sorted by `timestamp`. The spool files
of a request are unlinked only after its lines are durable. A run that is killed
before the unlink finds the request in the held file, adds no lines, and unlinks
the files. `index.jsonl` is never rewritten, because the harness appends to it.

A request file with no index line is an interrupted or failed attempt. It is read
only after the session ended, because before that it may still be in flight. An
attempt with a `thread` field contributes its new user blocks. One without is
discarded. A request whose agent cannot be proven is kept in the spool, and past
the settle window it is reported as a `body_unattributed` gap. A chain that hooks
tie to two agents is a `body_attribution_conflict` gap. A shape the reader does
not recognize is a `shape_unrecognized` gap, and its files stay in the spool.

A body file holding `not_recorded`, `body_withheld`, or a truncation mark, or a tool
use whose input is `{not_recorded: ...}`, is a `body_marked` gap, and its files stay.
Interrupted attempts add a `native_only_request` gap with location
`bodies/interrupted`. A request file with no index line that belongs to an ended
session and is older than the retention window is unlinked, with a `spool_orphan` gap
holding only the count. While the authority stop switch is set, no spool file is
removed.

A transcript record's `source` is `bodies` when the session's main transcript came
from the spool, and `native` otherwise.

### authority/ (`tellem.authority/v1`)

`<state_dir>/authority/state.json` holds `generation`, `harnesses` (per harness:
`plan_id`, `level`, `prior`, `applied_at`, `applied_ns`, `env` as key to sha256 of the
value so no token is stored, `settings_path`, after a lowering `restored_from`
and `restored`, and while a restore is failing `restore_failed`), and `lost`
(`harness`, `kind`, `reason`, `session_key`, `at`, `from`, `plan_id`).

`restore_failed` holds `harness`, `kind`, `reason`, `session_key`, `error` (an error
class, or `lock_busy`), `message`, `file`, `first_at`, `at`, and `attempts`. It keeps
the kind and reason of the first failure until a restore succeeds.

`receipts.jsonl` holds one line per lowering: `schema`, `at`, `kind`
(`capture_lost`, `level_ineffective`, or `stop_switch`), `harness`, `reason`,
`session_key`, `from`, `to`, `plan_id`, `env_removed`, `env_kept`, `backup`, and,
after a failed restore, `recovered_from` (`first_at`, `attempts`, `error`).

`<state_dir>/cutover/<plan_id>/import.json` is the history import of a `--specstory
subsume` plan: `plan_id`, `state`, `pid`, `started_at`, `updated_at`, `finished_at`,
`attempts`, `sources` (per source `sessions`, `to_import`, `skipped`, `scopes`,
`files`), `done` (per `source:root` the counts of a finished scope), `failures`
(`source`, `root`, `error`, `message`), `sessions_imported`, `observations_added`,
`gaps_added`, `sources_changed`, `sources_changed_sample`, and `compressed_rollouts`.
`import.lock` beside it is held while the import runs; a `running` state with the lock
free reads as `interrupted`.

`body-parity.jsonl` (`tellem.body-parity/v1`) holds one line per compared session:
`schema`, `at`, `harness`, `harness_version`, `session_key`, `scope_root`, `verdict`,
`causes` (cause name to count), `agents`, and `requests`. It holds no content.

`<state_dir>/authority.off` is the stop flag. Its presence means stop; its content
is not read for meaning.

### prune.jsonl (`tellem.prune/v1`)

`schema`, `plan_id`, `rule`, `removed` (session keys and pointer names, sorted),
`bytes` (integer), `at` (RFC 3339).

### forget.jsonl (`tellem.forget/v1`)

One receipt per session removed by `tellem forget`: `schema`, `plan_id`, `rule`,
`session_key`, `removed` (file paths under `.tellem`), `removed_copies` (identical
`.specstory/history` copies), `removed_dirs`, `bytes`, `at`, `remaining` (planned
paths that were no longer removable). `forget` plans first and applies only with
`--confirm PLAN_ID`; it unlinks the planned files one by one and removes only empty
directories.

### entries/<agent_key>.jsonl (`tellem.entry/v1`)

Written only while `transcripts.entries` is true (default false), beside `raw/`,
`transcripts/`, and `derived.jsonl` in `sessions/<session_key>/`. Append-only; an
entry's `id` is a hash of its source, kind, and part, so a rerun adds nothing.
Fields: `schema`, `id`, `session_key`, `agent_key`, `seq` (per file, one per line),
`kind` (`prompt`, `reply`, `reasoning`, `action`, `output`), `at`, `tool`,
`call_id`, `text`, `part` (`null`, or `[n, of]` when the text was split), `withheld`,
`note` (`error` for a failed result, `withheld`, or a prompt source such as `queued`
or `compact_summary`), `source` (`native:<ref>`).

`text` is redacted before it is written. For an `action` it is the tool's complete
input as JSON for every tool (the `tool_payload_bytes` omission does not apply);
for a string input it is that string. A text whose entry line would exceed
`record_bytes` is split into consecutive parts whose texts join to the redacted
text exactly. Visible reasoning appears only here. A call withheld by the
`transcript_policy` port keeps `tool` and `call_id`, with `withheld: true` and a
`null` text for the action and its output. An entry already written is not
rewritten when a policy later starts to withhold it; use `tellem forget`.

`tellem sync --session KEY [--scope PATH] [--timeout SECONDS]` derives the
session's scope and blocks at most the timeout (default 30); on timeout it exits 4
(`busy`, `detail.timed_out` true). `tellem export --session KEY [--after CURSOR]
[--limit N] [--scope PATH] --json` reads files only and returns `{session_key, scope_root, enabled, entries,
next_cursor, more}`. Entries carry a `cursor` and merge across agents by `at`,
agent key, and `seq`. A cursor (`e1:AGENT=SEQ,...`) names the last `seq` consumed per
agent file, so it stays valid across derives and a kill during one.
`tellem search QUERY [--scope PATH | --all] [--limit N]` matches Markdown
transcripts only.

### transcript_policy port

`withhold_tools` (tool names), `withhold_paths` (absolute path prefixes), and
`native_readers` (reader ids). The standalone form returns empty lists. A policy that
raises, takes longer than 3 s, or returns another shape stops transcript ingestion for
the scope: each session gets a `policy_failed` gap (location
`transcript/<session_key>:reason=<raised|timeout|shape>`), nothing is rendered or
entered, and the cursor does not move, so a later derive retries.

### config.yml

A YAML mapping of setting keys to values, flat (`commands.full: true`) or nested
(`commands: {full: true}`). Keys are those declared in `tellem.rplugin.yml`;
values failing their type are ignored. Resolution is the built-in default, then
the SDK user layers, then this file, with the scope winning; the kill switches
`TELLEM_DISABLED`, `TELLEM_DERIVE_DISABLED`, and `TELLEM_BACKEND_DISABLED` win
over every layer for `features.capture`, `features.derive`, and
`features.mirror_sync`. `features.capture: false` in a scope's file is mirrored
to that scope's `capture.off`. The user-level `features.capture` is mirrored to
`<state_dir>/capture.enabled` and `capture.fsync` to `<state_dir>/capture.fsync`
whenever `Tellem::Config.set` or `unset` changes them. `scope.exclude_roots` is
mirrored to `<state_dir>/scope.exclude_roots` (one expanded, symlink-resolved
root per line, written atomically, removed when the setting is empty) by
`Tellem::Config.set`, `unset`, and `sync_capture_flag`.

### Reports (`tellem.report/v1`)

`bin/tellem <command> --json` prints one document: `schema`, `command`, `data`,
and `error` (`code`, `message`, `next_command`, `detail`) when the command
failed. Exit codes: 0 ok, 1 operational failure, 2 usage, 3 confirmation
required, 4 busy, 5 capability unavailable.

## Usage accounting

- Claude: one provider request per assistant `message.id`. Content blocks
  sharing a `message.id` share one usage; the last occurrence in file order wins
  and supersedes earlier counters. `total_tokens = input_tokens + output_tokens +
  cache_read_input_tokens + cache_creation_input_tokens`. `reasoning_tokens` is
  null.
- Codex: one provider request per `token_usage_record` entry, keyed by its
  `response_id` and charged its usage object. Rollouts without
  `token_usage_record` fall back to `token_count` events whose
  `total_token_usage` differs from the previous event in the same rollout, keyed
  `<thread_id>:<ordinal>` and charged `last_token_usage`, never the cumulative
  total. `input_tokens` includes `cached_input_tokens`, so
  `cache_read_input_tokens = cached_input_tokens`,
  `cache_creation_input_tokens = cache_write_input_tokens`, and `total_tokens` is
  the provider's `total_tokens`. `reasoning_tokens = reasoning_output_tokens`. A
  forked rollout that repeats earlier records repeats their `response_id`, so the
  same request is never charged twice.
- A missing counter is null. Distinct requests with equal numbers stay distinct
  because `request_key`, not the counters, identifies them.

These rules are also `Tellem::Record::Formats::USAGE_RULES`. The Codex counter
mapping is `Tellem::Record::Formats::CODEX_COUNTER_MAP`:

| tellem counter | Codex usage field |
| --- | --- |
| input_tokens | input_tokens |
| output_tokens | output_tokens |
| cache_read_input_tokens | cached_input_tokens |
| cache_creation_input_tokens | cache_write_input_tokens |
| reasoning_tokens | reasoning_output_tokens |
| total_tokens | total_tokens |

The usage attribution fields are `Tellem::Record::Kinds::USAGE_ATTRIBUTION`; the
ledger fields are `Tellem::Record::Kinds::USAGE_LEDGER`.

## Codex child threads

A Codex session's child threads are found recursively from the main rollout, by
two signals:

- The parent names the child: a `spawn_agent` output carrying the child's id,
  or an `event_msg` `item_completed` item of type `SubAgentActivity` with
  `agent_thread_id` (Codex 0.163). The child is linked to that spawn call.
- The child names the parent: a rollout whose `session_meta` `parent_thread_id`
  (or `source.subagent.thread_spawn.parent_thread_id`) is the thread's id. The
  harness port scans the rollout date directories from the session's first day
  to its last activity day, reading only each rollout's first line. A child
  found only this way has evidence `parent_thread_id`, no spawn site, and the
  agent_type of its `source.subagent.other` (for example `guardian`).

Each thread is read once, so its usage is counted once.

## Imports

`tellem import native|specstory|ledger` writes through the same record writers
and adds these records and fields:

- A native import runs the deriver's pass over the imported transcripts and
  appends, for every agent without raw records, a `lifecycle` record with
  `state` `stopped` at that agent's last transcript line, `source_id`
  `import:<through>`, and two extra body fields: `evidence` `import` and
  `through`, the time of the session's last imported native line. A session
  with such a record is imported up to the largest `through`. Transcript
  activity at or before that time raises no hook-expectation gap
  (`unmatched_tool_call`, `missing_subagent_start`) and records no
  transcript-evidenced start. Activity after it, as when a resumed session
  brings raw hook records, follows the normal rules.
- A SpecStory import writes a `session` record, the home `place` and
  `repository`, and one `transcript` record per file with `source`
  `specstory_lossy`, `native_inode` and `native_size` of the SpecStory file,
  and `final` true. The Markdown is a byte copy under the SpecStory file name.
  No usage is written. A subagent file named
  `<time>-<claude|codex>-<session id or prefix>--subagent-<agent id>.md` with no
  main file of the same base belongs to the session its name gives; a prefix
  resolves to the one main file in the same directory whose session id starts
  with it, else to the one native transcript that does. When the import of a
  session holds no main file, it adds a `gap` with cause
  `missing_main_transcript`, location `specstory/main`, and detail
  `subagent_files`. A second file for the same agent with identical bytes is
  skipped as `duplicate_agent_file`.
- A native `transcript` record for an agent that has an unsuperseded
  `specstory_lossy` record carries that record's id in `supersedes`, so every
  file report drops the lossy record, the mirror stores the link in
  `observations.supersedes`, and the lossy Markdown copy is removed when its name
  differs from the native one.
- A ledger import writes a `session` record, places, and one `usage` record per
  row. Besides the usage fields, the body carries `source` `ledger`,
  `ledger_row` (the row object as written), and `provider_inferred` true for a
  row without `provider` whose `model` starts with `claude-`. A row without
  `provider` and without such a model is skipped as `unknown_model`; a row whose
  provider is neither `claude` nor `codex` is skipped as `unknown_provider`.
  `request_key` is the row's `id`, else `ledger:` and the first 32 hex of the
  sha256 of the row's JSON. The TOKENS view renders every field `ledger_row`
  carries exactly as written, and fills only the fields it lacks. Rows of one
  ledger that share an `id` collapse to the earliest by [timestamp,
  session_key, line]; the plan's `ledgers` list gives each ledger's `rows`,
  `duplicate_ids` (ids that had more than one row), and `rows_collapsed`.

## TOKENS view

`views/TOKENS.jsonl` writes one row per provider request in the incumbent
ledger's field order. Usage records keep their own `ts` for every report; the
view reads the ledger fields instead:

- The incumbent files a main transcript's request from its first line and a
  subagent transcript's request from its last line, so `timestamp` and `uuid`
  come from `first_line_*` in the usage body for the main agent, and for a
  subagent from the `usage_line` with the latest `line_at` for the request.
  `timestamp` is cut to whole seconds with `Z`.
- `inference_geo` and `speed` come from the Claude usage object.
- `permission_mode` is that of the latest raw record at or before the request
  that carries one; a Codex request takes its turn's `approval_policy` when the
  rollout records it.
- `billing` is that of the latest `session_start` raw record at or before the
  request, else `unknown`; `billing_plan` is always empty.
- A Claude subagent's last request is left out while its line has no
  `stop_reason` and the subagent has not stopped, as the incumbent leaves out a
  message still streaming.
- Codex rows follow the incumbent's Codex branch: `input_tokens` excludes cached
  and cache-write tokens, `uuid` is the turn id, `cwd` is the turn's cwd, `service_tier` and
  `inference_geo` are empty, and the `token_count` fallback's `id` is
  `codex:<session>:<cumulative total_tokens>`.
- A Claude row's `cwd` is the request's standing place, else its agent's home.
  When no hook record set the home, it is the first `cwd` the native transcript
  records on any line, so an imported session without tool calls keeps it.
- Rows are ordered by each request's first line.

## Bounds

| Bound | Value |
| --- | --- |
| record_bytes | 8388608 |
| nesting_depth | 64 |
| tool_payload_bytes | 262144 |
| raw_line_bytes | 65536 |

## Versioning

Record formats are versioned by schema name; a new major format is a new schema
name read alongside the old. Mirror schemas are versioned SQL files per backend,
`db/<backend>/NNN_<change>.sql`, applied in order and recorded in `tellem_meta`.
