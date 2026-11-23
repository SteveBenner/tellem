# Harness versions and payloads

This page records the harness versions tellem 0.2.0 was built and verified
against, the hook payload keys tellem reads from each harness, and where each
harness keeps its native transcripts. When a harness changes a payload,
tellem records a `shape_unrecognized` gap naming the missing keys and the
harness version (FR-26, risk R-1). Update this page when that happens.

## Versions

| Component | Version | Where it was used |
| --- | --- | --- |
| Claude Code | 2.1.308 | Real sessions of waves 1 to 3: capture, subagent_stop, async hooks, post_tool_failure, OpenTelemetry, retention |
| Claude Code | 2.1.312 | slice_4_integration: isolated native install, `tellem doctor` |
| Codex CLI | 0.163 | Real Codex rollouts of wave 2 (sessions S22, S23, S24) against the incumbent ledger |
| Codex CLI | 0.165.0 | slice_4_integration: isolated native install; the hook run below |
| rplugin | 1.19.3 | Packaging, check, install, doctor (tellem needs 1.19.0 or newer) |
| rplugin extension catalogue | 2.9.0 | Hook rendering for Claude Code and Codex |

## Hook events

tellem declares its hooks once in `hooks/hooks.yml`. `rplugin package`
renders `hooks/hooks.json` for Claude Code and `hooks/codex.json` for Codex.

| tellem event | Claude Code | Codex |
| --- | --- | --- |
| `session_start` | `SessionStart` | `SessionStart` |
| `prompt_submit` | `UserPromptSubmit` | `UserPromptSubmit` |
| `post_tool` | `PostToolUse` | `PostToolUse` |
| `post_tool_failure` | `PostToolUseFailure` | none |
| `stop` | `Stop` | `Stop` |
| `session_end` | `SessionEnd` | none |
| `subagent_start` | `SubagentStart` | none |
| `subagent_stop` | `SubagentStop` | none |

Claude Code runs the six capture hooks with `async: true` and a 30 s timeout,
and `Stop` and `SessionEnd` synchronously at 2 s. Codex has no background
hooks, so every Codex hook runs synchronously. Codex has no session end and no
subagent events, so a Codex session is final by the deriver's end-of-transcript
rule and a Codex child thread is found from its rollout (ADR-5).

The two `tellem-otel ensure` hooks run on `SessionStart` and
`UserPromptSubmit` for both harnesses and exit at once while `otel.receiver`
is off.

## Payload keys tellem reads

Every event needs `session_id`, `hook_event_name`, `cwd`, and
`transcript_path`. tellem also reads:

| Event | Keys |
| --- | --- |
| `session_start` | `source`, `permission_mode` |
| `prompt_submit` | `permission_mode` (the prompt text is never stored) |
| `post_tool` | `tool_name`, `tool_input` (an object), `tool_use_id`; `tool_response` or, for Claude Code's `PostToolUseFailure`, `error` |
| `subagent_start` | `agent_id`, `agent_type` |
| `subagent_stop` | `agent_id`, `agent_type`, `agent_transcript_path` |

From `tool_input` it reads only `file_path`, `path`, `notebook_path`, `url`,
and the shell command under `command` or `cmd`. The shell tools are `Bash` for
Claude Code and `Bash`, `shell`, and `exec_command` for Codex.

### Claude Code

The keys above were observed on Claude Code 2.1.308 in real sessions of waves
1 to 3. `SubagentStop` carries `agent_id`, `agent_type`, and
`agent_transcript_path` beside the parent's `session_id` (rplugin 1.18.0).
`PostToolUseFailure` replaces `PostToolUse` when a tool call fails and carries
`error` instead of `tool_response` (rplugin 1.19.0). Claude Code 2.1.308 ends
every subagent with a `SubagentHandback` tool call and writes no
`server_tool_use` blocks.

### Codex

Codex 0.163 and later run a plugin's hooks only once the user has trusted
them in `~/.codex/config.toml`, and ignore hook overrides on the command line.
Codex 0.165 reads a plugin's hooks from `.codex-plugin/plugin.json`, but
prefers the root Agent Plugins `plugin.json` when one exists, and that file
carries no hooks. rplugin 1.19.5 therefore leaves the root file out of
tellem's package. With it, `codex app-server` `hooks/list` reports tellem's six
hooks with source `plugin`.

