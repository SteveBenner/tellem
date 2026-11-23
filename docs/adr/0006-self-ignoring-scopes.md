# ADR-6: Each scope ignores itself

Status: accepted, from specs/tellem.impl.yml 0.2.0 (ADR-6). Amended in 0.5.8 by app D-37: the `*` is the state a scope is created in, not its resting state.

## Decision

Each .tellem/ directory carries its own .gitignore. It is created containing '*', so a new scope is ignored until the deriver reconciles it. A reconcile then makes the file match the scope's visibility: '*' when the scope declares `visibility public`, and only the volatile files when it is private, which is the default from 0.5.8.

## Alternatives considered

- edit the repository's .gitignore
- write .git/info/exclude

## Rationale

A file inside the scope lets tellem control what git sees without editing any tracked or git-internal file of a repository tellem does not own. Starting at '*' fails closed on the hook path, which never reads visibility.

## Consequences

- git add -f can still force a file in, and that is the operator's explicit act
- Since 0.5.8 a pointer scope in a repository tellem does not own is private by default, so its pointer files show as untracked there until the repository declares `visibility public` or the operator ignores them
