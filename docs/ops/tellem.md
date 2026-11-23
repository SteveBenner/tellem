# tellem operator runbook

This runbook takes tellem from a built plugin to the capturer of record, and
back. The stages run in order: shadow, parity, import, cutover, native
retention, and the optional OpenTelemetry receiver. Rollback is possible at
every stage.

Three steps are operator gates: the shadow install, import apply together
with cutover apply, and rollback. An agent asks the operator through the question
tool before each one and runs it only on an explicit yes. So does any
`tellem prune --confirm`.

## Before you start

Run `tellem doctor`. Work every finding to zero, or accept it knowingly. Each
finding names its next command.

| Check | What it means | Next command |
| --- | --- | --- |
| `hook_load` | The hook entrypoint's warm load time against the 50 ms budget | `tellem health --all` for real per-event `hook_ms` |
| `capture` | `features.capture`, the `capture.enabled` flag file, `TELLEM_DISABLED`, and a scope's own `capture.off` | `tellem config set features.capture true [--scope PATH]` |
| `harness_version` | `claude --version` and `codex --version` | `claude --version`, `codex --version` |
| `registry` | A registered scope whose `.tellem/` directory is gone (dangling) | Root still there and derive on: `tellem sync --scope ROOT`. Root still there but derive off (`features.derive` or `TELLEM_DERIVE_DISABLED`): none; doctor names the blocker, and the scope comes back at the first sync after the operator turns derive on. Root gone: none; reports treat its sessions as gone, and the append-only registry keeps the entry |
| `registry` (excluded root) | A `.tellem` directory that sits in a root `scope.exclude_roots` covers, listed with its path and the removal command; or an unreadable mirror file, which makes tellem treat every repository as excluded | `rm -r -- PATH/.tellem` (the operator runs it; tellem never does); for the mirror, `tellem config set scope.exclude_roots VALUE` |
| `backend` | The mirror for the current scope: none, unprovisioned, unreachable, or breaker open | `tellem store provision sqlite --scope ROOT`, `tellem store status --scope ROOT` |
| `persona` | Whether the persona CLI is detected and `features.persona` is on | `rplugin install persona`, `tellem config set features.persona true` |
| `rplugin` | rplugin must be 1.19.0 or newer for async hooks and `post_tool_failure` (ADR-13) | `git -C ~/.rplugin pull --recurse-submodules && ~/.rplugin/bin/rplugin install tellem` |
| `claude_hooks` | The rendered Claude Code hooks file of every installed copy | `~/.rplugin/bin/rplugin package tellem && ~/.rplugin/bin/rplugin install tellem` |
| `visibility` | A user-level `visibility` value, which tellem ignores; in the current repository: an ignore file out of step with the declared `visibility`; in a public repository, a tracked file under `.tellem/` or `.specstory/history`, or a foreign `.specstory/history/.gitignore` that does not ignore tellem's copies | `rplugin settings unset tellem visibility`; `tellem derive --scope ROOT`; `git -C ROOT rm -r --cached PATH`; `printf '*\n' >> ROOT/.specstory/history/.gitignore` |
| `history_import` | A subsume import that failed, was interrupted, or has not started. A host with no cutover directory has no import and reports ok | `tellem cutover import --confirm PLAN_ID` |
| `otel` | With `otel.receiver` on: the receiver is not running, its port is held by another listener (`port_in_use`), or it could not adopt its listening socket (`inherit_failed`) | `tellem otel status`; for `port_in_use`, `tellem config set otel.port PORT` and re-plan |

### Repository visibility

A repository is private unless its scope declares otherwise with
`tellem config set visibility public --scope ROOT`. In a private repository
only the volatile files (locks, the cursor, the dirty flag, the SQLite mirror
and its sidecars, temporary files) stay ignored, so `.tellem/` and
`.specstory/history/` show in `git status` and the operator may commit the
rest. Transcripts can carry sensitive content, so declare `visibility public`
in any repository that may be published. In a public repository `.tellem/` and
`.specstory/history/` each carry a `.gitignore` of `*`, so nothing tellem
writes can be pushed by accident. A repository tellem only writes a pointer
into is private by the same rule. tellem never runs `git add`, `git rm`, or `git commit` and never edits
the repository's own `.gitignore` or `.git/info/exclude`. Setting the value
reconciles the ignore files at once, and every derive keeps them in step.

`visibility` is read and written per repository scope only. `tellem config set
visibility` writes the scope named by `--scope`, else the repository around the
working directory, and refuses with a usage error outside a repository. For a
repository under a `scope.exclude_roots` root it sets nothing, names the
excluded root, and exits 0: tellem writes no scope there, and the user scope
keeps `*`. A user-level value is ignored, so no single setting can make every undeclared
repository public, and `tellem doctor` names it.
Turning a private repository public does not untrack what was committed;
`tellem doctor` names each tracked path with the `git rm -r --cached`
command, and the operator decides whether to run it.

