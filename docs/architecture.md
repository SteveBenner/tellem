# tellem architecture

This document is for people who work on tellem or build on its records. It
describes the components, the runtime paths, the storage layout, and the
control plane, with the module that implements each step. The normative record
formats are in [`specs/tellem.yml`](../specs/tellem.yml); the behaviour
contract is [`specs/tellem.app.yml`](../specs/tellem.app.yml); the reasons are
in [`adr/`](adr/).

Contents:

1. [System context](#1-system-context)
2. [Components](#2-components)
3. [Capture path: one hook invocation](#3-capture-path-one-hook-invocation)
4. [Scope resolution](#4-scope-resolution)
5. [Derive path](#5-derive-path)
6. [Read path: a report](#6-read-path-a-report)
7. [Storage layout and record relationships](#7-storage-layout-and-record-relationships)
8. [Durability and concurrency](#8-durability-and-concurrency)
9. [Authority levels](#9-authority-levels)
10. [Cutover plan and apply](#10-cutover-plan-and-apply)
11. [Invariants](#11-invariants)

## 1. System context

```mermaid
flowchart LR
  person([Person])
  subgraph harness[Agent harness]
    cc[Claude Code]
    cx[Codex]
  end
  subgraph tellem[tellem plugin]
    hook[tellem-hook]
    deriver["deriver<br/>bin/tellem derive --detached"]
    cli[bin/tellem CLI]
    skill[agent skill<br/>skills/tellem/SKILL.md]
  end
  subgraph files[Files tellem owns]
    scope[(#lt;repo#gt;/.tellem/<br/>per scope)]
    state[(state dir<br/>user scope, homes, registry,<br/>authority, cutover)]
  end
  native[(native transcripts<br/>~/.claude/projects, Codex rollouts)]
  incumbent[(SpecStory history,<br/>token ledger)]
  mirror[(SQLite / PostgreSQL<br/>mirror, optional)]
  sdk[[rplugin ports<br/>settings, state, events]]

  person -- asks --> cc
  cc -- lifecycle hooks --> hook
  cx -- lifecycle hooks --> hook
  hook -- append --> scope
  hook -- spawn --> deriver
  deriver -- read --> scope
  deriver -- read --> native
  deriver -- write views --> scope
  deriver -- write --> state
  deriver -- feed --> mirror
  deriver -- events --> sdk
  cc -- loads --> skill
  skill -- runs --> cli
  cli -- read --> scope
  cli -- read --> mirror
  cli -- parity reads --> incumbent
  cli -- settings --> sdk
```

| Element | Responsibility | Never does |
|---|---|---|
| `tellem-hook` | Append one metadata line per lifecycle event; spawn the deriver on boundary events | Load gems, read transcripts, block on a lock it does not own, fail the harness |
| deriver | Turn raw lines and native transcripts into derived records, transcripts, pointers, views, mirror rows | Run inside the harness's process tree; write outside the scopes a session touched and tellem's state |
| CLI | Answer reports from derived records or a mirror; plan and apply control changes | Mutate a record outside a confirmed plan |
| skill | Map a question to the command that answers it | Edit `.tellem/` |

## 2. Components

```mermaid
flowchart TB
  subgraph entry[Entry points]
    binhook[bin/tellem-hook]
    bincli[bin/tellem]
  end
  subgraph capture[Capture, no gems]
    hmain[hook/main]
    hextract[hook/extract]
    hfirst[hook/first_start]
    hspawn[hook/spawn]
    hcore[record/hook_core]
  end
  subgraph record[Record layer]
    rscope[record/scope]
    rformats[record/formats<br/>record/kinds<br/>record/schemas]
    rwriter[record/writer]
    rreader[record/reader]
    rlock[record/lock]
    rptr[record/pointers<br/>record/registry]
  end
  subgraph derive[Derive]
    drun[deriver/run]
    dpass[deriver/pass]
    dsteps[locations, samples, transcripts,<br/>alignment, reach, persona,<br/>lifecycle, usage, messages,<br/>entries, pointing, tasks]
  end
  subgraph read[Read]
    cmds[commands/*]
    reports[reports/*]
    backends[backends/*]
    projections[projections/*]
  end
  subgraph control[Control plane]
    authority[authority/*]
    cutover[cutover/*]
    parity[parity/*]
    retention[retention/*]
    specstory[specstory/*]
    discovery[discovery/*]
  end
  config[config/resolver]
  ports[ports/*<br/>Rplugin::Ports]

  binhook --> hmain
  hmain --> hextract & hfirst & hspawn & hcore
  hcore --> rscope & rformats
  bincli --> cmds
  cmds --> reports & control
  hspawn -. process .-> bincli
  cmds --> drun
  drun --> rlock & dpass
  dpass --> dsteps
  dsteps --> rwriter & rreader & rptr
  reports --> rreader & backends
  dpass --> projections & backends
  control --> parity
  cutover --> authority
  config --> ports
  dpass --> config
  cmds --> config
```

The hook path (`hook/*`, `record/hook_core`, `record/scope`, `record/formats`)
loads with `ruby --disable-gems` and must stay inside the latency budget that
`tellem health` reports (`hook_ms` p99 under 50 ms). Everything that needs the
library runs in the deriver or the CLI.

## 3. Capture path: one hook invocation

The harness runs `tellem-hook <event> <harness>` with the event payload on
stdin. `SessionStart`, `UserPromptSubmit`, `PostToolUse`,
`PostToolUseFailure`, `SubagentStart`, and `SubagentStop` run it with
`async: true` and a 30 s timeout; `Stop` and `SessionEnd` run it synchronously
with a 2 s timeout so the last lines land before the harness exits.

```mermaid
sequenceDiagram
  autonumber
  participant H as Harness
  participant K as hook/main
  participant C as record/hook_core
  participant F as raw/#lt;agent_key#gt;.jsonl
  participant G as hook-gaps.jsonl
  participant D as deriver (detached)

  H->>K: argv event harness, stdin payload
  K->>C: capture_enabled?
  alt flag absent and first start pending
    K->>K: FirstStart.sync writes capture.enabled
  end
  K->>K: read stdin bounded to RECORD_BYTES, parse JSON
  K->>K: Extract.fields, session_key, agent_key
  K->>C: read homes/SESSION_KEY or Scope.locate(cwd)
  K->>C: capture_enabled?(scope root)
  K->>C: home_for(session_key, cwd)
  K->>F: append one tellem.raw/v1 line (flock, torn-tail guard)
  opt inferred home, moved home, unrecognized shape
    K->>G: append a content-free gap
  end
  opt event is stop, session_end, subagent_stop, or a spawn tool's post_tool
    K-)D: Process.spawn bin/tellem derive --scope ROOT --detached (own process group)
  end
  K-->>H: exit 0
```

Every refusal or error on this path becomes a gap record and exit 0. The hook
never makes the harness fail.

```mermaid
flowchart TD
  start([tellem-hook event harness]) --> on{capture flag<br/>present?}
  on -- no --> first{session_start and<br/>first start pending?}
  first -- no --> exit0([exit 0])
  first -- yes --> sync[FirstStart.sync] --> on2{flag present now?}
  on2 -- no --> exit0
  on2 -- yes --> known
  on -- yes --> known{harness known?}
  known -- no --> g1[gap unknown_harness] --> exit0
  known -- yes --> ev{event in RAW_EVENTS?}
  ev -- no --> g2[gap unknown_event] --> exit0
  ev -- yes --> rd{payload within<br/>RECORD_BYTES?}
  rd -- no --> g3[gap over_limit] --> exit0
  rd -- yes --> js{JSON object?}
  js -- no --> g4[gap payload_not_object] --> exit0
  js -- yes --> sid{valid session_id<br/>and agent id?}
  sid -- no --> g5[gap invalid_session_id<br/>or invalid_agent_id] --> exit0
  sid -- yes --> root[resolve scope root] --> off{capture.off in scope<br/>or TELLEM_DISABLED?}
  off -- yes --> exit0
  off -- no --> app[append raw line] --> sp{derive-triggering<br/>event?}
  sp -- yes --> spawn[spawn detached deriver] --> exit0
  sp -- no --> exit0
  app -. exception .-> g6[gap with error class] --> exit0
```

## 4. Scope resolution

A scope is where a session's record lives: the main working tree of a git
repository, or the user scope under tellem's state dir. The first hook of a
session fixes it in `homes/<session_key>`, so every later event of that session,
from any directory, lands in the same scope.

```mermaid
flowchart TD
  a([hook has cwd and session_key]) --> h{homes/session_key<br/>exists?}
  h -- yes --> ex{its root now under<br/>scope.exclude_roots?}
  ex -- yes --> user[user scope<br/>gap home_moved_excluded]
  ex -- no --> keep[that root]
  h -- no --> walk[real path of cwd,<br/>walk up to first .git]
  walk --> found{.git found?}
  found -- no --> user2[user scope]
  found -- dir --> r1[that directory]
  found -- file --> wt{gitdir common dir<br/>named .git?}
  wt -- yes --> r2[parent of common dir<br/>linked worktree folds into main tree]
  wt -- no --> r3[directory holding .git file<br/>submodule]
  r1 & r2 & r3 --> exc{covered by<br/>scope.exclude_roots?}
  exc -- yes --> user2
  exc -- no --> root[repository scope]
  root & user2 --> claim[create homes/session_key exclusively<br/>inferred unless main agent's session_start]
```

No git process runs on this path. Other repositories a session touches do not
become its home; the deriver writes a pointer into each of them instead
(section 7).

## 5. Derive path

`bin/tellem derive --scope ROOT` (`deriver/run`) is started detached by the hook
and in-process by a report's refresh. One deriver works on a scope at a time.

```mermaid
flowchart TD
  s([derive ROOT]) --> en{features.derive on?}
  en -- no --> dis([status disabled])
  en -- yes --> lk{flock derive.lock<br/>non-blocking}
  lk -- held --> dirty[touch derive.dirty] --> w{"wait requested?"}
  w -- no --> d0([status dirty])
  w -- yes --> wi[wait for idle, up to 10 s] --> d1([status waited or busy])
  lk -- acquired --> p1[clear derive.dirty<br/>run one Pass]
  p1 --> again{derive.dirty set again<br/>and fewer than 3 extra passes?}
  again -- yes --> p1
  again -- no --> tasks[derive tasks] --> emit[emit tellem.derive.completed<br/>through the events port] --> rel[release lock] --> ok([status ran])
```

A held lock is never waited on by the hook path: the second deriver marks the
scope dirty and exits, and the holder runs again before it releases. A burst of
hooks therefore costs at most four passes per scope.

```mermaid
flowchart LR
  subgraph P[One Pass, deriver/pass]
    direction TB
    c[config<br/>sync capture and fsync flags] --> au1[authority watch, before]
    au1 --> raw[raw<br/>scan raw files from the cursor,<br/>plus sessions with unrendered transcripts]
    raw --> pl[places] --> ws[workspace samples] --> tr[transcripts<br/>ingest native, render Markdown,<br/>derive entries]
    tr --> al[alignment] --> re[remote reach] --> pe[persona] --> lc[lifecycle + usage] --> ms[messages]
    ms --> pt[pointers<br/>write into touched scopes,<br/>reconcile .gitignore]
    pt --> au2[authority watch, after<br/>liveness, capture_lost]
    au2 --> rg[registry + cursor save]
    rg --> rt[retention, specstory prevent]
    rt --> pj[projections<br/>views/TOKENS.jsonl]
    pj --> mi[mirror feed]
  end
```

Each per-session step runs inside a guard: an exception marks that session
failed for the rest of the pass, records a `derive_error` gap, and leaves the
other sessions and the cursor of the failed one untouched, so the next pass
retries it. Derived records are flushed after every step.

## 6. Read path: a report

```mermaid
sequenceDiagram
  autonumber
  participant U as Agent or person
  participant C as commands/#lt;verb#gt;
  participant S as reports/scopes
  participant R as reports/refresh
  participant D as deriver/run
  participant M as reports/mirror
  participant F as derived files

  U->>C: tellem VERB with --scope P or --all, --no-derive, --json
  C->>S: resolve scopes (cwd, --scope, or registry for --all)
  alt --no-derive
    C->>R: run(skip: true) returns status skipped
  else
    C->>R: run(scopes)
    par worker thread, joined for up to 10 s
      loop each live scope
        R->>D: run(root, wait: true)
      end
    end
    Note over R: past 10 s: derive status timeout,<br/>or Busy with --strict
  end
  C->>M: current mirror for these scopes?
  alt mirror provisioned and healthy
    M-->>C: rows from SQLite or PostgreSQL
  else
    C->>F: scan derived.jsonl per session (parallel workers)
    F-->>C: rows
  end
  C-->>U: text table, or tellem.report/v1 envelope with data, derive, source
```

Files and mirror return the same rows for the same query; `source:` in the
footer (or `source` in JSON) says which answered. `--all` reads the scope
registry, so it reaches every repository a session ever lived in or pointed to.

## 7. Storage layout and record relationships

```mermaid
flowchart TB
  subgraph repo[#lt;repo#gt;/.tellem/ — a repository scope]
    sj[scope.json<br/>tellem.scope/v1]
    cfg[config.yml]
    subgraph sess[sessions/#lt;session_key#gt;/]
      raw[raw/#lt;agent_key#gt;.jsonl<br/>tellem.raw/v1, hook]
      der[derived.jsonl<br/>tellem.derived/v1, deriver]
      bod[bodies/*.jsonl]
      ent[entries/#lt;agent_key#gt;.jsonl<br/>tellem.entry/v1]
      md[transcripts/*.md]
    end
    ptr[pointers/#lt;session_key#gt;.json<br/>tellem.pointer/v1]
    vw[views/TOKENS.jsonl]
    cur[derive.lock, derive.dirty,<br/>derive.cursor.json]
  end
  subgraph st[state dir]
    flag[capture.enabled, capture.fsync,<br/>scope.exclude_roots]
    homes[homes/#lt;session_key#gt;<br/>tellem.home/v1]
    reg[registry.jsonl]
    gaps[hook-gaps.jsonl]
    us[user/.tellem/<br/>the user scope, same layout]
    auth[authority/<br/>tellem.authority/v1]
    cut[cutover/#lt;plan_id#gt;/<br/>tellem.cutover/v1]
    spool[bodies/ spool]
  end
  homes -- names root of --> repo
  ptr -- points to home of --> sess
  reg -- lists --> repo
  raw -- joined with native transcript into --> der
  der -- rendered into --> md
  der -- projected into --> vw
  spool -- ingested and redacted into --> bod
```

```mermaid
erDiagram
  SCOPE ||--o{ SESSION : "is home of"
  SCOPE ||--o{ POINTER : "holds"
  POINTER }o--|| SESSION : "refers to"
  SESSION ||--|{ AGENT : "has (main + subagents)"
  AGENT ||--o{ RAW_OBSERVATION : "hook appends"
  SESSION ||--o{ DERIVED_RECORD : "deriver appends"
  AGENT ||--o{ DERIVED_RECORD : "subject of"
  DERIVED_RECORD }o--o| PLACE : "located at"
  PLACE }o--o| REPOSITORY : "inside"
  AGENT |o--o{ AGENT : "spawned"
  HOME ||--|| SESSION : "fixes scope of"
```

Field-level definitions of each record, its kinds, identifiers, and bounds are
in [`specs/tellem.yml`](../specs/tellem.yml).

## 8. Durability and concurrency

```mermaid
sequenceDiagram
  participant W as Writer (hook or deriver)
  participant F as record file
  participant L as flock on the file

  W->>F: open O_RDWR|O_APPEND|O_CREAT|O_NOFOLLOW, 0600
  W->>L: LOCK_EX
  W->>F: read last byte
  alt last byte is not a newline (torn tail)
    W->>F: write newline first
  end
  W->>F: one write: record line + newline
  W->>L: LOCK_UN
  opt capture.fsync present, or the deriver
    W->>F: fsync file (and directory when new)
  end
```

| Concern | Mechanism |
|---|---|
| Concurrent hooks on one file | `flock(LOCK_EX)` per append, one `write` per line |
| A writer killed mid-line | next writer starts a new line; readers count the fragment as torn and skip it |
| Concurrent derivers on one scope | `derive.lock` non-blocking; loser sets `derive.dirty`; holder re-runs up to 3 extra passes |
| Replays | derived records carry content ids; `Writer.append_derived` appends only unseen ids |
| Reader progress | per-file cursor `{inode, offset}`; a changed inode or short file restarts at 0 |
| Crash before fsync | hook lines are in the kernel when `append` returns; the deriver fsyncs raw files before it saves a cursor |
| Whole-file replacement | `replace_atomic`: temp file in the same directory, fsync, rename, fsync directory |
| Symlink attacks | every record file and `.tellem` directory opened `O_NOFOLLOW`; a symlink is refused |

## 9. Authority levels

Authority says who holds a harness's transcript. Each harness has one level.
Raising it is a reviewed plan; lowering happens by plan, by rollback, or on its
own when capture is lost.

```mermaid
stateDiagram-v2
  state "prior level recorded at apply<br/>(observe when none)" as prior
  [*] --> observe
  observe --> spool: plan + apply<br/>readers accepted, parity full count
  observe --> rehearse: plan + apply (Claude)<br/>switches present
  observe --> own: plan + apply (Claude)<br/>switches present, body parity recorded<br/>at this version, parity full count
  spool --> own: plan + apply (Claude), same gates
  rehearse --> own: plan + apply (Claude), same gates
  spool --> prior: rollback, or capture_lost
  rehearse --> prior: rollback, or capture_lost
  own --> prior: rollback, or capture_lost
  prior --> [*]
```

A lost capture lowers the harness automatically to the level recorded before
the plan that raised it, writes a receipt to `authority/receipts.jsonl`, emits
`tellem.authority.lowered`, and raises a `tellem doctor` finding. The stop
switch (`tellem authority stop`) blocks every raise until
`tellem authority resume`.

| Level | Native transcript | tellem | Codex |
|---|---|---|---|
| observe | written and expired by the harness | reads it | yes |
| spool | written by the harness | removes each session's files once its record is verified | yes (ceiling) |
| rehearse | written by the harness | also captures request bodies, to prove body parity | no |
| own | not written | captures from the body spool only | no |

## 10. Cutover plan and apply

```mermaid
sequenceDiagram
  autonumber
  actor O as Operator
  participant P as cutover plan
  participant A as cutover apply
  participant Q as parity
  participant X as files and settings
  participant S as authority state

  O->>P: tellem cutover plan --claude LEVEL [--codex LEVEL] [--specstory ...]
  P->>P: discover transcript methods, validate request
  P->>Q: levels that remove native transcripts: full parity count per harness
  Q-->>P: met or parity_unmet (refuse)
  P->>X: compute edits, rollback patch, settings, dispositions
  P-->>O: plan id, plan.json, apply.patch, rollback.patch
  O->>O: read the plan
  O->>A: tellem cutover apply --confirm PLAN_ID
  A->>A: not already applied, every file has an edit or a reason
  A->>X: refuse when a planned file changed since planning
  A->>P: re-propose, refuse when the id differs (plan_changed or discovery_changed)
  A->>Q: parity gate when the plan edits capture hooks
  A->>X: back up every file, write edits, apply settings
  A->>S: record levels with their priors
  A-->>O: applied, rollback is tellem cutover rollback --confirm PLAN_ID
```

## 11. Invariants

1. The hook exits 0 for every input and never waits on a deriver.
2. The hook writes only raw lines, gap lines, a session's home file, and, on a
   pending first start, the capture flag or its settled marker.
3. Records are append-only; the only rewrites are whole-file atomic
   replacements of cursors, views, pointers, and settings mirrors.
4. Every timestamp is UTC RFC 3339 with milliseconds and `Z`, so string order
   is time order.
5. A derived record's id is a hash of its schema, kind, and identity fields, so
   deriving twice changes nothing.
6. Tokens are what the provider reported; a missing report is a gap, never an
   estimate.
7. Nothing leaves the machine except through a mirror the operator provisioned
   or the events port the host configured.
8. Nothing that removes native data runs without a confirmed plan whose id
   still matches the host.
