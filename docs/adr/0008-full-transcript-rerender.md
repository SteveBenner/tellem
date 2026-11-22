# ADR-8: Transcripts re-rendered in full

Status: accepted, from specs/tellem.impl.yml 0.2.0 (ADR-8).

## Decision

Transcripts are re-rendered in full from the native transcript whenever its inode, size, or mtime changes, and replaced atomically; once the native file is gone the Markdown is final.

## Alternatives considered

- incremental Markdown appends

## Rationale

Claude rewrites streamed messages under one message id; a full deterministic render is the only way to keep rebuilds byte-stable.

## Consequences

- Derive cost grows with transcript size; NFR-P-4 bounds it