The `claude_hooks` check reads `<claude home>/plugins/installed_plugins.json`
(`CLAUDE_CONFIG_DIR`, else `~/.claude`) and each `tellem@tellem` install's
`hooks/hooks.json`, plus the package's own `hooks/hooks.json` when one exists.
It expects SessionStart, UserPromptSubmit, PostToolUse, PostToolUseFailure,
SubagentStart, and SubagentStop to run `tellem-hook` with `async: true` and a
30 s timeout, and Stop and SessionEnd to run it synchronously at 2 s.

`tellem doctor --json` gives the same report as one `tellem.report/v1`
document. It exits 0 whatever it finds; read `data.findings`.

## Shadow

Shadow means tellem captures beside SpecStory and the `TOKENS.jsonl` ledger
hook, which stay the capturers of record (`cutover.state` is `shadow`).

1. Gate: ask the operator. Then install with `~/.rplugin/bin/rplugin install tellem`,
   and confirm with `~/.rplugin/bin/rplugin doctor tellem` at zero findings.
2. Run `tellem doctor` and confirm `capture` and `claude_hooks` are ok.
3. Watch it: `tellem shadow status`, `tellem health --all`, and
   `tellem tree` in a repository where an agent just ran.

Monitors while in shadow:

- Hook time: `hook_ms` p99 above 50 ms in `tellem health`. Investigate it.
- Gaps: any new gap cause in `tellem health`. Investigate it before cutover.
  A record lost to a late async hook shows as a gap up to 35 s later
  (ADR-13).
- Derive lag above 600 s at idle. Inspect the scope's `derive.lock` and the
  deriver's events, then run `tellem sync --scope ROOT`.

To stop capture at once, export `TELLEM_DISABLED=1` in the harness's
environment, or run `tellem config set features.capture false`. Either takes
effect on the next hook.

## Parity

Run `tellem parity [--session S] [--since T]`. For each shadowed session it
compares the turn sequence with the SpecStory history file and every counter's
sum with the ledger rows, and for the TOKENS view every row field with the
incumbent's row of the same id. It names the cause of every mismatch.

These fields are excluded, because they depend on when the incumbent's hook
ran or on a credentials file tellem does not open: row order, `billing_plan`,
`stop_hook_active`, the `permission_mode` of a row the incumbent wrote at
SessionEnd, and Codex billing.

These are excluded and counted instead of compared:

- Thinking turns, a text turn made only of `<think>` blocks, on both sides:
  tellem stores no thinking, and a model that writes `<think>` into its text
  produces such a turn in tellem's transcript too. Each side is counted.
- `Agent - sidechain` turns on both sides: SpecStory inlines the subagents'
  turns into the parent's file, and a transcript that quotes such a heading
  parses as one. tellem compares each subagent in its own file.
- Incumbent ledger rows for `<synthetic>` messages whose every counter is zero.
- Ledger ids the incumbent wrote more than once.
- Rows that exist only in tellem and whose cwd is not an existing directory
  (`incumbent_cwd_missing`): the incumbent's hook cannot open `TOKENS.jsonl`
  there and exits silently. They are removed from both sides' sums.
- Rows that exist only in tellem and are timestamped at or after an applied
  cutover that retired the incumbent's `TOKENS.jsonl` hook for that harness
  (`incumbent_retired`, counted under `excluded.retired_ids` and listed under
  `accepted`): the incumbent stopped writing then, so a session running
  across the cutover has nothing to compare them with (D-40). They are
  removed from both sides' sums.

These differences are accepted and listed under `accepted` with a count and a
sample, so a session with only these is at parity and the report still shows
them:

- `mode_changed_mid_session`: a `permission_mode` difference in a session whose
  tellem rows carry more than one mode. tellem gives each row the mode of the
  nearest hook; the incumbent gives a whole Stop batch the Stop payload's mode.
- `incumbent_billing_undetected`: the incumbent says `unknown` where tellem
  does not.
- `redaction_only`: a transcript turn that differs only where a
  `[REDACTED:<kind>]` marker, on either side, stands for 1 to 64 characters of
  a text that would make the two sides equal. SpecStory redacting a path as a
  credential URI, and both sides redacting different places of one turn, are
  covered. Turn text over 262144 characters, more than 256 markers on a side,
  or a search past 500000 states is not matched and stays a mismatch. A turn
  that equals the incumbent's turn after tellem's own redactor runs on the
  incumbent's raw text also counts here, whatever the length of the redacted
  value (D-35).
- `image_placeholder`: a tellem turn whose only difference is an
  `[image omitted]` placeholder the incumbent leaves out.
