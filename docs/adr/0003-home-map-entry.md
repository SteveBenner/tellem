# ADR-3: Session home fixed by the first hook

Status: accepted, from specs/tellem.impl.yml 0.2.0 (ADR-3).

## Decision

A session's home scope is fixed by the first hook of the session through an O_EXCL-created home map entry in tellem's state; later hooks read it.

## Alternatives considered

- recompute from cwd on every hook
- store home in the scope

## Rationale

Subagents and cd move the working directory; the record must stay whole in one scope (D-11). One small read per hook keeps cost flat.

## Consequences

- A session first seen in a subagent records a home_inferred gap
