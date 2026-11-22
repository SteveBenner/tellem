# ADR-9: Mirrors fed only by the deriver

Status: accepted, from specs/tellem.impl.yml 0.2.0 (ADR-9).

## Decision

Mirrors are fed only by the deriver and rebuilt only from files; reports use a mirror only when its lag for the queried scopes is zero.

## Alternatives considered

- reports always from the mirror when configured

## Rationale

O-6 requires identical reports with or without a mirror.

## Consequences

- A lagging mirror is silently bypassed and the lag is shown in health