- `incumbent_truncated`: tellem's transcript has trailing turns after an
  otherwise equal turn list. SpecStory stops writing a subagent's file at its
  first stop, so a resumed subagent's later turns are missing there. The count
  is the number of extra turns.
- `subagent_final_report`: a subagent whose tellem transcript has exactly one
  extra trailing turn over an otherwise equal turn list, and that turn is its
  `SubagentHandback` tool turn. SpecStory leaves the final report out. Any other
  trailing turn, a second extra turn, and the same difference on the main
  thread stay mismatches.
- `incumbent_renders_queued`: the incumbent writes queued messages as ordinary
  user turns, as SpecStory does since its re-sync of 2026-11-22. Parity first
  compares with tellem's queued turns set aside. If that fails, it compares
  again with them kept in place, and a match then counts the queued turns
  here (D-39). The other rules apply to both comparisons.

For Codex sessions only, and only after the rules above leave a mismatch,
parity sets aside four kinds of turn that one side records and the other
does not (D-38). The rest must still match turn for turn:

- `codex_nested_command`: an `exec_command` turn. In code mode Codex runs each
  shell command inside an `exec` tool call. tellem renders each command, and
  SpecStory renders only the `exec` call.
- `codex_context_turn`: a user turn that carries injected context, not a
  prompt. These are AGENTS.md instructions, environment context, a hook prompt,
  Codex internal context, or a `Message Type:` message from another agent.
  Such a turn is set aside on both sides. The comparison against the Codex
  rollout applies the same rules, because the rollout keeps the injected
  messages and drops the messages between agents.
- `codex_inherited_turn`: in a subagent, a text turn before the first
  `Message Type:` message. That is history a forked child inherited, and
  SpecStory renders only its tool calls.
- `codex_question_echo`: an incumbent agent turn that repeats a
  `request_user_input` question tellem holds in the tool call's input.

Parity compares a session's tellem rows with the incumbent ledgers the
incumbent wrote to, not only the scope root's `TOKENS.jsonl`. The incumbent
writes a row to the ledger of the repository its cwd is in: the nearest ancestor
with a `.git`, stopping at the launch directory, a linked worktree mapped to its
main checkout, and the launch directory when the target is not writable. Parity
applies the same walk to every tellem row and reads each other ledger it names,
at most 64. A ledger that cannot be read adds nothing, so its rows stay
tellem-only and the session stays a mismatch.

A line shaped like a turn heading inside a tool-use block (opened by a line
beginning `<tool-use data-tool-`, closed by a line ending `</tool-use>`) is
tool output on both sides and starts no turn. A line ending `</tool-use>`
inside a fenced code block of the tool output does not close the block, so a
tool output that quotes a rendered transcript starts no turns.

The incumbent logs a turn's rows at the next Stop, a subagent's at its
SubagentStop, or at SessionEnd. Until then a session shows them as
`tellem_only_rows`. When that is the only difference, each such row is no older
than the newest ledger row of the same agent, the session has no `session_end`
record, and its last record is under 24 hours old, the session is `pending`.
A transcript whose turns are an accepted prefix of SpecStory's
(`tellem_behind`) is pending under the same conditions. A pending session takes no slot among
the last 20 Claude sessions and is listed on the `pending` line of the report,
and `cutover` stays unmet while any session is pending. It becomes `parity`
when the incumbent logs the row, and a `mismatch` again if the session ends
without it or goes 24 hours quiet. Codex has no `session_end` hook and its
rows carry no `stop_reason`, so a Codex session is never pending.

`<system-reminder>` blocks are removed from both sides before a turn's text is
digested. A SpecStory subagent file named
`<time>-<harness>-<prefix>--subagent-<agent>.md` pairs with the session its
prefix matches uniquely, by the import rule. Differences that only a replay
causes (billing, permission mode, or cwd from a replay without credentials,
payload fields, or worktrees) are not excluded.

Parity holds when the last 20 shadowed Claude sessions that have incumbent
output and the last 5 shadowed Codex sessions all match (FR-24). While they do
not, the report says how many more passing sessions it needs: enough to push
the newest failing session out of the window, or to fill it. A Codex
session is judged against its rollout (below), because Codex has no incumbent
writer. Cutover
is not offered before that. A shadowed session is one with raw hook records.
An imported session has none, so it carries no billing or permission mode and
never counts toward the criteria; the report still shows its own verdict and
lists it under `not_counted` with the reason `no_hook_records`.

### Codex sessions

