# ADR-2: One raw file per agent under flock

Status: accepted, from specs/tellem.impl.yml 0.2.2 (ADR-2).

## Decision

Raw observations go to one file per agent, raw/<agent_key>.jsonl, written under flock(LOCK_EX) as a single write after sealing any torn tail with a newline, and the lock is then released. The hook does not fsync by default; the deriver fsyncs each raw file it reads (and the directory of a new one) before it persists its cursor. With the capture.fsync setting, mirrored to <state_dir>/capture.fsync, the hook fsyncs the file after unlocking and before it exits.

## Alternatives considered

- one file per session
- one file per process
- an O_APPEND write without a lock

## Rationale

Parallel tool calls of one agent are the only contention; 16 concurrent writers on one file measured p99 32.4 ms with 500 of 500 lines intact. Sealing keeps a killed writer's fragment from swallowing the next record. Holding the lock through fsync serializes every writer's flush; measured 2026-10-21 at load 23 with 16 writers x 25 appends, p99 was 29 to 41 ms with fsync inside the lock and 6 to 9 ms with fsync after unlock, 400 of 400 lines intact both ways. The seal check and write need the lock; durability does not, because fsync flushes every byte of the file written before it. The maintainer chose deferred flushing on 2026-10-21. A single append measured p99 19.6 ms with fsync and 0.6 ms without at moderate I/O, fsync stalled up to 2.3 s under heavy I/O, and the whole hook ran p99 54 to 88 ms under I/O pressure with per-hook fsync. A killed or crashed process loses nothing either way because the write is in the kernel; only a power loss or kernel crash before the next derive can lose observations, and native transcripts hold most of what they carried.

## Consequences

- Readers skip unparseable lines and count them as torn-line gaps
- Hook cost does not depend on file size because only the last byte is read
