# ADR-4: No pre_tool hook

Status: accepted, from specs/tellem.impl.yml 0.2.0 (ADR-4).

## Decision

There is no pre_tool hook. post_tool carries the cwd, tool input, and outcome; denials and failures come from transcripts.

## Alternatives considered

- pre_tool and post_tool

## Rationale

It halves per-tool hook cost; nothing location-related is only visible before the call.

## Consequences

- A tool call that never completes appears only in the transcript