A shadowed Codex session is compared with the rollout Codex wrote, found by the
`transcript_path` in the session's hook records. A separate reader re-parses the
rollout: the user and assistant message turns (tool turns are left out of both
sides) and the main agent's counters, summed from the per-request
`token_usage_record` entries or, when there are none, from the distinct
`last_token_usage` entries, with `input_tokens` net of `cached_input_tokens` as
in the incumbent ledger's Codex rows. The report adds a `ROLLOUT` column holding
the transcript and token verdicts, and a Codex session at `parity` counts toward
the last 5. A session whose rollout changed after tellem's last record, with no
`session_end` and under 24 hours quiet, is `pending`. Where the rollout's
cumulative `total_token_usage` differs from its per-request records (4 of 29
rollouts on this host), the difference is listed as accepted, never as a
mismatch. A missing or unreadable rollout leaves the session with no reference.

The check shows that the hook, redaction, alignment, derivation, and rendering
kept what the rollout holds. It does not show that the rollout matches what the
model saw, and it does not compare tool turns, subagent rollouts, or cost.

Codex runs a plugin's hooks only after you trust them in
`~/.codex/config.toml`. Until then a real Codex session is not captured and
cannot count. `codex exec --dangerously-bypass-hook-trust` runs one session
without that trust, for a test in a scratch repository.

## Import

Import brings prior histories into their home scopes, one source per session:
the native transcript first, then the SpecStory file (transcript only,
labelled `specstory_lossy`), then ledger rows (usage only).

1. Plan: `tellem import native`, `tellem import specstory --path P`, or
   `tellem import ledger --path P`. Without `--confirm` it is a dry run that
   prints a plan id and every session with its chosen source, and exits 3.
   It changes nothing.
2. Review the plan.
3. Gate: ask the operator, showing the plan id. Then run the same command with
   `--confirm PLAN_ID`.
4. Check: the report lists each source's sha256 before and after, and they
   are equal. A re-apply adds nothing.

A plan refuses when its inputs changed since planning. Plan again.

An import while `features.transcripts` is off writes no Markdown transcript.
Once it is on, the next derive renders the transcript of every session whose
native transcript still exists and whose Markdown is missing.

## Cutover

Cutover makes tellem the capturer of record and removes SpecStory and the
ledger hook from `~/.ai`.

1. Plan: `tellem cutover plan` (add `--otel` for the OpenTelemetry receiver,
   below). It writes `plan.json`, `apply.patch`, and `rollback.patch` under
   `<state_dir>/cutover/<plan_id>/`, covering every hook script, settings
   registration, and rule text that captures with or names SpecStory or
   `TOKENS.jsonl`. It changes nothing.
2. Review the patches. The plan also sets `retention.native` true and states
   the retention window.
3. Gate: ask the operator, showing the plan id. Then run
   `tellem cutover apply --confirm PLAN_ID`.

Apply refuses (exit 3 or 1, with the cause) when the plan id is wrong, when
parity does not hold, or when any planned file's sha256 differs from the plan:
exit 3 without `--confirm`, exit 1 with `unknown_plan`, `invalid_plan_id`,
`parity_unmet`, `files_changed`, `plan_changed`, or
`unresolved_dispositions`. Plan, apply, and rollback fail with exit 5 when
`TELLEM_AI_HOME` (or `~/.ai`) or the Claude home is missing; they never fall
back to another directory.
It backs up every file it changes, sets `cutover.state` to `cutover`, and
never commits in `~/.ai`; it prints the git commands for you to run.

Only cutover apply switches on `cutover.state`, `retention.native`,
`retention.purge`, and `otel.receiver`. `tellem config set` refuses to turn any of
them on with a usage error naming `tellem cutover plan`; it still turns
`retention.native` and `otel.receiver` off. It refuses every `cutover.state` value
except that `cutover` is accepted on a host with no `~/.ai` and no incumbent:
`shadow` names `tellem cutover rollback`, because only rollback restores `~/.ai`
with it. `authority.claude` and `authority.codex` are set only by apply and
rollback.

## Authority levels

A plan can also raise how much of the transcript tellem owns, for each harness:

```
tellem cutover plan [--otel] [--claude observe|spool|rehearse|own] [--codex observe|spool]
                    [--specstory coexist|subsume] [--purge] [--accept-reader ID]...
                    [--accept-parity NAME]... [--link-target PATH]...
tellem cutover status
tellem cutover import --confirm PLAN_ID
```

| Level | Native transcript | Cost |
| --- | --- | --- |
| `observe` | stays | none, and it frees no disk |
| `spool` | removed once its record is verified and its window passed | resume, rewind, and logs lose each removed session |
| `rehearse` (Claude only) | stays, with the body file mode on too | disk use rises until each session is compared; it frees no disk |
| `own` (Claude only) | never written | resume, rewind, and logs have nothing to open, reasoning text is unavailable, and the session that reveals a loss cannot be recovered |

A bare plan keeps its meaning: it retires the `~/.ai` hooks, and it needs `~/.ai`.
A plan that names a level needs no `~/.ai` and leaves `~/.ai` alone unless it also
says `--specstory subsume`, which retires the `~/.ai` hooks and removes each
wrapper function or alias from its startup file, by its real path. Open shells and
running `specstory run` processes keep the old behavior until they exit.

