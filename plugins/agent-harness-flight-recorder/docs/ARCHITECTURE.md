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

Schema v3 separates immutable source projections from recomputable state:

- `source_chunks` records chunk identity, source path, Git blob OID, producer,
  event count, and canonical plaintext digest;
- `source_events` stores ordered Event v1/v2/v3 projections, canonical JSON,
  nullable Event v2 relationship context, and nullable Event v3 operation kind;
- `import_provenance` records the receipt and cache path used for each chunk;
- `deterministic_evidence` contains rebuildable, source-linked facts with
  stable IDs, collector versions, timestamps, explicit states, and bounded
  values;
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

R1.1 wakes a local policy every five minutes through `launchd` on macOS and a
`systemd --user` timer on Linux. `RunAtLoad` and the user timer recover after
login or wake. A healthy policy enters the serialized sync core at most once
per 24 hours. Transient remote failures use deterministic equal-jitter
exponential backoff from five minutes to a 24-hour cap; the next deadline and
failure count are stored atomically in `scheduler/state.json`. A separate
non-blocking scheduler lock collapses concurrent starts, and the persisted
deadline gates new processes after restart.

Background failure never changes a harness hook's exit status. Remote
operation failures are retried, while locally provable origin mismatch,
rebase conflict, and integrity failures are suppressed until repair. Status
publishes only finite diagnostic and next-action codes, never Git stderr,
remote URLs, paths, or credentials. Handled sync failures and early wakeups
exit zero; unsafe scheduler setup, locks, or tampered local state exit non-zero
and fail closed. Explicit manual sync bypasses the automatic deadline and
reconciles both successful and failed outcomes under the same scheduler lock.

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
2. On-demand delayed evaluation: the owner selects an episode, invokes a local
   versioned evaluator adapter, and explicitly permits any additional artifact
   scope required by a model.
3. Background evaluation: a later release evaluates uncertain episodes from
   metadata by default. Artifact access remains an explicit workspace policy.

Stored evaluation provenance includes the rubric version, evaluator and model,
timestamp, evidence identifiers, artifact hashes, conclusions, and confidence.
Artifact bodies and evaluator input transcripts are not persisted by default.
R1.2 stores only finite judgments and criterion states, never free-form model
text. Records are atomic, user-only, content-addressed local files excluded
from Vault Git; the input fingerprint makes identical
rubric/model/evidence/executable scopes comparable and idempotent when
evaluated at the same timestamp. Card output is version 3 so strict consumers
can distinguish the separate model-judgment field.

Additional artifact access is a two-step protocol. The first invocation
authenticates the episode and returns canonical paths plus byte sizes without
reading content or starting the evaluator. It also returns a keyed receipt
bound to file identity and metadata. Only a second invocation with explicit
permission and that still-valid receipt reads bounded UTF-8 content. The
evaluator executable is pinned by SHA-256 and runs from an empty temporary
directory with a minimal environment and an OS-enforced stdout limit. Failure,
timeout, invalid JSON, an out-of-rubric response, or changed evidence creates
no evaluation record and does not mutate episode evidence.

Background evaluation is enabled only by an owner-held local policy containing
the relationship-policy version, uncertainty threshold, adapter/model, maximum
episodes per run, and maximum micro-USD per run. The daily scheduler runs it
only after sync health has been committed as successful. Requests have no
artifact-content surface. The existing on-demand adapter and record contracts
remain exact v1. Background adapters use v2, receive the remaining run budget,
and must return measured micro-USD; their records identify the background
trigger. Presentation treats exact v1 records as on-demand without rewriting
their stored schema. A local fingerprint ledger reserves an attempt before
provider invocation and bounds pending or failed retries; successful records
provide the corresponding idempotency boundary. Configure, automatic runs, and
applied purge share an outer lock, and purge removes or transactionally restores
matching reservations. Background health is separate from sync health and
exposes finite diagnostics only. Custom relationship policies require their
owner-held file as the authenticity anchor.

The deterministic collector is deliberately narrower than a shell parser.
Event v3 recognizes only finite operation kinds from simple allowlisted tool
invocations. It stores the classification and a bounded outcome but never the
raw command, tool output, diff, or artifact body. SQLite derives one stable
evidence ID from the collector version, source event, timestamp, type, state,
and bounded value. A recognized operation without a trustworthy outcome is
`missing`; a trustworthy unsuccessful outcome is `failure`.

## User interface

The first interface is a stable CLI that agent harnesses can also invoke:

```text
flight-recorder status
flight-recorder report --last 7d
flight-recorder inspect <episode-id>
flight-recorder evaluate <episode-id> --evaluator ADAPTER --model MODEL
flight-recorder auto-evaluation configure ...
flight-recorder auto-evaluation run
flight-recorder source register --adapter HARNESS --path SESSION.jsonl
flight-recorder receipt generate <episode-id> --source-ref REF ...
flight-recorder receipt-auto configure ...
flight-recorder receipt-auto run
```

