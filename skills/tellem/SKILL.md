---
name: tellem
description: >
  Agent telemetry for Claude Code and Codex sessions: the agent tree, where each
  agent lived and worked, provider-reported tokens, persona evidence, state, and
  transcripts. Use it to answer which agents ran, where they worked, what they
  spent, and what they said, and to check tellem's own health with tellem doctor.
---

# tellem

tellem records what coding agents do. A hook appends metadata to `.tellem/`
in the repository the agent works in, and a deriver turns it into an agent
tree, places, tokens, persona evidence, state, and Markdown transcripts.

## Query with the CLI

Ask tellem through `tellem <command> --json`. Every command prints one
`tellem.report/v1` document with a `data` key, and every failure names its
next command.

| Question | Command |
| --- | --- |
| Which agents ran in a session, who spawned whom, how many messages each sent and received, and each one's wall, active, waiting, and spawn-to-stop time (`time.active`: `spans`, or `activity` and `both`, which need `transcripts.entries` on) | `tellem tree [SESSION]` |
| Messages between agents and sessions, with cross-session sends joined to their receives | `tellem messages [SESSION] [--agent KEY] [--channel NAME] [--since DURATION]` |
| Where an agent lived, stood, worked, and reached | `tellem where AGENT [--descendants]` |
| Which sessions touched a repository | `tellem sessions [--repo PATH]` |
| Provider-reported tokens | `tellem tokens [--by DIM[,DIM]] [--session S] [--since T] [--until T]` |
| An agent's lifecycle, context, and workspace over time, with its time figures | `tellem state AGENT [--since T]` |
| One agent's transcript | `tellem transcript show AGENT` |
| Timed spans of requests, tool calls, subagents, and task turns | `tellem spans [--session S] [--task T] [--agent A [--descendants]] [--kind request,tool_call,subagent,turn] [--since T] [--until T] [--limit N]` |
| Time and tokens per task | `tellem tasks`, `tellem tokens --tasks` (needs `tasks.mode` on, the default) |
| Capture health, gaps, and lag | `tellem health [--scope PATH]` |
| Whether tellem itself is working | `tellem doctor` |
| Settings and where each value comes from | `tellem config list [--scope PATH]` |
| Shadow progress and parity with SpecStory and the ledger | `tellem shadow status`, `tellem parity` |
| Every transcript method on this host (read-only) | `tellem transcripts discover` |
| Each harness's authority level and the stop switch | `tellem authority status` |
| Cutover and SpecStory removal state | `tellem cutover status`, `tellem specstory status` |
| Whole redacted entries of a session, for a plugin | `tellem export --session KEY [--after CURSOR] [--limit N]` (needs `transcripts.entries` on, off by default) |

Add `--scope PATH` to ask about another repository and `--all` to ask across
every registered scope. A question about the person's agents in general ("today",
"this week", "my agents", "across my repos") that names no repository needs
`--all`; without it the answer covers only the current directory's scope, which
outside a repository holds little more than this session.
Read-only commands bring the scope up to date first.
Add `--no-derive` to skip that derive pass and answer from the record already
derived, which is fast across many scopes; the envelope's `derive` then reads
`{"status": "skipped"}`, and the answer can lag the newest activity. The hooks
keep deriving.

`tellem sessions --brief [--since T] [--limit N]` lists one row per session, newest
first, in `data.sessions`: `session_key`, `root`, `harness`, `started_at`,
`ended_at`, and `label` (the redacted head, at most 80 characters, of the
session's first task name; null when the record holds none). It reads only
session-level records, no agents, places, pointers, or task breakdown, and
combines with `--all`, `--scope`, `--repo`, and `--no-derive`. Use
`tellem sessions --all --brief --no-derive --json` for a subject picker.

Tokens are only what the provider reported. Never estimate or add tokens
tellem did not report.

`tellem spans --json` returns one row per timed span in `data.rows`, with
`data.truncated` and `data.total`. It carries metadata only, never prompt,
tool input, tool output, or message text. Each row has `kind` (`request`,
`tool_call`, `subagent`, `turn`), `id`, `session_key`, `agent_key`,
`parent_agent_key`, `subagent_type`, `model`, `tool`, `task_id`, `start`,
`end`, `duration_ms`, `duration_source` (`otel`, `transcript`, `lifecycle`,
`task`, `none`), `open`, `is_error`, and the token counters `input_tokens`,
`output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, and
`total_tokens`. Counters are set on request rows, summed over the requests
inside on subagent and turn rows, and null on tool_call rows. A request's `duration_ms` is
the OpenTelemetry duration when present (`otel`), else the time from the
preceding transcript entry to the request's last line, recorded by tellem
(`transcript`), else null with `none`.
`--agent A --descendants` returns A and every agent spawned below it.

## Never edit tellem's files

Never create, edit, move, or delete anything under a `.tellem/` directory or
tellem's state directory. That includes raw records, derived records,
pointers, transcripts, views such as `TOKENS.jsonl`, `registry.jsonl`,
`capture.enabled`, and cutover plans. They are append-only evidence, and a
hand edit corrupts it silently. Change tellem only through its commands.

A repository is public unless its scope declares `visibility private`. In a
public repository tellem keeps `.tellem/` and `.specstory/history/` out of git
with ignore files of their own; in a private one only volatile files stay
ignored. tellem never runs `git add`, `git rm`, or `git commit`, and never
edits a repository's own `.gitignore` or `.git/info/exclude`.

## Ask the user first

Ask the user through the question tool, and wait for an explicit yes, before any
of these. State what the command changes and show the plan id when it has
one.

- Shadow install: `rplugin install tellem`, which installs the hooks into
  the harnesses and starts capture.
- Import apply: `tellem import native|specstory|ledger --confirm PLAN_ID`.
- Cutover apply: `tellem cutover apply --confirm PLAN_ID`, which edits
  `~/.ai`, and turns on native retention (and, with `--otel`, the
  OpenTelemetry receiver).
- Prune: `tellem prune ... --confirm PLAN_ID`, which removes records.
- Authority and SpecStory: `tellem cutover plan --claude LEVEL --codex LEVEL`
  then `tellem cutover apply --confirm PLAN_ID`, `tellem cutover import
  --confirm PLAN_ID`, `tellem specstory remove ... --confirm PLAN_ID`,
  `tellem authority stop|resume|restore`, and `tellem forget ... --confirm
  PLAN_ID`. Levels above `observe` and `--purge` can delete native
  transcripts; a reader of those files must be named with `--accept-reader`.

The dry runs that produce a plan id change nothing and need no approval:
`tellem import ...` and `tellem prune ...` without `--confirm`, and
`tellem cutover plan`, `tellem specstory remove` and `tellem forget` without
`--confirm`. Never pass `--confirm` with a plan id the user did not
approve, and plan again if the inputs changed.

A rollback (`tellem cutover rollback --confirm PLAN_ID`) is also the user's call;
ask the same way.

## When something looks wrong

Run `tellem doctor`. It reports each condition with the next command that
fixes it: the hook entrypoint's load time, whether capture is on, harness
versions, dangling registry scopes, the mirror backend, persona binding, the
rplugin version, the rendered Claude Code hooks, repository visibility, and the
OpenTelemetry receiver (not running, `port_in_use`, or `inherit_failed`).
Report what it says to the user; do not change settings, install, or uninstall on
your own.

tellem needs Ruby 3.3 or newer; below it the CLI and the hook name the Ruby
and stop.

To stop capture at once, set `TELLEM_DISABLED=1`; to stop authority levels
raising or removing anything, run `tellem authority stop` (the user's call). The operator runbook is
`docs/ops/tellem.md`.