`--specstory subsume` also imports history (D-25). Apply starts the import in the
background and returns without waiting. It runs the importer over native
transcripts, then over `.specstory/history` and `TOKENS.jsonl` in every registered
scope, one source per session as in Import above, and changes no source. Confirming
the plan is the gate for it; there is no second plan id.

`tellem cutover status` shows the import's state (`starting`, `running`, `done`,
`failed`, `interrupted`, `stopped_by_rollback`), its counts per source, and each
failure. `tellem doctor` raises a `history_import` finding when it failed, was
interrupted, or never started. A failed import does not undo the subsume.
`tellem cutover import --confirm PLAN_ID` resumes in the foreground: it skips each
scope already finished, and a repeat adds nothing. A source file that changed during
the import is counted, not refused, because a running session appends to its own
transcript. Compressed Codex rollouts cannot be read and are counted as not imported.
A repository the registry does not know is not found; import it with
`tellem import specstory --path P`.

The plan id binds the discovery digest, the request, the harness version, the
accepted names, and the retention window. Apply refuses with `discovery_changed`
when discovery's digest moved.

Refusals exit 5 and name the cause in `error.detail.cause`, changing nothing:

| Cause | When |
| --- | --- |
| `level_not_available` | `--codex own` or `--codex rehearse`; Codex stops at spool |
| `switch_absent` | own or rehearse needs a switch that is not `present` at the installed version |
| `unknown_parity_cause` | `--accept-parity` names no known cause |
| `body_parity_unrecorded` | no rehearse recorded body parity at the installed version |
| `body_parity_unmet` | a recorded difference is not named by `--accept-parity` |
| `parity_cause_not_observed` | `--accept-parity` names a cause not recorded at this version |
| `reader_not_accepted` | a reader of native transcripts is not named by `--accept-reader` |
| `specstory_active` | own with a wrapper, process, schedule, or sync hook this plan does not remove |
| `authority_stopped` | a raising plan while the stop switch is set |
| `env_set_outside` | Claude settings env already holds another value for a key the level sets; tellem never overwrites it |

Own refuses in the order the table lists them. To reach own, apply
`--claude rehearse --specstory coexist`, let real sessions finish, read
`tellem parity bodies`, and name each difference you accept. The plan text prints
what each accepted name loses. A new cause, or the same cause at a new harness
version, refuses again.

**Rehearse.** The deriver compares each finished session (`session_end` seen or
300 s quiet, and past the settle window) with `Parity::Bodies`, appends a row to
`<state_dir>/authority/body-parity.jsonl`, and removes that session's spool files.

**Liveness at own.** Each derive checks the sessions that started after apply. It
records a `capture_lost` gap, with no content, when:

- the spool is missing, unreadable, wrongly owned, or at any mode but 0700;
- a native transcript or file appeared for the session;
- a body file is missing, too large, or marked `not_recorded`, `body_withheld`, or
  truncated;
- no index line arrived within the first response's latency plus 30 s of the first
  evidence of a response; or
- at session end or after 300 s quiet, fewer bodies exist than the provider
  responses OTel evidenced, or a tool call in the hook records has no body.

A native main transcript at own is `level_ineffective`, handled the same way. An
interrupted request leaves a request file with no response and no index line. It
is a `native_only_request` gap, never a loss, so pressing Escape does not end own.

A loss removes own's env keys from the settings file (keys whose value still
matches, through a backup under `<state_dir>/authority/backup/`), sets
`authority.claude` to the prior level, appends a receipt to
`<state_dir>/authority/receipts.jsonl`, emits `tellem.authority.lowered`, and
raises a `tellem doctor` finding. Own stays refused until planned anew: the plan id
binds a generation the loss advances.

**A failed restore.** A restore can fail: the settings file cannot be replaced (a
read-only directory; a read-only file alone is replaced and keeps its mode), the
Claude home is gone, or a cutover plan, apply, or rollback holds the lock. The level
then stays where it was, and sessions may go on writing no native transcript. tellem
records `restore_failed` with its reason in `<state_dir>/authority/state.json`, adds a
`restore_failed` gap to the session that revealed the loss, emits
`tellem.authority.restore_failed` once, and raises a `tellem doctor` finding naming the
file and the fix. Retention does not run for that harness (`authority_restore_failed`).
Every later derive retries from the stored record, in any scope, without needing the
session's evidence. `tellem authority restore` retries at once. Success removes the
env keys, lowers the level, writes the receipt with `recovered_from`, and clears the
record. Rollback of the plan also clears it.