The primary output is an Episode Evidence Card containing task type, model,
duration, measured cost, deterministic outcomes, retry count, confidence, and
supporting evidence. A dashboard is not required for the first value test.

All evaluation and reporting commands accept `--json` and build their output
from the same versioned domain object. `report` uses an explicit positive
duration and includes an episode when its last recorded event is inside the UTC
window. `report` and `inspect` default to `default-v1`; another coexisting view
requires its owner-held file through `--policy`. A custom definition stored
only in the derived database is not an authenticity anchor.

Card reads are authenticated, not ordinary SQLite selects. Under the Vault
lock, the reader validates imported chunks and receipts, compares the complete
source projection, authenticates the stored policy, and rederives both
deterministic evidence and that policy's edges and episodes in memory. It
returns a card only when all stored derived rows match those projections
exactly. Human-readable output never weakens this check.

`elapsed_ms` is the observed timestamp span. Recorded duration and cost metrics
are labeled as sums of recorded values and carry `complete`, `partial`, or
`missing` coverage. Models carry the same coverage instead of hiding events
where no model was recorded. Retry count uses the same explicit measurement
coverage and remains `missing` until its own evidence exists. Relationship
confidence exposes the minimum supporting integer score beside the policy
threshold; it is not a normalized probability.
`status` performs no network request and describes a missing pending marker
only as locally `idle`, never as proof of a successful remote sync.

### Local session sources and Semantic Receipts

Lifecycle hooks still discard prompt, response, command, output, and code
content. Semantic interpretation is a separate, explicit local operation. The
owner first registers one absolute Claude Code or Codex JSONL session source.
Flight Recorder stores its local path, adapter, byte size, and content digest
under Git-ignored `session-sources/`. The CLI returns an opaque source
reference, content digest, and size; it never returns the local path or raw
content. It does not copy the source body into the Vault.

`receipt generate` accepts that opaque reference and a required 1-based,
inclusive line span. Only those bytes are sent on stdin to an owner-selected
local evaluator. The evaluator runs with the same executable pinning, empty
working directory, minimal environment, output limit, and timeout boundary as
on-demand evaluation. Its response is validated against an exact, bounded
Semantic Receipt contract.

The recorder, not the evaluator, adds source and evidence hashes, source event
IDs, evaluator/model/rubric identity, and generation time. Content-addressed
records live under Git-ignored `semantic-receipts/`. A different model, rubric,
source snapshot, or semantic result produces another record; an existing
record is never overwritten. `inspect` labels these records as model-derived
semantics and does not silently promote them into deterministic task or
outcome fields.

Automatic Semantic Receipts add a hook-assisted discovery layer without
changing Event v3. When explicitly configured, the `Stop` recorder first
persists its canonical metadata Event, releases the Event lock, and then
best-effort appends a Git-ignored local hint. The hint binds the Event ID and
HMAC session/turn identifiers to an allowed local source, file identity, and
captured byte boundary. Hook failure never changes agent behavior and the hook
never calls a model.

The asynchronous worker reads only the captured prefix, bounds its bytes and
line count, and classifies the candidate as exact, active, missing, or
ambiguous. Claude Code exactness follows the latest `last-prompt` leaf backward
to the nearest non-tool human prompt and rejects interleaved branches. Codex
exactness requires one matching session and one closed
`task_started`/`task_complete` turn. Before evaluation, an authenticated index
query proves that the Stop Event belongs to one Episode whose members all
agree on harness and non-null correlation identifiers.

The worker pins the evaluator and rubric by SHA-256, includes the Episode,
source prefix, selected lines, evidence set, model, and policy in its durable
fingerprint, and reserves that fingerprint before invocation. Automatic
requests use evaluator protocol v2 with an integer remaining-cost budget and
mandatory measured cost; manual generation remains exact v1. Completed,
pending, and failed fingerprints are not automatically charged again.
Scheduler invocation occurs only after successful sync and outside the sync
critical section, so matching, configuration, or evaluator failure cannot
downgrade sync health. Public status v4 adds only finite automation counts and
diagnostics; all paths, hints, reservations, and raw session bodies remain
local under Git-ignored `receipt-automation/`.

