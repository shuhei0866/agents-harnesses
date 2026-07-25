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
privacy allowlist + canonical Event v1/v2
        |
        v
local append-only inbox/events.jsonl
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
├── vault.json
├── inbox/
│   ├── events.lock
│   └── events.jsonl
├── queue/
│   └── <rotation-id>.jsonl.pending
├── quarantine/
│   └── <rotation-id>.jsonl
├── devices/
│   └── <device-id>/YYYY/MM/DD/<digest>.jsonl.age
├── index/
│   └── vault.sqlite
├── keys/
│   ├── device.agekey
│   └── correlation-key.age
└── hash.key
```

Only encrypted immutable chunks, `vault.json`, `.gitignore`, and the encrypted
correlation-key envelope are eligible for the private Git repository. The
device secret key, plaintext inbox and retry queue, quarantine, `hash.key`,
decoded chunks, and SQLite index remain local.

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
key envelope. On the new device, `device join` generates a local identity and
device ID, decrypts the envelope through an already authorized identity, and
materializes the shared correlation key as a local-only `hash.key`. The
recipient registry is authenticated with that key before re-encryption. Device
private keys are never copied through the Git repository.

## Rotation and manual synchronization

The first release separates local rotation from synchronization:

```text
flight-recorder rotate
  1. verify the authenticated recipient registry
  2. take the stable inbox lock
  3. atomically rename each complete event generation into the retry queue
  4. release the inbox lock before validation and encryption
  5. quarantine invalid lines and preserve valid Event v1/v2 records in order
  6. derive a content ID from the Vault, device, and canonical event bytes
  7. encrypt the Chunk v1 JSONL to every enrolled age recipient
  8. publish one immutable device-scoped `.jsonl.age` file
  9. delete plaintext retry state only after successful publication
```

The hook and rotate command acquire the same stable `inbox/events.lock` before
opening the live data file, preventing stale-inode writes during rename. The
lock is not held during validation or age encryption, so a slow or failed
rotation does not block normal event capture.

Chunks are content-addressed and never edited after publication. A retry that
finds the same path decrypts and compares the existing artifact instead of
re-encrypting or overwriting it. A conflicting artifact fails closed while
retaining the plaintext pending source. Import decrypts unseen chunks and
rebuilds derived state idempotently.

Manual Git synchronization is layered on top of this format:

```text
flight-recorder sync
  1. rotate local pending events
  2. validate and commit only the explicit Vault allowlist
  3. record local pending-sync intent
  4. pull --rebase from the configured private remote
  5. re-authenticate Vault metadata and validate tracked chunks
  6. idempotently import unseen chunks into local-only derived state
  7. push without force and clear pending state only after success
```

The private remote is an untrusted transport. A tracked chunk is decrypted and
its path, header, Vault/device IDs, date, homogeneous Event v1 or v2 records,
count, and content
digest are verified before commit or import. Import receipts retain the Git
blob OID so a ciphertext replacement at an immutable path fails closed.
Rotation itself does not invoke Git or the network beyond the local `age`
process.

## Rebuildable evidence index

The SQLite index is a deterministic projection of receipt-selected canonical
Chunk v1 cache files. It is never a source of truth:

```text
encrypted immutable chunk (source evidence)
        |
        | validated by sync
        v
import receipt + canonical decoded cache
        |
        | rebuild-index
        v
index/vault.sqlite (derived, local-only, replaceable)
```

Schema v2 separates immutable source projections from recomputable state:

- `source_chunks` records chunk identity, source path, Git blob OID, producer,
  event count, and canonical plaintext digest;
- `source_events` stores ordered Event v1/v2 projections, canonical JSON, and
  nullable Event v2 relationship-context projections;
- `import_provenance` records the receipt and cache path used for each chunk;
- `derived_state` is namespaced and policy-versioned;
- `relationship_policies`, `relationship_edges`, `episodes`, and
  `episode_members` contain recomputable versioned relationship views.

`rebuild-index` constructs a fresh user-only temporary database, validates
foreign keys and SQLite integrity, fsyncs it, and atomically replaces the
previous index. `--incremental` accepts only the exact current schema and adds
unseen chunks in a transaction; known identical chunks are no-ops and
immutable conflicts fail closed. Incremental rebuild authenticates and
recomputes every stored policy version in that same transaction. Full rebuild
restores only the bundled default view; custom views must be reapplied from
their owner-held policy files. R1 does not migrate evidence rows in place.
An unsupported schema is recovered through a full rebuild from canonical
chunks, leaving encrypted evidence and decoded inputs untouched.

R1.1 runs the same operation once per day through `launchd` on macOS and a
`systemd --user` timer on Linux. `RunAtLoad` and `Persistent=true` recover
missed runs after login or wake. A separate non-blocking scheduler lock
collapses concurrent starts before they enter the existing serialized sync
core. Background failure never changes a harness hook's exit status and is
visible through `flight-recorder status`. Handled sync failures exit zero to
avoid an OS-manager retry storm; unsafe scheduler setup, local state, or
integrity failures exit non-zero and fail closed. Durable bounded retry and
backoff are the next R1.1 layer.

Scheduler ownership is fail-closed. A `0600` local install manifest records the
platform, manager identifiers, target paths, content hashes, and transaction
phase. Install and uninstall also inspect the origin currently loaded in the
`launchd` or `systemd` namespace. Manager operations are allowed only when both
signals identify Flight Recorder's own target, so a same-name user job from
another path is never replaced or stopped. During a config upgrade the manifest
temporarily accepts both the previous and replacement hashes, allowing repair
after an interrupted write without treating copied same-content config as
owned. A user-global, owner-only transaction lock serializes install and
uninstall across Vaults sharing the same OS scheduler namespace. The local
`scheduler/` directory is excluded from Git so its absolute paths, timestamps,
locks, and failure state remain device-local.

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

A versioned integer-only policy converts these edges into a derived episode
view. Explicit contradictory task IDs are a hard veto, including during
component union, so an unknown-task event cannot bridge contradictory tasks.
Every event belongs to a view, including singleton episodes. Weight and
threshold changes create a coexisting view without rewriting source events.
`rebuild-relationships` replaces only the requested policy version in one
transaction.

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

All three commands accept `--json` and build their human and machine output
from the same versioned domain object. `report` uses an explicit positive
duration and includes an episode when its last recorded event is inside the UTC
window. `report` and `inspect` default to `default-v1`; another coexisting view
requires its owner-held file through `--policy`. A custom definition stored
only in the derived database is not an authenticity anchor.

Card reads are authenticated, not ordinary SQLite selects. Under the Vault
lock, the reader validates imported chunks and receipts, compares the complete
source projection, authenticates the stored policy, and rederives that policy's
edges and episodes in memory. It returns a card only when the stored graph
matches the deterministic projection exactly. Human-readable output never
weakens this check.

`elapsed_ms` is the observed timestamp span. Recorded duration and cost metrics
are labeled as sums of recorded values and carry `complete`, `partial`, or
`missing` coverage. Models carry the same coverage instead of hiding events
where no model was recorded. Task type and retry count remain null until their
own evidence exists. Relationship confidence exposes the minimum supporting
integer score beside the policy threshold; it is not a normalized probability.
`status` performs no network request and describes a missing pending marker
only as locally `idle`, never as proof of a successful remote sync.

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