**Stop switch.** `tellem authority stop` lowers every harness to its prior level at
once and sets `<state_dir>/authority.off`. `TELLEM_AUTHORITY_DISABLED=1` or the flag
is read at every derive and before any removal, and the environment wins in both
directions (`0` overrides the flag). A flag tellem cannot read counts as set. While
set, retention, purge, and body removal do not run, and no plan can raise a level.
`tellem authority resume` clears the flag and raises nothing. The capture hook does
not read the switch. `tellem authority status` shows levels, the switch, and losses.

**Purge.** `--purge` with `--claude spool`, `--claude own`, or `--codex spool`
applies the retention check to every native session older than the applied plan, at
apply and at later derives. The plan prints the bytes it can free and the share the
record keeps. Purged files stay gone after rollback; their receipts name them.

**Window 0.** `retention.native_days` accepts 0 at spool and own: a session's native
files go once it is final and verified, and never sessions older than the plan
without `--purge`. A session with no `session_end` counts as final only after 24 h
quiet.

## Discovery and entries

`tellem transcripts discover [--json]` is read-only and the first thing to run
before a level plan. It reports the harness stores and their sizes, expiry
settings, switches and whether the installed harness carries them (declared by
a version table, seen in the installed binary, or verified by a session), prompt
histories, hooks in harness settings and in `~/.ai` when present, shell wrappers
in startup files, running wrapper and watcher processes, user timers and cron
entries, SpecStory's state and its per-repository output including vault links,
OpenTelemetry exporters, Codex hook trust, and the readers: the harnesses' own
features that open a transcript, every command registered as a hook, `~/.ai`
when present, and installed packages that name native transcript paths. A
capability it cannot establish stays unknown. It needs no `~/.ai`, no
SpecStory, and no polispec, and exits 0 on a host with none.

Entries are off by default (`transcripts.entries`). With them on, the deriver
also writes redacted, whole, ordered records of each agent's prompts, replies,
visible reasoning, actions, and outputs, omitting nothing for size or tool; a
body over the record bound is split into consecutive parts.

```
tellem export --session KEY [--after CURSOR] [--limit N] [--scope PATH] [--json]
tellem sync --session KEY [--timeout S]
tellem forget --session KEY | --all [--scope PATH] [--confirm PLAN_ID]
```

`export` is the only interface another plugin reads entries through; `sync
--session` makes a session current first and is bounded by its timeout. A plugin
that must keep content out of the record declares the `transcript_policy` port
(tool names and path prefixes replaced by a placeholder before they enter the
record, and the native readers it declares); the standalone form withholds
nothing. `forget` without `--confirm` only plans.

tellem needs Ruby 3.3 or newer. Below it `bin/tellem` prints the Ruby it found
and exits 1, and the hook exits 0, adds no raw record, and writes
`hook-load-failure.json`, which `tellem doctor` reports.

## SpecStory removal

```
tellem specstory remove [--history keep|remove] [--prevent on|off] [--link-target PATH]... [--confirm PLAN_ID]
tellem specstory status
```

Removal is the irreversible step behind the reversible subsume. It refuses with
`not_subsumed` unless the cutover state is `cutover` with SpecStory subsumed, or
discovery finds no active SpecStory. Without `--confirm` it prints the plan and exits
3. The plan id binds the file list with each file's sha256, the history mode,
prevention, and the named link targets. Apply deletes per file with unlink and rmdir,
never a recursive delete and never through a symlink, and writes a
`tellem.specstory-removal/v1` receipt with path, size, and sha256 to
`<state_dir>/specstory/removal.jsonl` before each unlink. A killed removal resumes at
the next derive or the next `remove --confirm`.

It removes SpecStory's user state (`~/.specstory`), each registered repository's
`.specstory` files other than `history`, and any wrapper block discovery still finds.
`--history remove` also removes a history file only when the record holds that
session at parity or imported it with a receipt; an unfinished or failed history
import keeps every history file with `history_import_<state>`. A file git tracks is
listed for you to decide, because tellem never runs `git rm`. The default keeps
history. A `.specstory` symlink is followed only for a target named with
`--link-target`; any other is skipped and reported. The plan prints the uninstall
command for the program and never runs it, lists what tellem does not replace
(cross-agent resume, other agents, skills, cloud sync and any cloud copy), and warns
when cloud sync was on.

Afterwards `specstory_writer` is pinned on, unless you set it off, so readers of
`.specstory/history` keep their input. With `--prevent on` each derive removes the
wrappers and state the plan named if they return, with a receipt and a `tellem doctor`
finding, and only reports a returned program. A startup file is edited by writing a
temporary file beside it and renaming it over the original only when its inode, size,
and modification time are unchanged; a changed file is left alone and retried at the
next derive. While the authority stop switch is set, drift is reported and nothing is
removed.

## Rollback

Before cutover: `tellem config set features.capture false`, or
`~/.rplugin/bin/rplugin uninstall tellem`. Scopes stay readable.

