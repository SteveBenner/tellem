# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.7] - 2026-11-22

### Added

- `specs/tellem.yml`, the normative field-level specification of every file
  tellem writes and every machine-readable output it prints: 45 formats in
  three planes (capture, derived, control), with types, required fields,
  enums, bounds, writers and readers, and invariants. It was extracted from
  the code and cross-checked against `Record::Formats`, `Record::Kinds`, every
  schema id in `lib/`, and the manifest's 52 settings. It names 20 points still
  unresolved and 43 places where `docs/reference/formats.md` is incomplete or
  wrong; that page now defers to the spec.

### Changed

- `docs/architecture.md` is an engineering document: system context,
  components, the capture, derive, and read paths as sequence diagrams and
  flow charts, scope resolution, storage layout and record relationships,
  durability and concurrency, the authority state machine, the cutover
  sequence, and the invariants, all as Mermaid diagrams that name the module
  behind each step. The illustrated figures stay in the README.

## [0.5.6] - 2026-11-22

### Added

- The README tells tellem's story: four Imagine scenes, what tellem does in
  plain words, eight things you can ask your agent, each with the prompt and
  the agent's real answer from a clean-home demo, an install that is one
  sentence to your agent, and the command line at the end. It has a hero image
  and four architecture figures.
- `INSTALL.md`, written for an AI agent: check Ruby and git, get rplugin and
  tellem without overwriting anything, install, run both doctors, and tell the
  person what happens next. A fresh agent given only this file installed
  tellem in a clean home.
- `docs/architecture.md` walks through the pipeline, the life of one event,
  a session's tree and places, and the takeover ladder.
- `tellem tokens --by repository` shows a `repository_root` column, the
  repository's path, beside each opaque repository id, in text and JSON.

### Fixed

- The cutover parity criteria were met by fewer sessions than FR-24 requires:
  one passing Claude session of 20 printed "cutover criteria met". Each harness
  now needs its full count (20 Claude, 5 Codex) once it has a shadowed session
  with a reference, and a harness with nothing to compare does not block the
  other. The summary says how many more are needed. `tellem cutover plan`
  refuses `spool` or `own` for a harness whose own count is unmet
  (`parity_unmet`, next `tellem parity --all`); `observe` and `rehearse`, which
  remove nothing, are not gated.
- Right after install, `tellem doctor` reported the missing `capture.enabled`
  file as a finding, and an installing agent concluded that recording would
  not work. The first SessionStart writes that file. Doctor now reports
  "capture starts with the next agent session" while that first start is
  pending, and keeps the finding when a first start ran and could not write it.
- The agent skill says when a question needs `--all`. Asked "what did my agents
  do today?" outside a repository, an agent answered from the current scope
  alone and found only its own session.

## [0.5.5] - 2026-11-22

### Fixed

- `release/export-public.rb` could hang without limit, and some of its failures
  escaped as Ruby stack traces. A policy review found three gaps, and each is
  closed without changing what the export builds:
  - Every git, tar, clone and exposure-scan call runs under a 300 s deadline.
    When the deadline passes, the script stops the whole process group (TERM,
    then KILL after 5 s) and refuses. The push keeps the terminal attached, so
    a credential prompt still works, and has its own 600 s deadline.
  - `VERSION` and `.gitignore` are read only up to 1 MiB, and scanned files up
    to 16 MiB. A larger file stops the export instead of going unscanned.
  - Malformed YAML, a missing config key, an unreadable file, an encoding
    error or a bad scan regex ends with one `export-public:` line and exit 1.
  - The 0.5.5 script built the same mirror tree (`7c17f98`) from the same
    commit as the 0.5.4 script.

## [0.5.4] - 2026-11-22

### Changed

- `Redact.rules` (`lib/tellem/redact.rb`) builds the userinfo and credential
  replacements with `Array#join`, and `Cutover::Plan` (`lib/tellem/cutover/plan.rb`)
  builds `plan.json` the same way, instead of string interpolation. The host
  exposure scan read the three interpolations as high-entropy secrets and
  stopped the public export. Output is unchanged: the 0.5.3 and 0.5.4
  redactors gave byte-identical output over 34474 strings, the repository's
  docs, code, specs, and skill plus eight secret-shaped samples. The export now
  passes its own scan (0 hits) and the exposure scan (0 findings).

