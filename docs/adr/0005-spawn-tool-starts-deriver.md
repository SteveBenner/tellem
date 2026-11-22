# ADR-5: The spawn tool call starts the deriver

Status: accepted, from specs/tellem.impl.yml 0.2.0 (ADR-5); amended in 0.2.13.

## Decision

A post_tool on the spawn tool (Claude Task or Agent; the Codex spawn tool as observed) starts the deriver, and the deriver marks a subagent stopped when its transcript ends or its parent session stops.

Amended 2026-10-22 after rplugin 1.18.0 added subagent_stop. On Claude Code a subagent_stop hook appends one metadata observation carrying agent_id, agent_type, and agent_transcript_path and starts the deriver, which marks that subagent stopped at once. The spawn-tool path stays for Codex, which has no such event, and as a fallback. The manifest requires rplugin 1.18.0 or later.

## Alternatives considered

- write harness hook files by hand
- wait for an upstream change

## Rationale

rplugin forbids hand-written harness hook files. Synchronous subagents finish before their spawn call returns; background subagents were caught only at the next stop, session_end, query, or sync until rplugin gained the event.

## Consequences

- Background subagent lifecycle is exact on Claude Code and still lags until the next derivation on Codex
- tellem needs rplugin 1.18.0 or later