After cutover: ask the operator, then run `tellem cutover rollback --confirm PLAN_ID`.
It restores every `~/.ai` file byte for byte from the plan's backups, sets
`cutover.state` back to `shadow`, and clears `retention.native` and
`otel.receiver`. With an `--otel` plan it also restores the Claude settings
file. Native transcripts that retention already removed are not restored;
their receipts name each removed file with its sha256. Rollback of a `--specstory
subsume` plan leaves what the history import added in the record and says so, and a
running import stops before its next scope.

Claude Code rewrites its settings file during a session. When that file changed
after apply, rollback undoes this plan's env keys in it, and restores the original
bytes when nothing else differs. A key that holds another value stays, and the
result names it. Any other planned file that changed still refuses with
`files_changed`. Rollback removes the spool directory only when it is empty, and
`index.jsonl` stays because the harness appends to it.

## Native retention

After cutover, the deriver removes a Claude Code session's own native files:
the session transcript and the `<session id>/` directory beside it
(`subagents/`, `tool-results/`). It runs only while `retention.native` is on,
`cutover.state` is `cutover`, and `TELLEM_RETENTION_DISABLED` is unset.

A session is removed only when, at that moment, all of these hold:

- It is final: `session_end` was seen, or nothing was written for the window.
- It is settled: no expected record is still inside the 35 s settle window.
- A fresh parse of its native transcripts gives the same request ids and the
  same sum for every counter as tellem's usage records.
- Every agent with a transcript link has its Markdown transcript written.
- For every agent, the native `assistant` tool use blocks and answered tool
  results count the same as the Markdown (`tool_count_mismatch` holds the session
  and names both counts). `api-request-blob` lines replay request content and do not
  count. Under a withholding policy only tool uses are compared.
- Its newest native file is older than `retention.native_days` (14 by
  default).

Files are unlinked one by one, never recursively, never through a symlink,
and never outside the harness transcript root. Each removal appends a
`tellem.retention/v1` receipt to the scope's `.tellem/retention.jsonl`. A
held session records a gap naming the failed condition; a harness lookup that
fails on unreadable outside data holds the session with `harness_unreadable`.

- Report: `tellem retention` shows candidates, held sessions with their
  causes, and removed totals.
- Stop: export `TELLEM_RETENTION_DISABLED=1`, or `tellem authority stop`.
- Longer resume window: `tellem config set retention.native_days DAYS`.

Codex rollouts are removed only at `authority.codex` spool. The session must have
ended its last turn, tokens must match `Parity::Rollout`, and tool counts must match
the Markdown. Removal runs `codex delete --force <uuid>` with the id from the hook
payload and a 30 s timeout, never a glob. `--force` is needed because delete refuses
to prompt without a terminal. On Codex 0.166 delete removes the rollout and the
`threads` row, and `codex exec resume` then fails with `no rollout found`. A failed
delete holds the session with `codex_delete_failed`, and the next derive tries
again. A session with a `.jsonl.zst` rollout or one tellem cannot read holds with
`rollout_unreadable`. A plan does not change `history.persistence`.

## OpenTelemetry receiver (optional)

The receiver adds each Claude Code request's effort, cost, time to first
token, duration, and query source as a usage detail. It never creates usage
or changes a counter.

1. Plan with `tellem cutover plan --otel`. Beyond the cutover patch it
   proposes the Claude settings env change: `CLAUDE_CODE_ENABLE_TELEMETRY=1`,
   `OTEL_LOGS_EXPORTER=otlp`, `OTEL_EXPORTER_OTLP_PROTOCOL=http/json`,
   `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` on 127.0.0.1 at `otel.port` (43180 by
   default), `OTEL_EXPORTER_OTLP_HEADERS` with the bearer token,
   `OTEL_METRICS_EXPORTER=none`, and `OTEL_TRACES_EXPORTER=none`. It turns on
   no content switch. Apply sets `otel.receiver` true.
2. Gate: the same as cutover apply.
3. Two synchronous session_start and prompt_submit hooks run
   `tellem-otel ensure`. It reads `otel.receiver` itself and exits at once
   when it is off. When it is on and no receiver runs, ensure takes the
   receiver lock, binds 127.0.0.1 at `otel.port` itself with a backlog of
   128, and hands the listening socket to a detached `tellem-otel serve`, so
   the port listens before the hook returns. The receiver answers 401
   without the bearer token, refuses bodies over 1 MiB, and exits after 30
   minutes without a request. It refuses a socket not bound to 127.0.0.1,
   and when it cannot adopt the socket it records `inherit_failed`.
4. Check with `tellem otel status`: receiver state, port, last event age,
   events kept and refused by cause, and requests derived without a detail.