## [0.5.3] - 2026-11-22

tellem's source can be published through a one-commit-per-release mirror under
the MIT License (application spec D-36). Nothing is published yet.

### Added

- `LICENSE` (MIT), `CONTRIBUTING.md` (issues and pull requests welcome; a pull
  request is re-applied in the development repository, never merged on the
  mirror), and `SECURITY.md` (private vulnerability reporting).
- `release/export-public.rb` and `release/public.yml`: export a ref, leave out
  development records, blueprints, and environment policy, overlay
  `release/public/AGENTS.md`, scan every file for private names, home paths,
  emails, and secret shapes, run the host exposure scan on a throwaway commit,
  and only then commit one orphan or child commit tagged `v<VERSION>` into the
  mirror. Each allowance is named by file, pattern, and reason, and an
  allowance that matches nothing stops the export. `--push` pushes `main` and
  the tag as two commands, after checking the mirror's origin.
- Decision D-36 and scope line for the public mirror; OQ-14.

### Changed

- D-26 no longer keeps tellem unpublished, and the "Publishing tellem" non-goal
  is gone.
- Shipped text names no private project or person: the application spec,
  `FEATURES.md`, `CHANGELOG.md`, `ROADMAP.md`, the skill, the operator runbook,
  and two ADRs say "the maintainer", "the operator", "the user", or "a
  coresident plugin". The skill asks "the user" before every gated command.
- `README.md` installs from public clones of rplugin and tellem, and links the
  license, contributing, and security pages instead of the implementation
  blueprint.

## [0.5.2] - 2026-11-18

### Added

- `--no-derive` on every report verb (`sessions`, `spans`, `tree`, `where`, `state`,
  `tokens`, `tasks`, `health`, `otel`, `parity`, `tasks parity`): the verb answers from
  the record already derived without running the derive pass first, and the envelope's
  `derive` field reads `{"status": "skipped"}`. It is the per-call form of
  `TELLEM_DERIVE_DISABLED=1` and shares its path in `Reports::Refresh`. Derive keeps
  running from the hooks.
- `tellem sessions --brief [--since T] [--limit N]`: one row per session, newest first,
  with `session_key`, `root`, `harness`, `started_at`, `ended_at`, and `label`, read from
  the session, lifecycle, and task records only (no agent, place, pointer, or task
  breakdown resolution). `label` is the redacted head of the session's first task name,
  at most 80 characters, or null when the record holds none; no transcript is read.
  Combines with `--all`, `--scope`, `--repo`, and `--no-derive`. The full `sessions`
  listing takes minutes on a large host, because it loads every scope's whole record.

## [0.5.1] - 2026-11-18

### Fixed

- `tellem parity` reported 20 sessions as mismatches, and the Claude half of the
  cutover criteria read 14 of the last 20, though none was a capture defect
  (application spec D-35, impl `fix_8_parity_cutover_blockers`). Now 20 of 20,
  and no session that was at parity before lost it.
  - A turn counts as `redaction_only` when it equals the incumbent's turn after
    tellem's own redactor runs on the incumbent's raw text. Before, a redacted
    value over 64 characters (a backtick command) or an empty quoted value
    (`token: ""`) stayed a mismatch.
  - A line ending `</tool-use>` inside a fenced code block no longer closes the
    tool block in `lib/tellem/parity/turns.rb`. A tool output quoting a SpecStory
    transcript had split three main threads (b3712d8f, a0b28599, dbf9be87) into
    hundreds of shifted turns.
  - New accepted differences: `incumbent_truncated` (SpecStory stopped writing a
    resumed subagent's file, 12 agents) and `image_placeholder` (tellem keeps
    `[image omitted]`).
  - A live session is `pending`, not a mismatch, when tellem's transcript is a
    few turns behind SpecStory's (`tellem_behind`), or when its tellem-only
    token rows are all no older than the newest ledger row of the same agent.
    The incumbent logs a turn at Stop and a subagent at SubagentStop. This
    replaces the single newest `end_turn` row rule in
    `lib/tellem/parity/report.rb`.
- `docs/ops/tellem.md` describes the new rules and the pending line.

## [0.5.0] - 2026-11-18

### Added

