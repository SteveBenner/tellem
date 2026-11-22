# ADR-1: Minimal hook entrypoint

Status: accepted, from specs/tellem.impl.yml 0.2.0 (ADR-1).

## Decision

The hook entrypoint is bin/tellem-hook run as `ruby --disable-gems`, registered without an rplugin `when:` gate, and it loads only Ruby core, json, the hook core, and Rplugin::Paths.

## Alternatives considered

- load the full tellem library
- use an rplugin when gate
- a shell script

## Rationale

Measured 2026-10-21. Bare --disable-gems append with fsync p99 8.6 ms at load 4; with json, a 250 KB payload, flock, and fsync p99 20.3 ms at load 33; default gems 41 ms; the prior foundation 53 ms; the when gate adds about 10 ms as a second Ruby process. A shell script cannot parse JSON safely.

## Consequences

- The kill switch is the env var plus a flag file the CLI keeps in step with the capture setting
- The hook core must stay free of yaml and gem dependencies
