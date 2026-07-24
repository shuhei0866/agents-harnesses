# Agent Harness Flight Recorder architecture

## Product definition

Agent Harness Flight Recorder is a local-first, user-owned Evidence Vault for
work performed through coding-agent harnesses. It records privacy-safe evidence
without requiring developers to rate each interaction, then turns that evidence
into inspectable work episodes.

The product must be useful to one person before any shared marketplace or model
router exists.

## Invariants

- Recorder failure must never block the observed harness.
- Prompts, code, commands, tool output, and transcript contents are not persisted
  by default.
- Plaintext events and private keys are never committed to Git.
- Git is one synchronization transport, not the vault format.
- The SQLite index and episode views are derived and can be rebuilt.
- Episode grouping and evaluation use versioned policies and can be recomputed.
- Automatic evaluation does not gain access to artifact contents by default.
- External sharing is not required for the vault to return value to its owner.

## Architecture

```text
Claude Code / Codex
        |
        | lifecycle hooks
        v
privacy allowlist + canonical Event v1
        |
        v
local append-only events.jsonl
        |
        | rotate
        v
immutable device-scoped chunks
        |                         +-----------------------+
        | index                   | versioned policies    |
        +-----------------------> | episode relationships |
        |                         | evidence evaluation   |
        |                         +-----------+-----------+
        |                                     |
        v                                     v
age encryption                         local SQLite index
        |                                     |
        v                                     v
private Git remote                    status/report/inspect
```

## Local and synchronized state

The exact platform state directory is configurable. A representative vault is:

```text
vault/
├── config.json
├── inbox/
│   └── events.jsonl
├── chunks/
│   └── <device-id>/YYYY/MM/DD/<chunk-id>.jsonl
├── encrypted/
│   └── <device-id>/YYYY/MM/DD/<chunk-id>.jsonl.age
├── index/
│   └── vault.sqlite
├── keys/
│   ├── device.agekey
│   └── correlation-key.age
└── queue/
    └── pending-sync.json
```

Only encrypted immutable chunks and non-sensitive format metadata are eligible
for the private Git repository. The device secret key, plaintext inbox, decoded
chunks, and SQLite index remain local.

The Git layout avoids shared mutable files:

```text
devices/
├── <device-a>/YYYY/MM/DD/<chunk-id>.jsonl.age
└── <device-b>/YYYY/MM/DD/<chunk-id>.jsonl.age
```

## Identity and key model

Each vault has:

- a random `vault_id`;
- a random `device_id` for every enrolled device;
- a separate age identity on each device;
- an offline recovery recipient;
- one vault-wide HMAC correlation key encrypted to all current recipients.

The correlation key creates stable pseudonymous identifiers across devices.
Raw workspace, session, and turn identifiers are not synchronized.

Adding a device means adding its age recipient and re-encrypting the small vault
key envelope. Device private keys are never copied through the Git repository.

## Rotation and manual synchronization

The first release exposes explicit synchronization:

```text
flight-recorder sync
  1. lock the local inbox
  2. rotate complete events into a unique immutable chunk
  3. validate the chunk schema
  4. encrypt the chunk to enrolled age recipients
  5. commit only the encrypted device-scoped file
  6. pull --rebase and push
  7. retain failed work in the local retry queue
```

Chunks are content-addressed or randomly identified and are never edited after
publication. Import decrypts unseen chunks and rebuilds derived state
idempotently.

The next release runs the same operation once per day through `launchd` on macOS
and a `systemd` timer on Linux. Failures use backoff and remain invisible during
normal harness operation; prolonged failures are visible through
`flight-recorder status`.

## Work episode model

Event identity is a gradient. Events are therefore not destructively assigned
to a permanent episode. The index stores versioned relationship evidence:

```text
event A -- 0.95 --> event B  same workspace, branch, and short time gap
event B -- 0.72 --> event C  same workspace and branch, longer gap
event C -- 0.40 --> event D  same branch on a later day
```

Initial deterministic features include:

- explicit issue or task identifier when safely available;
- HMAC workspace identifier;
- HMAC branch or worktree identifier;
- time distance;
- allowlisted changed-file fingerprints;
- contradictory explicit task identifiers.

A versioned policy converts these edges into a derived episode view. Weight and
threshold changes create a new view without rewriting source events.

## Evaluation

Evaluation is layered by cost and privacy:

1. Deterministic evidence: test, build, lint, exit status, commit, pull request,
   retry count, duration, token use, and measured cost when available.
2. On-demand delayed evaluation: the owner selects an episode and explicitly
   permits any additional artifact scope required by a model.
3. Background evaluation: a later release evaluates uncertain episodes from
   metadata by default. Artifact access remains an explicit workspace policy.

Stored evaluation provenance includes the rubric version, evaluator and model,
timestamp, evidence identifiers, artifact hashes, conclusions, and confidence.
Artifact bodies and evaluator input transcripts are not persisted by default.

## User interface

The first interface is a stable CLI that agent harnesses can also invoke:

```text
flight-recorder status
flight-recorder report --last 7d
flight-recorder inspect <episode-id>
```

The primary output is an Episode Evidence Card containing task type, model,
duration, measured cost, deterministic outcomes, retry count, confidence, and
supporting evidence. A dashboard is not required for the first value test.

## Retention and deletion

Privacy-safe encrypted events are retained until the owner deletes them. Normal
analysis deletion is a tombstone-like `forget` operation in derived state.

`purge` removes matching local data and rewrites the dedicated private data
repository so encrypted chunks are removed from Git history. It is explicit,
destructive, and must show the affected scope before applying. Remote-provider
caches and independent clones mean purge is best-effort beyond repositories the
owner controls; the CLI must state this limitation clearly.

## Release boundaries

### R1: Evidence Vault

- vault initialization, device identity, recipients, and recovery key;
- JSONL rotation, schema validation, age encryption, and manual Git sync;
- deterministic local SQLite rebuild;
- versioned episode relationship policy;
- `status`, `report`, `inspect`, Evidence Cards, `forget`, and `purge`.

### R1.1: Unconscious Sync

- daily `launchd` and `systemd` scheduling;
- durable retry queue, backoff, and sync-health reporting.

### R1.2: Evaluation

- deterministic evidence collectors;
- on-demand delayed model evaluation with provenance;
- metadata-only background evaluation for uncertain episodes.

### Later

- selected, privacy-reviewed episode export;
- aggregate signals and incentive design;
- context-aware model and skill routing.

External sharing, a marketplace, automatic artifact-content evaluation, and a
hosted Flight Recorder cloud are outside R1 through R1.2.