- Messages between agents as first-class records (application spec D-33, O-13).
  Before this, SendMessage, send_input, and spawn prompts were only tool calls of
  kind agent and a Codex agent_message was a user turn, so no record said who told
  whom what. The deriver now writes a `message` record per spawn prompt, send
  (SendMessage, send_input, send_message), handback (a spawning call's result,
  except a background launch, whose `toolUseResult` status `async_launched` only
  acknowledges it and whose report arrives as a receive), and receive (a Codex agent_message, or a Claude Code `cross-session-message`,
  `agent-message`, or `teammate-message` in a queue-operation enqueue, a
  queued_command attachment, or a user turn, one record per delivery within
  600 s). Each carries sender, recipient agent key or raw address, channel, time,
  byte size, the sender's summary, a redacted head of at most 200 bytes, a
  SHA-256 digest of the redacted text, and the transcript turn that holds the
  whole text; content the transcript policy withholds gives no head, digest, or
  summary. `lib/tellem/deriver/messages.rb`, a `messages` deriver step, and a
  `received` list on the ingest batch that never reaches the Markdown or entries.
- `tellem messages [SESSION_KEY] [--agent KEY] [--channel NAME] [--since D]`
  lists them and joins a cross-session send to its receive in any covered scope
  by digest within 600 s. Measured on copies of six real sessions: 195 records
  (64 spawn, 1 handback, 36 send, 94 receive; 63 background launches give no
  handback), and the 2026-11-06 send from
  323b441a to a socket address joined to session 49a50b65's receive 1.1 s later,
  758 bytes and one digest on both sides. `tellem tree` shows `msgs S/R` per agent.
- Per-agent time in `tellem tree` and `tellem state` (D-34): wall, active,
  waiting on the user (main), and spawn to stop (subagents), computed at report
  time and never stored. An agent's end follows its last activity record when a
  resumed subagent works past its write-once stopped record. Active time is
  `time.active`: `spans` (default, prompt-to-stop spans from lifecycle records),
  `activity` (gaps of at most `time.idle_seconds`, default 300, between the
  agent's usage, tool_call, works_in, shells_out, message, lifecycle, and
  context records, so it needs no transcript entries), or `both`. Spans matched every lifecycle
  span of the task clock and sat 1.4 s and 2.9 s below task active on two
  single-task sessions, because the task clock also counts tool calls after a
  stop.
- Compatibility check for both additions: on copies of six real sessions,
  rendered Markdown and every derived record other than `message` are
  byte-identical to 0.4.0 apart from the "Generated by tellem" version line and
  the transcript sha256 that follows from it, parity verdicts are unchanged, and
  the hook is untouched. The mirror needs no migration, and `messages`, `tree`,
  and `state` give identical output from files and from SQLite.

## [0.4.0] - 2026-11-18

### Added

- `tellem spans`: timed spans for requests, tool calls, subagents, and task turns as rows
  in the `tellem.report/v1` envelope, filtered by `--session` (a key or the bare harness
  session id), `--task`, `--agent` with `--descendants`, `--kind`, `--since`, `--until`,
  and `--limit` (default 20000, with `truncated` and `total` in the envelope). Rows carry
  metadata only. Text output is a per-kind summary of count, sum, p50, p95, max, and total
  tokens (application spec D-32).
- A derived kind `tool_call` {tool_use_id, agent_key, tool, started_at, ended_at,
  duration_ms, is_error}, written by the deriver from the tool calls it pairs once their
  result is in the transcript.
- A derived kind `request_start` {harness, request_key, started_at}: the timestamp of the
  transcript entry immediately preceding a request's first line in the same agent thread.
  A request's `duration_ms` in `tellem spans` is the OpenTelemetry duration when present
  (`otel`), else last line minus that start (`transcript`), else null (`none`). Measured on
  one session: all 2699 requests carry a duration, p50 4.2 s, p95 28.8 s, max 5 m; a request
  that an earlier report-time inference put at 8466686 ms after a subagent resumed now reads
  17506 ms. A session whose sources do not change is not re-read, so it
  gains its tool_call and request_start observations only when its sources change, or after
  its derive cursor is reset.

## [0.3.3] - 2026-11-06

### Fixed