The keys were observed on Codex 0.165.0 in one
`codex exec --dangerously-bypass-hook-trust` run (session S2,
2026-10-28), in a scratch repository, against a scratch `CODEX_HOME` whose only
hooks are tellem's. Every one of its nine hook events had the required keys
(`shape` `known`, no missing keys):

| Event | Observed |
| --- | --- |
| `SessionStart` | `session_id`, `hook_event_name`, `cwd`, `transcript_path` (the rollout), `source` (`startup`), `permission_mode` (`bypassPermissions`) |
| `UserPromptSubmit` | `session_id`, `hook_event_name`, `cwd`, `transcript_path`, `permission_mode` |
| `PostToolUse` | the four common keys, `permission_mode`, `tool_name` (`Bash`), `tool_input` (an object), `tool_use_id` (`exec-<uuid>`), `tool_response` |
| `Stop` | `session_id`, `hook_event_name`, `cwd`, `transcript_path`, `permission_mode` |

The hook input type in the Codex 0.165.0 binary also names `turn_id`, `model`,
`agent_type`, and `trigger`. tellem does not read them, and the run did not
record whether they were present.

Codex 0.165 runs the model in code mode. The model calls one custom tool,
`exec`, whose input is a JavaScript script, for example
`text(await tools.exec_command({cmd: "ls -la"}))`. Each shell command that
script runs is an `item_completed` event of type `CommandExecution`, with its
own id (`exec-<uuid>`), `command` (an argv such as `/bin/bash -lc "ls -la"`),
`cwd` (a `file://` URL), `exit_code`, and `aggregated_output`. `PostToolUse`
fires once per command, not once per script, and its `tool_use_id` is the
command's id. tellem therefore:

- records each `CommandExecution` as an `exec_command` call with that id, its
  working directory, and its output, so the hook observation and the rollout
  align;
- keeps the `exec` script call in the transcript, but never counts it as a
  shell command, a place, or a call waiting for a hook.

When the model calls `exec_command` directly as a function call, the
`CommandExecution` id equals the call's `call_id`, and tellem reads the
function call only. On this host's rollouts, 16,314 of the 16,320 `exec`
inputs (0.163 and 0.164) are code-mode scripts. The other six call
`store(...)`, which is code mode as well.

Codex 0.166.0 reads the same way. Six `codex exec` runs, five sessions and one resume (2026-10-29, scratch
`CODEX_HOME`, `--dangerously-bypass-hook-trust`) captured 25 raw observations
with no hook gap, recorded every command as an `exec_command` call with the
`exec` script kept out of shells_out, and gave TOKENS rows equal to each
rollout's `total_token_usage`. Every session records one `unrecognized_item` gap
for the `additional_tools` item.

The rollout's `response_item` of type `additional_tools` (keys `id`, `role`,
`tools`, `type`) is new in 0.165. It lists the tools offered to the model, and
tellem records it as an `unrecognized_item` gap (R-1).

## Claude Code transcript entries tellem does not read

The Claude ingest rule knows the conversation entries (`user`, `assistant`)
and a fixed list of metadata entries. Any other top-level `type` is recorded
as an `unrecognized_entry` gap naming the type and its keys, and is never
guessed at (R-1). A survey of 2162 transcripts on the reference host (795 main
transcripts, Claude Code 2.1.289 to 2.1.312, 2026-10-14 to 2026-10-28) found
these:

| Entry type | Transcripts | Versions seen | Keys | Routine |
| --- | --- | --- | --- | --- |
| `cost-state` | 777 of 795 main transcripts | 2.1.289 to 2.1.312 | `hasUnknownModelCost`, `modelUsage`, `sessionId`, `startTime`, `totalAPIDuration`, `totalAPIDurationWithoutRetries`, `totalCostUSD`, `totalDuration`, `totalLinesAdded`, `totalLinesRemoved`, `totalToolDuration` | yes: about one gap per main session |
| `agent-setting` | 416 | 2.1.299 to 2.1.312 | `agentSetting`, `sessionId` | yes, in sessions started with an agent setting |
| `tools-used` | 87 | 2.1.311 to 2.1.312 | `sessionId`, `tools` | yes, since 2.1.311 |
| `frame-link` | 1 | 2.1.304 | `artifactCount`, `frameUrl`, `path`, `sessionId`, `timestamp`, `title` | no |
| `artifact-comment-monitor` | 1 | 2.1.304 | `artifacts`, `sessionId`, `v` | no |
| `artifact-autoreact-ledger` | 1 | 2.1.304 | `accountUuid`, `artifacts`, `sessionId`, `v` | no |
| `session-owner` | measured 2026-11-05: 4 of 5 scratch transcripts, 12 lines; 1 of 53 reference transcripts, 115 lines | 2.1.318 | `accountUuid`, `organizationUuid`, `sessionId` | yes on 2.1.318 |

