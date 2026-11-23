---
name: tellem-migrate
description: >
  Walks a user from SpecStory (and the TOKENS.jsonl ledger hook) to tellem as
  the capturer of record: shadow install, discovery, parity, a backup of native
  transcripts and SpecStory history, the cutover plan and apply, native
  retention, and what to do afterwards. Use it when the user says they want to
  move, migrate, switch, or take over from SpecStory, or asks whether tellem is
  ready to replace it.
---

# Migrating from SpecStory to tellem

This skill drives the takeover with tellem's real commands. It adds no
behaviour of its own. The command reference is `docs/ops/tellem.md` and the
query skill is `tellem`; read the sections named below when a step needs more.

The end state of this guide is a takeover with SpecStory kept: tellem is the
capturer of record, SpecStory's history stays where it is, and native
transcripts are removed by retention after a window. Removing SpecStory itself,
and the levels `rehearse` and `own`, are separate follow-ups the user must ask
for; see the last section.

## Rules

- Run only read-only commands and dry-run plans yourself. Ask the user through
  the question tool, and wait for an explicit yes, before: `rplugin install`,
  any copy of the user's data, `tellem import ... --confirm`,
  `tellem cutover apply --confirm`, `tellem cutover rollback --confirm`, and
  `tellem specstory remove ... --confirm`. Name the command, what it changes,
  and the plan id.
- Never pass `--confirm` with a plan id the user did not approve. If anything
  changed since the plan (a new session, an install), plan again; a stale id is
  refused.
- Never edit anything under `.tellem/`, tellem's state directory, or
  `~/.ai` by hand. Change tellem only through its commands.
- Report what each command printed. Do not summarize a failure as success.

## 1. Find out where things stand

```sh
tellem version
tellem doctor
tellem transcripts discover
tellem cutover status
tellem specstory status
```

If `tellem` is not found, tellem is not installed: follow `INSTALL.md`, which
installs it in shadow mode (`cutover.state` is `shadow`), and stop until the
user has used the agent app for a while, because parity needs real sessions.
`tellem doctor` should report zero findings you cannot explain. Show the user
anything it flags.

`transcripts discover` lists every transcript method on the host: SpecStory
wrappers and hooks, the `TOKENS.jsonl` hook, the agent apps' own stores, and
retention settings. It reads only. Tell the user what it found, because the
cutover plan retires exactly the SpecStory and ledger hooks that discovery
sees.

## 2. Check that tellem captures what SpecStory does

```sh
tellem shadow status
tellem parity --all
```

Read the last lines of the `parity` output. The takeover needs the last 20
shadowed Claude sessions that have a SpecStory or ledger reference, and the
last 5 Codex sessions when there are any, all at `parity`. A session that is
still open counts as `pending` and keeps the criteria unmet. That includes the
session you are running in, so a final parity check is best read by the user
from a plain terminal with no agent session open.

If the criteria are unmet:

- Fewer sessions than required: keep working with both running. The line says
  how many more passing sessions are needed.
- A failing session: run `tellem parity --all --json` and read its `causes`.
  Docs for each accepted difference are in the Parity section of
  `docs/ops/tellem.md`. A cause that is not accepted there is a finding to
  report to the user, not something to wave through. Do not use
  `--accept-parity` to get past it unless the user asks.

Do not go on until the criteria read `met`.

## 3. Back up before retention can delete anything

Cutover turns on native retention. After the window (14 days by default,
`retention.native_days`), tellem removes the native Claude transcript files of
each session it has verified, and that includes sessions from before the
cutover. tellem keeps its own redacted Markdown copy, but that is not the
native JSONL, and resume and rewind need the native one. Nothing tellem does
backs up the originals, so back them up first.

Ask the user where the backup should go, and check the space before copying:

```sh
du -sh ~/.claude/projects ~/.codex/sessions
df -h DESTINATION
```

With the user's yes, copy with `rsync -a` into a new, dated directory. Do not
use `--delete`, and never point the destination inside the source.

```sh
rsync -a ~/.claude/projects/ DESTINATION/claude-projects-DATE/
rsync -a ~/.codex/sessions/ DESTINATION/codex-sessions-DATE/
```

Also copy SpecStory's history, since retention does not touch it but the user
may later remove SpecStory. It lives in each repository's `.specstory/history`;
find the repositories with `tellem sessions --all --brief --no-derive --json`
and look for that folder under each `root`. Copy those folders the same way,
one directory per repository.

