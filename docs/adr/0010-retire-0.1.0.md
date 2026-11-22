# ADR-10: Retire the 0.1.0 build

Status: accepted, from specs/tellem.impl.yml 0.2.0 (ADR-10).

## Decision

The 0.1.0 build is retired. Its branches move to retired/0.1.0/*, the uncommitted slice 2 files are committed to their branch first, its worktrees are removed, and its code leaves main through git rm. Workers may read it as reference only.

## Alternatives considered

- build on the old foundation

## Rationale

The maintainer chose retirement on 2026-10-21; its registry and facades served ten features that no longer exist.

## Consequences

- Useful logic, such as Claude message-id deduplication and Codex counter handling in retired/0.1.0/slice_1_sources, is re-derived, not merged