`cost-state`, `tools-used`, and `session-owner` hold only metadata, so they joined the
metadata list and raise no gap: `tools` is a list of strings, and `cost-state` holds
session totals (`modelUsage`, `totalCostUSD`) that tellem does not read, since usage
comes from the assistant entries. The other types above still appear as
`unrecognized_entry` gaps. They carry no conversation or usage that tellem reports.

## Native transcripts

| Harness | Location | Read by |
| --- | --- | --- |
| Claude Code | `<claude home>/projects/<encoded cwd>/<session id>.jsonl`, with subagents in `<session id>/subagents/agent-<agent id>.jsonl` and `.meta.json` | the deriver, import, and retention |
| Codex | `<codex home>/sessions/YYYY/MM/DD/rollout-*.jsonl` | the deriver, import, and retention at `authority.codex` spool through `codex delete` |

`<claude home>` is `CLAUDE_CONFIG_DIR`, else `~/.claude`. `<codex home>` is
`CODEX_HOME`, else `~/.codex`.

## Claude Code request bodies

Measured on Claude Code 2.1.318 in interactive sessions with a subagent, a resumed
subagent, a tool failure, a large output, an interrupt, and a compaction.

`OTEL_LOG_RAW_API_BODIES=file:<dir>` writes `<uuid>.request.json`,
`<request_id>.response.json`, and `index.jsonl` with the keys `timestamp`,
`session_id`, `query_source`, `model`, `request_id`, `message_id`, `message_uuid`,
`request_file`, and `response_file`. The index timestamp is the end of the response.
The request file's mtime is when the request was sent.

**Conversation protocol.** A request carries `thread`. `{"type":"continue",
"previous_message_id":...}` holds only the new messages, and the id links it to the
request before it. `{"type":"create"}` starts a chain and holds the whole history
when a subagent resumes, after an interrupt, and after a compaction. Each request
counts once by request id, and blocks already seen in a history are not counted again.

**Query sources.** `repl_main_thread` and, in print mode, `sdk` are the main agent. `agent:custom:<name>` and
`agent:builtin:<name>` are subagents, and they name a type, not an agent.
`generate_session_title`, `prompt_suggestion`, and `compact` have no `thread` and
never appear in a native transcript, so they are counted apart. Any other value is a
`shape_unrecognized` gap.

**Attribution.** A subagent's chain takes its agent from hook payloads. The tool use
ids in its responses, or in its history when its responses hold none, match the
`agent_id` of `PreToolUse` and `PostToolUse`. A chain that continues a held message
keeps that message's agent. Two parallel subagents with identical prompts resolve
this way. A subagent interrupted before any tool use leaves no such evidence and
stays a `body_unattributed` gap. OTel `api_response_body` events also carry
`agent_id`, and `Otel::Extract` does not keep that field.

**Thinking.** Response and request bodies hold the literal `<REDACTED>` with a
signature. Native transcripts vary by model: Haiku holds an empty string with a
signature, while a real Opus session held text in 35 of 136 blocks. So reasoning text
is unavailable at own, and `tellem parity bodies` reports
`reasoning_text_only_in_native` when native holds text the bodies do not.

**Counting tool use in a native transcript.** `api-request-blob` lines replay request
content, including earlier `tool_use` blocks. Count `assistant` lines only: over 8
real sessions, every block count of 11421 reduced to 8243 unique ids, which equal the
blocks tellem renders.

**Compaction.** The `compact` request holds the old history and its response holds
the summary, which the next `create` request begins with. That request also carries
the partial text of an interrupted reply and the command lines of `/compact`.
The typed `/compact` echo reaches no request, and tellem rebuilds it from the
`<command-args>` of the command line.

**Injected text.** Bodies have no `isMeta` or `origin` marker. tellem marks a user
block as meta by its text: a whole `<system-reminder>`, `Another Claude session sent
a message`, `The coordinator sent a message`, `<local-command-caveat>`, and
`[handback-send-enforce]`, plus a `[SYSTEM NOTIFICATION` banner in a subagent. Text
the harness injects in any other form reads as a user prompt, and `tellem parity
bodies` reports it as `exchange_source_differs`.