When the bind fails because another listener holds the port, ensure records
`port_in_use` and never retries; `tellem otel status` and `tellem doctor`
report it (and `inherit_failed`). Change `otel.port` and re-plan. The token is
the SDK secret `otel_token`. The SDK secrets port reads it from an
`OTEL_TOKEN` environment variable first, then from tellem's
`credentials.yml`. Keep it in `credentials.yml`. Claude Code removes every
variable named `OTEL_*` from the environment of its hooks (measured on 2.1.318), so
a receiver started by the `SessionStart` hook never sees an exported `OTEL_TOKEN`
and records `no_token`, which `tellem otel status` and `tellem doctor` report. An
exported `OTEL_TOKEN` works only for what a shell starts directly:
`tellem-otel ensure`, and the check in `tellem cutover plan --otel`, which fails
with exit 5 until one of the two exists, so that check can pass on a token the hook
will not see. To stop the receiver, export
`TELLEM_OTEL_DISABLED=1`. Rollback of the `--otel` plan removes the env change
and clears `otel.receiver`.

## Tasks

A task is a run of one person's prompts about one piece of work. tellem groups
prompts into tasks by the rules of the task clock in `~/.ai`
(`claude/hooks/task_clock.py`) and times them the same way: **elapsed** from the
first prompt, **active** as the main agent's working time, **agents** as active
plus every subagent's time. This is telemetry only. tellem registers no hook for
tasks, answers no `/task` marker, and serves no status line segment; the clock
in `~/.ai` keeps those. The engine still reads a `/task` marker in a recorded
prompt so the derived tasks agree with the clock.

`tellem config set tasks.mode MODE` takes `on` (the default) or `off`. With `off`
nothing is derived, and `tellem tasks` and `tellem tokens --tasks` refuse and name
`tasks.mode`. A value of `shadow` or `live` from 0.2.5 is no longer valid.

| Question | Command |
| --- | --- |
| Time and tokens per task, with rates per agent-minute | `tellem tasks [--session S] [--since T] [--scope PATH \| --all] [--json]` |
| The tokens report grouped by task, or by task and agent | `tellem tokens --tasks [--by agent]` |
| Derived tasks against the clock's own store | `tellem tasks parity --against PATH` |

`tasks.attribution` decides which task a main-agent request joins: `timeline`
(the task whose latest turn in that session began at or before the request) or
`spans` (only a request inside an active span). A subagent request joins the
task that holds its agent id. A request that joins no task is counted in the
`unattributed` row, so a session's tasks plus `unattributed` equal its total.
`tasks.<rule>` settings carry the clock's thresholds and word lists; every
number and list is JSON text, for example
`tellem config set tasks.new_threshold 3`.

Differences you should expect between a derived task and the clock's: the
transcript carries no Stop or SessionStart events, so active time and a
mid-session restart are reconstructed; a resumed subagent counts once instead
of once per start; the clock leaves some subagents open, which inflates its
agents time. Every derive re-reads each session of a scope (0.1 to 1.7 s per
scope in the scratch copies). tellem keeps no task state outside the record.

## Excluded roots

`scope.exclude_roots` (D-28) is a colon-separated list of root prefixes tellem
never writes into, empty by default. Set it with
`tellem config set scope.exclude_roots /path/one:/path/two`; each entry is
expanded and resolved (symlinks followed) when it is mirrored to
`<state_dir>/scope.exclude_roots`, one root per line, at `tellem config set`
and at the next derive or first session start. The hook reads that file only
when a session's home is located, and nothing when it is absent.

A repository at or under a listed root (matched at a path boundary, so a
sibling directory sharing the prefix is not covered) is not a scope. A session
started there has its home in the user scope; no `.tellem` directory, pointer,
registry entry, or lock is created there, and `derive`, `sync`, and the reports
skip it. The session keeps its record, including the paths it worked in. A
session that was homed in a covered root before the setting was set moves to the
user scope at its next hook, with a `home_moved_excluded` hook gap; its earlier
raw observations stay where they are. An unreadable mirror file fails closed:
every repository is treated as covered and each hook leaves an
`exclude_roots_unreadable` gap. tellem removes nothing under a covered root;
`tellem doctor` lists any `.tellem` directory already there with the command for
you to run.

## Kill switches

| Variable | Stops |
| --- | --- |
| `TELLEM_DISABLED=1` | Capture by the hook |
| `TELLEM_DERIVE_DISABLED=1` | Derivation |
| `TELLEM_BACKEND_DISABLED=1` | The mirror backend: sync, provisioning, rebuild, and drop |
| `TELLEM_RETENTION_DISABLED=1` | Native retention |
| `TELLEM_AUTHORITY_DISABLED=1` | Own and rehearse env for later sessions, retention, purge, and body removal; `0` overrides the flag file |
| `TELLEM_OTEL_DISABLED=1` | The OpenTelemetry receiver |

Each takes effect on the next invocation.
