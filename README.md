# tellem

A flight recorder for coding agents, built as an rplugin plugin for Claude
Code and Codex. It records which agents and subagents ran, who spawned whom,
where each one lived, stood, worked, and reached, what the provider reported
it spent, which persona it was, what state it was in, and what it said, so any
session can be reconstructed as a tree of agents moving through places. It
needs nothing but the filesystem and can mirror into SQLite or PostgreSQL.

## How it works

- A hook appends one metadata line per event to `.tellem/` in the repository
  where the session started. It loads no gems and never blocks the agent.
- A detached deriver turns those lines and the harness's native transcripts
  into the agent tree, places, pointers in every other repository a session
  touched, tokens, persona evidence, state, messages between agents, and
  Markdown transcripts. Each agent's wall, active, waiting, and spawn-to-stop
  time is computed from that record when a report asks.
- The CLI answers from those files, or from a mirror when one is provisioned,
  with the same output either way.
- With `tasks.mode` on (the default), the deriver also groups a person's
  prompts into tasks by the rules of a prompt-grouping task clock (the
  `tasks.*` settings), and `tellem tasks` shows each task's time beside its
  tokens. It is telemetry
  only: tellem adds no hook, marker reply, or status line for tasks.

## Use

```sh
tellem tree                      # agents and subagents of each session here, with time and messages
tellem messages                  # what agents said to each other, joined across sessions
tellem where main --descendants  # where each agent lived, worked, and reached
tellem sessions --repo PATH      # sessions that worked in a repository
tellem sessions --all --brief --no-derive --json  # one fast row per session, no derive pass
tellem tokens --by agent,model   # provider-reported tokens
tellem spans --session S --json  # timed requests, tool calls, subagents, and task turns
tellem state main                # lifecycle, context, workspace, and time
tellem health                    # hook latency, gaps, derive lag
tellem doctor                    # what is wrong and the next command
```

Every command takes `--json`. Every read verb takes `--no-derive`, which skips the
derive pass and answers from the record already derived; `derive` reads
`{"status": "skipped"}`. Hooks keep deriving. `tellem sessions --brief [--since T] [--limit N]`
lists one row per session, newest first, from the session-level records only:
`session_key`, `root`, `harness`, `started_at`, `ended_at`, and `label`, the redacted
head (at most 80 characters) of the session's first task name, or null. The operator runbook is
[docs/ops/tellem.md](docs/ops/tellem.md); the agent skill is
[skills/tellem/SKILL.md](skills/tellem/SKILL.md).

## Install

tellem needs Ruby 3.3 or newer, git, and [rplugin](https://github.com/SteveBenner/rplugin).

```sh
git clone --recurse-submodules https://github.com/SteveBenner/rplugin ~/.rplugin
git clone https://github.com/SteveBenner/tellem ~/.rplugins/tellem
~/.rplugin/bin/rplugin install tellem
~/.rplugin/bin/rplugin doctor tellem
```

The feature defaults are on, so the first SessionStart after installing turns
capture on. Capture then runs in shadow beside any capture that was already
there, such as SpecStory or a token ledger hook. `TELLEM_DISABLED=1`,
`tellem config set features.capture false`, and a scope's own capture-off
setting each keep capture off. Taking over from an incumbent is a separate
reviewed step (`tellem cutover plan`).

## Transcript takeover

0.3.0 adds the commands that let tellem replace what SpecStory and the
harnesses' own transcripts do, each behind a reviewed plan or an off-by-default
setting:

```sh
tellem transcripts discover                  # every transcript method on this host, read-only
tellem authority status                      # each harness's level: observe, spool, rehearse, own
tellem cutover plan --claude spool           # plan a level (also --codex, --specstory subsume, --purge)
tellem cutover apply --confirm PLAN_ID       # apply it; rollback and import take the same form
tellem specstory remove --history keep       # plan removing SpecStory; status shows drift
tellem export --session KEY --after CURSOR   # whole, redacted entries for another plugin
tellem sync --session KEY                    # make a session's entries current now
tellem forget --session KEY                  # remove entries after a confirmed plan
```

A plain install stays at `observe`, with entries off and SpecStory untouched.
tellem needs Ruby 3.3 or newer; below it `bin/tellem` and the hook say so and
stop. A plugin that must read tellem's records declares the `transcript_policy`
port to withhold tool content and name its readers.

## Status

The version is in [VERSION](VERSION). Built and verified in containers and
isolated homes. The maintainer's host runs tellem in shadow mode since
2026-11-06. No import, cutover, retention, level above `observe`, or SpecStory
removal was applied anywhere real, and tellem's Codex hooks are not trusted in
Codex. See [FEATURES.md](FEATURES.md) for what is verified and how, and what
was not run.

## Documentation

- [Record formats](docs/reference/formats.md)
- [Harness versions and payloads](docs/reference/harnesses.md)
- [Architecture decisions](docs/adr/)
- [Application specification](specs/tellem.app.yml)
- [Contributing](CONTRIBUTING.md) and [security reports](SECURITY.md)

## License

MIT. See [LICENSE](LICENSE).