**Differences from the native transcript that bodies cannot close.** `tellem parity
bodies` names each one:

| Cause | What happens |
| --- | --- |
| `terminal_tool_result_not_in_bodies` | A subagent's last tool result, such as `SubagentHandback`, is never sent back to the provider. |
| `native_only_trailing_turns` | A task notification queued as the session exits is never sent. |
| `tool_input_enriched_after_the_wire` | The native `SendMessage` input gains keys the request never held. |
| `native_only_request` | An interrupted stream writes no response file, so its message id and usage are absent. |
| `timestamps_differ` | Native stamps each block as it arrives. Bodies have the send time and the response's end time. |
| `reasoning_text_only_in_native` | Native holds thinking text and the body holds `<REDACTED>`. |

## Harnesses tellem does not capture

tellem installs only into Claude Code and Codex: the manifest sets
`extensions.only: [claude-code, codex]`. `extensions.enabled` is a priority
order, not an allow-list, and without `only` rplugin 1.19.3 linked tellem's
skill into a detected Hermes, Pi, and DeepSeek TUI and merged its hooks into
the Hermes profile. With `only`, an isolated install on a host where all three
are detected creates nothing under their homes, and `rplugin doctor` reports
0 findings. `rstack` and `os` stay in `extensions.enabled`: they are fleet and
os adapter extensions, which `only` does not affect. tellem does not read
Hermes, Pi, or DeepSeek TUI transcripts; they are on
[ROADMAP.md](../../ROADMAP.md). If a hook ever arrives from another harness,
it is recorded as an `unknown_harness` hook gap and no observation.

## Transcript discovery

`tellem transcripts discover [--json]` reports every way a transcript is made,
kept, read, or controlled on the host, as `tellem.discovery/v1`: `harnesses`,
`methods`, `readers`, `controls`, and a `digest`. It writes no state and no
event, reads nothing inside a transcript, a credentials file, or an auth file,
and starts no harness except the bounded `--version` call.

| Method kind | Source |
| --- | --- |
| `native_store` | Claude `projects`; Codex `sessions`, `archived_sessions`, and the `state_*.sqlite` files; file counts and bytes by `stat` only |
| `expiry`, `switch` | `cleanupPeriodDays`, `CLAUDE_CODE_SKIP_PROMPT_HISTORY`, `--no-session-persistence`, `OTEL_LOG_RAW_API_BODIES`, `codex exec --ephemeral`, `history.persistence`, `codex delete` |
| `prompt_history` | `history.jsonl` of each harness, by `stat` only |
| `hook` | Claude settings files (user, local, managed, and each registered scope), Codex `config.toml`, and `~/.ai` through `Cutover::Discover.hooks` and `registrations` |
| `wrapper` | functions and aliases that run an agent through `specstory` in `.bashrc`, `.zshrc`, `.profile`, `.bash_profile`, and fish config |
| `process`, `schedule` | `specstory run` and `specstory watch` in `/proc`; user systemd units and `crontab -l` lines naming `specstory` |
| `repo_output` | `.specstory` in each registered scope (directory or symlink and target) and a `post-checkout` hook naming `specstory` |
| `specstory_state` | `~/.specstory` and its `cloud_sync` and `local_sync` switches |
| `otel` | exporter environment in Claude settings and Codex `[otel]`; headers, tokens, and keys read `[hidden]` |
| `codex_trust` | Codex `hooks.state` entries and tellem's declared hooks; a state key naming the plugin id counts as trusting one |
| `tellem` | its own cutover state, authority levels, and installed hooks |

Every capability carries `known_by`: `binary` when the string is in the
installed harness binary (a bounded streaming search), `evidence` when a
recorded session showed it at that version, `table` for a fixed fact, or
`unknown` with a reason. A switch whose string is missing from the binary reads
`absent` at that version. A source that exceeds its size or time bound reads
`unknown` with the reason.

Readers come from the harness features that open a transcript, the script
behind each registered hook command, code and manifest files in `~/.ai`, and
installed plugin packages (rplugin registry, Claude and Codex plugin caches)
searched for `transcript_path`, `agent_transcript_path`, `.claude/projects`,
and `.codex/sessions`, excluding tellem itself. The digest covers the facts a
plan depends on and leaves out sizes, counts, processes, and line numbers of
reader evidence.
