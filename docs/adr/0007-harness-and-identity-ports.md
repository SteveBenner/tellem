# ADR-7: Harness and identity ports

Status: accepted, from specs/tellem.impl.yml 0.2.0 (ADR-7).

## Decision

tellem declares two ports, harness and identity. The harness port's standalone class owns every harness and host path convention; the identity port's standalone class answers unknown, and the plugin-local extension extensions/persona backs it from the persona CLI's persona.session/v1 output.

## Alternatives considered

- hardcode ~/.claude and ~/.codex in the core
- call persona from the core

## Rationale

CLAUDE.md requires host access through SDK ports; DECOUPLE requires an application-owned port, an rStack-free default, and an extension for the binding.

## Consequences

- The hook reads only Rplugin::Paths and the harness port's pure path module, a documented latency exception
