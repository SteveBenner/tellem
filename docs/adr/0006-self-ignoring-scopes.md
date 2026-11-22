# ADR-6: Each scope ignores itself

Status: accepted, from specs/tellem.impl.yml 0.2.0 (ADR-6).

## Decision

Each .tellem/ directory carries its own .gitignore containing '*'.

## Alternatives considered

- edit the repository's .gitignore
- write .git/info/exclude

## Rationale

It keeps a scope out of git (D-9) without editing any tracked or git-internal file of a repository tellem does not own.

## Consequences

- git add -f can still force a file in, and that is the operator's explicit act