Verify the copy with a checksum dry run and read the result:

```sh
rsync -anc --itemize-changes ~/.claude/projects/ DESTINATION/claude-projects-DATE/
```

An empty list is a match. Files the running session is still writing may
differ; say so rather than hiding it.

## 4. Plan the cutover (a dry run)

```sh
tellem cutover plan
```

This changes nothing. It writes `plan.json`, `apply.patch`, and
`rollback.patch` under tellem's state directory in `cutover/<plan_id>/` and
prints the plan id. Show the user the whole output and the patches. It lists
every hook script and settings registration that captures with SpecStory or
`TOKENS.jsonl`, sets `cutover.state` to `cutover`, sets `retention.native` to
true, and states the retention window.

Two variants the user may want:

- `--specstory subsume` also retires the SpecStory wrapper functions and
  aliases from shell startup files and imports SpecStory history into tellem's
  record in the background. Open shells keep the old behaviour until they exit.
  Plan it as `tellem cutover plan --specstory subsume`.
- `--otel` adds the OpenTelemetry usage receiver. Leave it out unless asked.

Without `--claude` and `--codex`, both harnesses stay at `observe`, which
changes no transcript by itself; retention is what removes native files.

If the plan refuses, the refusal names its cause in `error.detail.cause`.
Apply refuses with `parity_unmet` when parity does not hold (go back to
step 2) and with `files_changed` or `plan_changed` when the host moved since
planning (plan again). The causes are in the Cutover and Authority levels
sections of `docs/ops/tellem.md`.

## 5. Apply, with the user's yes

Ask the user, showing the plan id and what apply changes: the hook
registrations it removes from `~/.ai`, the retention window, and that
retention is the step that removes native files. Only then:

```sh
tellem cutover apply --confirm PLAN_ID
```

Apply backs up every file it changes under the plan's `backup/` directory. It
never commits in `~/.ai`; if it prints git commands, give them to the user to
run. With `--specstory subsume` the history import starts in the background,
and `tellem cutover status` shows its progress. A failed import does not undo
the plan; `tellem doctor` reports a `history_import` finding and
`tellem cutover import --confirm PLAN_ID` resumes it.

Run apply from a terminal outside any agent session when the user can. The
agent session that runs it is itself open, and parity treats an open session
as pending.

## 6. Check the result

```sh
tellem cutover status
tellem config get cutover.state
tellem config get retention.native
tellem doctor
tellem retention
tellem parity --all
```

Expect `cutover.state` to be `cutover`, `retention.native` true, `doctor`
clean, and `retention` to list candidates and held sessions with causes. Tell
the user that the next derive of a scope removes the native files of every
verified session idle longer than the window, and that each removal appends a
receipt (path and sha256) to that scope's `.tellem/retention.jsonl`.

Useful dials, all the user's call:

- Longer window: `tellem config set retention.native_days DAYS`.
- Stop removals at once: `TELLEM_RETENTION_DISABLED=1`, or `tellem authority stop`.
- Turn retention off: `tellem config set retention.native false`. It cannot
  be turned back on with `config set`; only a new `tellem cutover plan` and
  apply does that, because only apply switches retention on.

## 7. Undoing it

Ask the user first, then `tellem cutover rollback --confirm PLAN_ID`. It
restores every `~/.ai` file byte for byte and sets `cutover.state` back to
`shadow`. Native transcripts that retention already removed are not restored;
the receipts name each one, and the backup from step 3 is where they come from.
Before cutover, `tellem config set features.capture false` or
`rplugin uninstall tellem` stops tellem and leaves scopes readable.

## Optional follow-ups, only if the user asks

- Importing old histories: `tellem import native`, `tellem import specstory
  --path P`, `tellem import ledger --path P`. Without `--confirm` each is a dry
  run that prints a plan id and exits 3.
- Removing SpecStory's own state: `tellem specstory remove --history keep`
  is a dry run. It refuses until the cutover state is `cutover` with SpecStory
  subsumed (`tellem cutover plan --specstory subsume`, applied) and SpecStory
  is no longer active. Applying it cannot be rolled back, and the user
  uninstalls the program themselves. Read the SpecStory removal section of
  `docs/ops/tellem.md` first.
- Higher levels (`spool`, `rehearse`, `own`) and `--purge`: they remove or stop
  writing native transcripts, so resume, rewind, and logs lose what they need.
  Read the Authority levels section of `docs/ops/tellem.md` with the user
  before planning one.