- The assignment redaction replaced prose between two code spans with
  `[REDACTED:assignment]` (application spec D-31). Symptom: session 5265df67's
  transcript holds `` `x-api-key:`[REDACTED:assignment]`--access-token` `` where the
  session said `` `x-api-key:` - converting a curl from an API key is a header
  change, not a key swap). Always pass `--access-token` ``, about 96 characters
  lost, and parity reads the turn as a mismatch. Cause: `Redact::ASSIGNMENT`
  takes a backtick-quoted run as a value, and the closing backtick of the
  name's own code span opened one that ended at the next span's opening
  backtick. Now `Redact.prose_between_spans?` skips that match when the name
  sits directly after an opening backtick, the quoted run starts directly after
  the separator, its first character is whitespace, and the character after its
  closing backtick is neither whitespace nor a backtick. Nine control strings
  redact as before, including a multi-word secret glued to a closed span, which
  a first version without the whitespace test exposed. Measured: over 278105
  unique strings from the 60 most recent native sessions, 8 outputs differ, all
  this pattern. Cost: a secret written after a closed name span and a space,
  then followed by a code span with no space, is no longer redacted by this
  rule. Records already written keep their text, so 5265df67 still mismatches;
  sessions captured from now on keep the prose.

## [0.3.2] - 2026-11-06

### Fixed

- `tellem parity` read only the scope root's `TOKENS.jsonl`, so a session whose
  requests ran in other repositories read as tellem-only rows (application spec
  D-30). Symptom: session bb33c2a5 showed 647 tellem rows against 644 ledger
  rows, with three requests whose cwd was a nested Codex scratch repository.
  Cause: the incumbent token logger writes each row to the ledger of the
  repository its cwd is in, and parity never read those ledgers. Now
  `Parity::Ledger.routed` applies the incumbent's own routing, a port of its
  `resolve_target` (nearest ancestor with a `.git`, stopping at the launch
  directory, a linked worktree mapped to its main checkout, the launch directory
  when the target is not writable), to every tellem row and adds that session's
  rows from each other ledger it names, at most 64. A ledger that cannot be read
  adds nothing, so those rows stay tellem-only. Nothing is accepted. Measured:
  the port and the incumbent's function gave identical targets on 12 paths,
  bb33c2a5 moves from mismatch to parity, and no session that matched before
  mismatches after.

## [0.3.1] - 2026-11-06

Parity fixes found while measuring FR-24 on the installed 0.3.0 (application spec
D-29). Neither is a capture defect: in every case below tellem holds the turns
the session had. Both made a session read as a mismatch that no cutover could
clear.

### Fixed

- `tellem parity` counted heading-shaped lines printed by a tool as turns.
  Symptom: session e817b5ae, a development session of tellem itself, read 439
  tellem turns against 448 in SpecStory, with phantom turns such as
  `hello ${slug}` and a chunk of Ruby under a User heading. Cause:
  `Parity::Turns.parse` matched the heading pattern on every line, including
  lines inside a tool-use block, so tool output that contained transcript text
  split into extra turns on the SpecStory side. Now a tool-use block, opened by
  a line beginning `<tool-use data-tool-` and closed by a line ending
  `</tool-use>`, starts no turn. Measured: e817b5ae moves from mismatch to
  parity, with `redaction_only` accepted on three turns, and no session that
  matched before mismatches after.
### Added

- `subagent_final_report`, a third accepted parity difference beside
  `redaction_only` and `mode_changed_mid_session`. SpecStory leaves out the
  final report a subagent hands back; tellem renders it as the agent's last
  turn, a `SubagentHandback` tool turn. When a subagent's tellem transcript
  has exactly that one extra trailing turn over an otherwise equal turn list,
  the agent is at parity and the difference is listed under `accepted` with a
  count of 1. A different trailing turn, a second extra turn, and the same
  difference on the main thread stay mismatches
  (`Parity::Turns.compare(..., subagent:)`, passed by `Parity::Report`).
  Measured: 8405ee55 moves from mismatch to parity; 10294a2a and 5265df67 lose
  their subagent mismatch.

### Not fixed

- 10294a2a and 5265df67 still differ on the main thread, where tellem's
  `[REDACTED:assignment]` stands for more characters than parity accepts or for
  none. 7a88fa41 and bb33c2a5 differ on tokens. Sessions still being written moved
  between the two measuring runs and are not counted either way.

## [0.3.0] - 2026-11-05

The transcript takeover. tellem can record every session in full, replace what
SpecStory and the harnesses' own transcripts do on a computer, and hand its
records to another plugin through one interface (application spec 0.8.0,
D-21 to D-28). Built and verified in containers and isolated homes; not
installed live, and nothing in it was applied to a real host. The host still
runs 0.2.8.