The bundled production adapter translates protocol v2 into one Claude Code
print-mode call. It uses structured output, safe mode, an empty tool set,
strictly empty MCP configuration, no Chrome, and no session persistence. The
dynamic request and raw source stay on stdin rather than process arguments.
Only `structured_output` and `total_cost_usd` are accepted from the provider;
cost is rounded upward to integer micro-USD and rejected when it exceeds the
remaining budget. The child runs in an empty temporary directory with bounded
output and timeout, while `FLIGHT_RECORDER_EVALUATOR_CHILD=1` makes any
remaining managed Recorder hook a no-op. The evaluator resolver recognizes
only the bundled adapter name and pins its absolute path relative to the active
CLI, so manual and scheduled discovery do not broaden runtime `PATH`.
Authentication is deliberately inherited only through the local user's home
directory and keychain; credential-bearing environment variables are excluded
so an ambient API key cannot silently change the billing identity.
The production Claude child has a finite 180-second deadline. Automatic
Semantic Receipt generation gives that bundled adapter a 240-second outer
deadline, leaving 60 seconds for startup, validation, and process-group cleanup
before the worker boundary fires. Custom evaluators retain the existing
60-second outer deadline. Test-only timeout shortening is ignored unless the
explicit test-harness marker is also present.

### Meaning Lift pilot

The Meaning Lift pilot is a separate manual projection over one registered
source span. It does not alter Event v3, relationship formation, or automatic
Receipt selection. A deterministic local extractor accepts only the first
human message and the final assistant message for supported Claude Code and
Codex JSONL shapes. Tool calls, tool results, thinking, intermediate assistant
messages, and fenced code are excluded. Recognized paths, email addresses, and
credential forms are redacted before a canonical `meaning-packet-v1` is sent
to an evaluator. The packet is at most 16 KiB and is never persisted.

The evaluator returns only intent, deliverable, verification, outcome,
reusable learning, confidence, and packet evidence references. The Recorder
validates every reference against the transient packet and adds source,
evaluator, policy, cost, latency, and generation provenance. The resulting
content-addressed `meaning-card-v1` lives under owner-only, Git-ignored
`meaning-cards/`. A matching episode, source span, packet, evaluator, model,
policy, and contract reuses the stored Card without another paid invocation.

The command also emits a deterministic baseline and a five-question comparison:
intent, deliverable, verification and outcome, reusable learning, and time and
API cost. The baseline reads only fields that exist on the authenticated
Evidence Card. Coverage is intentionally conservative: answers score as
covered (`1`), partial (`0.5`), or uncovered (`0`), and an `unknown` model
outcome leaves deliverable and verification/outcome only partial. A Meaning
field also needs a bounded summary citing at least one allowed packet evidence
ID. This measures whether the projection answers previously unanswered
questions without claiming that fluent prose proves business value. The pilot
remains outside the scheduler and automatic Receipt worker until real-task
results justify that integration.

## Retention and deletion

Privacy-safe encrypted events are retained until the owner deletes them. Normal
analysis deletion is a tombstone-like `forget` operation in derived state.

`purge` removes matching local data, including evaluation records, and rewrites
the dedicated private data repository so encrypted chunks are removed from Git
history. A rejected force-push restores the evaluation records with the other
retryable local state. It is explicit, destructive, and must show the affected
scope before applying. Remote-provider caches and independent clones mean
purge is best-effort beyond repositories the owner controls; the CLI must state
this limitation clearly.

## Release boundaries

### R1: Evidence Vault

- vault initialization, device identity, recipients, and recovery key;
- JSONL rotation, schema validation, age encryption, and manual Git sync;
- deterministic local SQLite rebuild;
- versioned episode relationship policy;
- `status`, `report`, `inspect`, Evidence Cards, `forget`, and `purge`.

### R1.1: Unconscious Sync

- unconscious `launchd` and `systemd` scheduling;
- durable retry queue, bounded jittered backoff, and secret-free sync health.

### R1.2: Evaluation

- deterministic evidence collectors;
- explicit `evaluate` with metadata-only default, finite model judgments,
  provenance, and artifact scope preview;
- metadata-only background evaluation for uncertain episodes.

### R1.3: Semantic Receipts

- explicit local Claude Code and Codex session source registration;
- bounded, versioned Semantic Receipt generation from an owner-selected span;
- model/rubric/source provenance and later-model rederivation;
- local-only storage with an explicit export boundary;
- inspect v4 presentation and purge/rollback coverage for derived receipts.

### R1.4: Unconscious Semantic Receipts

- Stop-hook local hints with captured source boundaries;
- exact-only Claude Code parent-chain and Codex turn matching;
- durable pre-invocation reservations and protocol-v2 cost budgets;
- scheduler integration isolated from sync health;
- content-free status v4 automation counts.

### R1.4.1: Meaning Lift pilot

- deterministic, transient semantic evidence packets;
- fixed five-question baseline-to-Meaning coverage comparison;
- recorder-measured cost and latency provenance;
- owner-only, content-addressed Meaning Cards with paid-call idempotency;
- manual real-task validation before automatic integration.

### Later

- selected, privacy-reviewed episode export;
- aggregate signals and incentive design;
- context-aware model and skill routing.

External sharing, a marketplace, automatic artifact-content evaluation, and a
hosted Flight Recorder cloud are outside R1 through R1.2.
