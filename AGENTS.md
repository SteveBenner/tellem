# tellem

tellem is agent telemetry for Claude Code and Codex, built as a plugin on
rplugin, the SDK for agent-harness plugins. This file tells an agent how to work
on it. `CLAUDE.md` links to this file, so every harness reads the same text.

## Where things are

- `specs/tellem.app.yml` is the application contract: outcomes, scope, decisions
  (D-1 onward), and quality scenarios. A change to behavior starts there.
- `tellem.rplugin.yml` is the plugin manifest (schema `rplugin/v1`).
- `lib/tellem/` holds the library, `bin/tellem` the command, `bin/tellem-hook`
  the capture hook, and `hooks/` the hook wiring per harness.
- `docs/adr/` holds the architecture decisions, `docs/reference/` the record
  formats and harness payloads, and `docs/ops/tellem.md` the operator runbook.
- `skills/tellem/SKILL.md` is the skill agents load to read tellem's reports.

## Working rules

- Match the surrounding file's conventions. The code carries no comments.
- Code reaches every capability (secrets, events, state, registry, schedule)
  through `Rplugin::Ports.for("tellem", root: <plugin root>)`. Never call a host's
  service or read its files directly, and never copy rplugin's runtime into
  this plugin.
- The capture hook loads no gems and must stay inside its latency budget; work
  that needs the library runs in the deriver.
- Point `HOME`, `TELLEM_STATE_HOME`, `XDG_STATE_HOME`, `XDG_CONFIG_HOME`, and
  `CLAUDE_CONFIG_DIR` at scratch directories for any run that captures, derives,
  or installs, and pass `--scope` with scratch paths. A derive follows the paths
  a session recorded, so a session copied from a real home writes into real
  repositories unless its paths are rewritten first.
- Run `rplugin check tellem` and `tellem doctor` after a change, and read the
  output.
- `VERSION`, `tellem.rplugin.yml`, and the harness plugin manifests must agree.
  Every change lands in `CHANGELOG.md`, and every feature change in
  `FEATURES.md` with what was verified and how.