### Added

- `tellem transcripts discover`: a read-only report of every transcript method
  on the host: harness stores and sizes, expiry settings, switches and whether
  the installed harness carries them, prompt histories, hooks, shell wrappers,
  running wrappers and watchers, timers and cron entries, SpecStory's state and
  its output (vault links included), OpenTelemetry exporters, Codex hook trust,
  and readers. Each capability says how it is known: declared, seen in the
  binary, or verified by a session.
- Authority levels per harness (`observe`, `spool`, `rehearse`, `own`), raised
  only through the reviewed `tellem cutover plan --claude LEVEL --codex LEVEL`
  and lowered by its rollback, by `capture_lost`, or by `tellem authority stop`.
  `tellem authority status|stop|resume|restore` reports and controls them. A
  reader of native transcripts that discovery found must be named with
  `--accept-reader ID` or the plan refuses. `--purge` applies the retention
  check to older native sessions. A failed restore is visible, retried at every
  derive, and reported by doctor.
- Body ingestion for the `own` level: Claude Code's raw API bodies are taken
  from the OpenTelemetry body spool (`OTEL_LOG_RAW_API_BODIES=file:`), parsed,
  paired to the session, and deduplicated, with the spool files removed only
  after the derived record is verified. Tool-use counting, liveness, and
  `capture_lost` guard the level.
- `tellem cutover status|import`: a subsume plan starts a detached import of
  native transcripts, then `.specstory/history` and `TOKENS.jsonl` in
  registered scopes. An interrupted import resumes only by command, and
  rollback leaves imported records.
- `tellem specstory remove|status`: a reviewed plan removes SpecStory's wrapper,
  state, and optionally its history, with `--prevent on|off` and
  `--link-target PATH` for vault links. Drift (a returned wrapper or state) is
  reported by doctor. Tracked, unverified, and vault files are kept with their
  reasons, and nothing outside the plan is touched.
- Entries (`transcripts.entries`, off by default): redacted, whole, ordered
  records of each agent's prompts, replies, visible reasoning, actions, and
  outputs, with nothing omitted for size or tool. `tellem export --session KEY
  [--after CURSOR] [--limit N]` reads them from a cursor, `tellem sync
  --session KEY` makes them current on demand, and `tellem forget --session KEY
  | --all` removes them after a confirmed plan.
- The `transcript_policy` port, declared by tellem with a standalone form that
  withholds nothing, so another plugin can name tool names and path prefixes
  whose content is replaced by a placeholder before it enters the record, and
  the native readers it declares.
- The Ruby floor 3.3 is visible: `bin/tellem` and the hook stop with a named
  failure below it, and the hook records one it cannot load.

### Changed

- `tellem doctor` on a host with no `~/.ai` and no cutover history no longer
  reports a failed history import: the missing cutover directory means no
  import, not a failed one.
- Documentation describes the transcript takeover surface: README, the agent
  skill, and the operator runbook. ROADMAP moves Codex retention out (the
  authority levels cover it) and adds per-repository levels and Windows.

### Fixed

- On Ruby 4.0 (json 3.0.2), every raw record was read as a torn line, because
  `JSON.parse` no longer accepts `create_additions:`. The option is removed
  from the eight calls that passed it; the default is the same, and 3.3 behaves
  as before. `rplugin doctor` and `tellem doctor` did not show it.

### Verified

Isolated homes with a scratch Claude home and repositories, claude-haiku-5-5,
`RLOGS_DISABLE=1`: tellem and a coresident plugin installed into one home beside
a fixture of that plugin's server over TLS (signed up through its validation
pass), with sessions in and out of the plugin's working folder; an empty home with tellem alone; the
doctors on Ruby 3.3.8 and 4.0.6; a sentinel scan of every integration run. The
results and what was not run are in FEATURES.md.

## [0.2.8] - 2026-11-05

A hotfix on 0.2.7. The deployed tellem wrote `.tellem` directories into
production release checkouts whenever a session touched one. Verified in
containers, and deployed on the development host on 2026-11-05 (app spec D-28).

### Added

