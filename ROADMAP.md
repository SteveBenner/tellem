# Roadmap

Work deliberately left out of tellem 0.3.0, with what is already known. Codex
native retention left this list in 0.3.0: the authority levels (`spool`) cover
it for Codex, verified only as far as FEATURES.md says.

## Spec story and decision ledger

tellem records the life of every spec polispec has registered and one ledger of
governance decisions, with polispec as a buddy through bridge extensions: off by
default, metadata first, and redacted export. It only observes, so the "Policy
enforcement and Polispec feature constraints" non-goal stands, and O-11 still
holds.

## Public exclusion by remote visibility

tellem excludes roots by path prefix (`scope.exclude_roots`, D-28). A
repository whose origin is public but whose checkout sits outside every
excluded root still gets a `.tellem` scope. A visibility check of the origin
URL at scope location would treat it as excluded, and doctor would report an
excluded scope whose directory is gone as retired rather than dangling.

## Dashboard server and later views

`tellem dashboard` writes one file (D-42). Left for later: a local server that
reads on demand, which needs a second loopback listener in the specification,
and views of tasks, places, messages, and transcripts. Reading a database mirror
is left out as well.

## Other harnesses

Hermes, Pi, the DeepSeek TUI, and Antigravity. tellem 0.2.0 reads only Claude
Code and Codex transcripts and hook payloads, and installs only into those two
(`extensions.only: [claude-code, codex]`). Each new harness needs its
transcript reader behind the harness port, its hook payload keys recorded in
`docs/reference/harnesses.md`, and its id added to `extensions.only`.

## Aggregation across hosts

A shared PostgreSQL mirror is the expected path. Mirror rows are keyed by
`(scope_id, id)` and scope ids already include the host, so several hosts can
feed one database. Open points: credentials per host through the secrets
port, and how reports pick scopes from other hosts whose files are not local.

## Codex OpenTelemetry details

Codex has its own OTLP/HTTP exporter with request and stream events. Before
building a receiver path for it, measure what its events carry against a
rollout, as D-16 did for Claude Code, and decide finality without a
session end.

## Per-repository authority levels

An authority level is per harness for the whole host (D-22). A repository whose
transcripts must stay in the harness, or one that may have them removed, cannot
differ from the rest. A project-level harness setting could scope a level; the
plan, its readers, and rollback would need a per-repository form.

## Windows

tellem has been built and run only on Linux. The hook, the state home, the
harness stores, the wrapper and startup-file discovery, and the process and
timer discovery all assume a POSIX host, and macOS was never run. Windows needs its own harness path
conventions behind the harness port and a verified hook launch; a plugin that
ships a Ruby kit for Windows could run tellem on it.