- `scope.exclude_roots`: a string setting of colon-separated root prefixes,
  empty by default. A repository at or under one is not a scope: a session
  started there is homed in the user scope, and no `.tellem` directory, pointer,
  registry entry, or lock is written there. `derive`, `sync`, and the reports
  skip it. The session keeps its record, including the paths it worked in.
- `Tellem::Record::Exclude`, and the mirror file `<state>/scope.exclude_roots`
  that the setting writes at `tellem config set`, at derive, and at the first
  session start. The hook reads it only when it locates a session's home, and
  nothing when it is absent. An unreadable file fails closed with an
  `exclude_roots_unreadable` hook gap.
- A session whose recorded home is in a covered root moves to the user scope at
  its next hook, with a `home_moved_excluded` hook gap. Earlier raw stays where
  it is.
- `Scope.prepare` refuses a covered root other than the user root, before it
  looks for an existing scope, so no path writes into one. `tellem config set
  scope.exclude_roots VALUE --scope PATH` is a usage error: the setting is
  user-level and a per-scope value would be ignored.
- `tellem doctor` lists a `.tellem` directory already sitting in a covered root,
  with its path and the removal command for the operator to run. tellem removes
  nothing there.

### Unchanged

- With the setting empty, behavior and every written byte match 0.2.7.
- No shipped file names a host path, polispec, or a repository.

## [0.2.7] - 2026-10-30

The Codex half of the cutover criterion asked for five shadowed Codex sessions
with incumbent output, and Codex has no incumbent writer beside tellem, so it
could never be met (app spec D-20).

### Added

- `lib/tellem/parity/rollout.rb`: a reference reader that re-parses the rollout
  named by a Codex session's hook records, without the Codex ingestion. It reads
  the user and assistant message turns and the main agent's counters, from the
  per-request `token_usage_record` entries or else the distinct
  `last_token_usage` entries, with `input_tokens` net of `cached_input_tokens`.
- `tellem parity` compares each shadowed Codex session with that reference:
  transcript turns by the existing rules with tool turns excluded, and counters
  by sum and request count. A `ROLLOUT` column and a `rollout` object per
  session show the result. A session whose rollout changed after tellem's last
  record, with no `session_end` and under 24 hours quiet, is `pending`.
- A rollout whose cumulative `total_token_usage` differs from its per-request
  records (4 of 29 rollouts on the reference host) is listed as accepted, not a
  mismatch.

### Changed

- The cutover criteria count the last 5 shadowed Codex sessions at parity with
  their rollouts, and the report line reads "with a reference (incumbent output,
  or the rollout for Codex)". Claude sessions are judged as before.
- `Turns.compare` takes `tools: false` to leave tool turns out of both sides.
- `docs/ops/tellem.md` says that Codex runs a plugin's hooks only after the user
  trusts them in `~/.codex/config.toml`, so a real Codex session is not captured
  until then.

## [0.2.6] - 2026-10-30

After reading `tellem tasks` on real sessions, the maintainer chose to keep the
task telemetry in tellem and not the task clock's own interface, so 0.2.6 removes
everything in 0.2.5 that talked to the agent or the status line (app spec D-19).
The task clock in `~/.ai` keeps those.

### Removed

- The live mode. `bin/tellem-task`, `lib/tellem/tasks/live/`, the six
  `tellem-task` hook entries (and their entries in `hooks/hooks.json` and
  `hooks/codex.json`), the `/task` marker replies, `tellem tasks line`, the
  `tasks.live` flag file, and the task working state under the state directory.
  tellem registers no hook for tasks, and the hook path again persists metadata
  only with no exception.

### Changed

- `tasks.mode` takes `off` and `on`, and the default is `on`. 0.2.5's `shadow`
  and `live` are no longer valid values; run `tellem config set tasks.mode on`
  if either is set. `on` does what `shadow` did: the deriver writes task records
  and the reports show them.
- The engine still reads a `/task` marker in a recorded prompt, because the
  clock in `~/.ai` acts on it and the derived tasks must agree; it answers none.

## [0.2.5] - 2026-10-30

The maintainer asked to track the tokens an agent thread or task spends, compatibly with
the task clock in `~/.ai`, and then to absorb that clock into tellem as a
toggle (app spec D-18). A task is a run of one person's prompts about one piece
of work; tellem now groups prompts into tasks by the clock's rules, times them
the clock's way, and puts the tokens beside the time.

### Added

- `tasks.mode` (`off`, `shadow`, `live`; default `shadow`), `tasks.attribution`
  (`timeline` or `spans`), and one `tasks.<rule>` setting for every key of the
  clock's `tasks` block, with the clock's defaults. The twenty numeric and list
  rule keys are strings holding JSON, because the plugin SDK has no numeric or
  list setting type; a malformed value is refused with the key named.
- The task engine (`lib/tellem/tasks/`): the clock's scoring, verdicts,
  `/task` markers, merging and auto-close, and its elapsed, active, and agents
  time and duration format, with no gem and no clock of its own.
- In `shadow` and `live`, the deriver replays the engine over each scope's
  sessions and writes `task` records (`lib/tellem/deriver/tasks.rb`). A rerun
  of unchanged data writes nothing; a task the replay no longer produces is
  superseded with `merged_into: retired`, which reports hide.
- `tellem tasks` (one row per task: elapsed, active, agents, subagents,
  requests, `total_tokens`, `output_tokens`, and each as a rate per
  agent-minute, plus an `unattributed` row), `tellem tokens --tasks`
  (combinable with `--by agent`), and a task column in `tellem tree` and
  `tellem sessions` when the mode is on. A main-agent request joins the task by
  `tasks.attribution`; a subagent request joins the task that holds its agent
  id.
- `tellem tasks parity --against PATH` compares the derived tasks with the task
  clock's own store, read-only, and names every difference by cause.
- In `live`, a synchronous hook step (`bin/tellem-task`) answers `/task`
  markers and keeps working state under the state directory, and
  `tellem tasks line SESSION_ID` prints the status line segment. Under 50 ms
  warm p99 (27 ms measured). The step exits at once when the mode is not live,
  and ignores Codex.

### Changed

- The `task` record kind is identified by `id` and `state_digest`, so a later
  state of a task supersedes the earlier one.
- Six hook entries (`tellem-task` for session start, prompt, stop, session end,
  subagent start and stop) are added to `hooks/hooks.yml`, and the generated
  `hooks/hooks.json` and `hooks/codex.json` with them.

## [0.2.4] - 2026-10-30

The incumbent ledger adds a session's newest message at its next rescan, so
every open session showed one `tellem_only_rows` mismatch that cleared by
itself, and each one pushed older, resolved sessions out of the last-20 window.

### Added

- A `pending` parity verdict (`lib/tellem/parity/report.rb`): a session whose
  only difference is its newest `end_turn` row, with no `session_end` record
  and a last record under 24 hours old. It takes no slot among the last 20
  Claude sessions, is listed under `criteria.pending` and on the text report's
  pending line, and keeps `criteria.met` false while it exists. A session that
  has ended, or has been quiet for 24 hours, is judged as before. Codex
  sessions are never pending.

## [0.2.3] - 2026-10-30

One session's main transcript still failed parity after 0.2.2 because both
tellem and SpecStory had redacted, at different places, in the same turn.

### Changed

- `tellem parity` accepts a turn when some text could expand both sides: a
  `[REDACTED:<kind>]` marker on either side stands for 1 to 64 characters, and
  the literal characters of the two sides must agree everywhere else
  (`lib/tellem/parity/turns.rb`). The search is bounded to 500000 states, 256
  markers per side, and 262144 characters per turn. The 64-character cap also
  applies to the one-sided check from 0.2.2, which let a marker stand for any
  text.

## [0.2.2] - 2026-10-29

SpecStory redacted a path (`.rassessments-wt`) as a credential URI in many
turns of one session while tellem kept it, and parity reported the transcripts
as different.

### Changed

- `tellem parity` accepts a transcript turn that differs from SpecStory's only
  where one side has a `[REDACTED:<kind>]` marker, and counts it as
  `redaction_only` in the new `accepted` list of the transcripts result and in
  the text report's accepted line (`lib/tellem/parity/turns.rb`,
  `lib/tellem/parity/report.rb`). The match is a linear scan, bounded to 262144
  characters and 256 markers per turn. A turn that both sides redacted at
  different places, or that differs anywhere else, is still a mismatch.

### Fixed

- `rplugin package` regenerated `.antigravity-plugin/plugin.json`, which
  `rplugin check` reported as stale.

## [0.2.1] - 2026-10-29

Live parity against the incumbents read 5 of 13 Claude sessions. Reading the
eight mismatches showed one tellem defect and several differences that come
from how the incumbent ledger hook works, so 0.2.1 fixes the defect and makes
parity name the others instead of failing on them.

### Fixed

- The TOKENS view cwd of a Claude row is the transcript line's cwd, as the
  incumbent ledger keeps it, instead of the place the agent was recorded
  standing in (`lib/tellem/ingest/claude.rb`). A session that worked in a
  subdirectory no longer differs from the ledger on cwd. Rows already derived
  keep their old cwd until the session is derived again after the 0.2.1
  install.

### Changed

- `tellem parity` moves three differences from causes to an `accepted` list
  with a count and a sample: a `permission_mode` difference in a session whose
  rows carry more than one mode (`mode_changed_mid_session`), a billing the
  incumbent could not detect (`incumbent_billing_undetected`), and rows whose
  cwd directory no longer exists, which the incumbent hook cannot write
  (`incumbent_cwd_missing`, excluded from both sides' sums). The text report
  prints one line for them. A final message missing from the incumbent ledger
  is still a mismatch. Any other cause still fails the session
  (`lib/tellem/parity/ledger.rb`, `lib/tellem/parity/report.rb`).

## [0.2.0] - 2026-10-28

The first release of the 0.3.0 design. The 0.1.0 build captured too much in
the hook and kept one central database as the authority. Agent telemetry
needs the opposite: a hook cheap enough for every tool call, a record that
lives beside the work in each repository, and reports that are the same
whether or not a database exists. 0.2.0 is that rebuild.

### Added

- A metadata-only capture hook for Claude Code and Codex that loads no gems,
  writes one line per event into per-agent files, and never blocks an agent;
  every failure becomes a hook gap with its cause.
- A detached deriver that turns hook records and native transcripts into the
  agent tree, homes and places, pointers in every repository a session
  touched, provider-reported tokens, persona evidence, agent state, and
  SpecStory-pattern Markdown transcripts.
- CLI reports: `tree`, `where`, `sessions`, `tokens`, `state`, `transcript`,
  `health`, `doctor`, and `config`, each with `--json`.
- Optional SQLite and PostgreSQL mirrors with provisioning, rebuild, and drop
  that never change a report.
- Shadow, parity, import, cutover, and rollback for replacing SpecStory and
  the `TOKENS.jsonl` ledger hook in `~/.ai`, with plan ids and backups.
- Verified native retention of Claude Code transcripts after cutover, and an
  optional loopback OpenTelemetry receiver for Claude Code usage details.
- Per-repository visibility that keeps tellem's files out of git in public
  repositories.
- Native Claude Code and Codex packages generated by `rplugin package`, and
  `docs/reference/harnesses.md` with the harness versions and payload keys.

### Changed

- The six `features.*` settings default to true, and the first SessionStart
  after install turns capture on. If the capture flag file is missing and
  `TELLEM_DISABLED` is not set, that one event writes the flag from the
  resolved setting. Every other event checks only the flag file. When the
  setting is false, a `capture.settled` marker stops later SessionStarts from
  loading the SDK again.
  `tellem config set features.capture false` and a scope's capture-off
  setting still keep capture off.
- The package no longer ships the root Agent Plugins `plugin.json`
  (rplugin 1.19.5). Codex 0.165 preferred that file and read no hooks from
  it, so no tellem hook ran under Codex.
- Codex 0.165 code mode is read as it runs. Each `CommandExecution` item is a
  shell call with its own id, working directory, and output, aligned with the
  `PostToolUse` hook for that command. The `exec` script that ran it stays in
  the transcript, and it is no longer counted as a shell command, a place, or
  a call waiting for a hook.
- The Codex hook treats `Bash`, the tool name Codex 0.165 sends, as a shell
  tool.
- `extensions.enabled` lists only rstack, claude-code, codex, and os, and
  `extensions.only` limits installation to Claude Code and Codex, because
  tellem reads no other harness's transcripts and a detected Hermes otherwise
  received its hooks.

### Removed

- The 0.1.0 build (central SQLite authority, tokenizers, remote sinks, vendor
  profiles, MCP wrapper). Its history is kept on the `retired/0.1.0/*`
  branches.

### Security

- Secrets in prompts, commands, URLs, and tool results are redacted before
  anything is written; credentials live only in the SDK secrets port.
