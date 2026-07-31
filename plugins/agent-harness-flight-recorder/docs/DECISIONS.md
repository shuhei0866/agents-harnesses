# Agent Harness Flight Recorder decisions

This file is the decision log for the public, reusable Flight Recorder plugin.
Accepted decisions remain recorded when later superseded.

## D-20260722-01: Start as a personal Evidence Vault

- Status: accepted
- Decision: deliver a useful, user-owned local work history before building a
  marketplace or router.
- Reason: it creates value without requiring network effects or shared outcome
  definitions.
- Consequence: external sharing and incentive design are outside the first
  releases.

## D-20260722-02: Separate encryption from synchronization

- Status: accepted
- Decision: encrypt immutable files with age and use a user-provided private Git
  remote as the first transport.
- Reason: the vault format remains portable to other transports while Git gives
  individuals practical multi-device synchronization.
- Consequence: plaintext events, device private keys, and local indexes are
  never committed.

## D-20260722-03: Use JSONL source data and a rebuildable SQLite index

- Status: accepted
- Decision: preserve append-only JSONL as source evidence, rotate it into
  immutable chunks, and treat SQLite as a derived query index.
- Reason: hook writes remain simple and fail-open while richer queries do not
  make the synchronized database a conflict-prone source of truth.
- Consequence: every index migration must support deterministic rebuild from
  decrypted chunks.

## D-20260722-04: Make synchronization eventually unconscious

- Status: accepted
- Decision: validate synchronization through an explicit command in R1, then
  move quickly to a five-minute OS wake policy with a durable retry queue in
  R1.1; healthy synchronization remains limited to once per 24 hours.
- Reason: invisible operation is a core product property, but Git, encryption,
  and recovery semantics need an observable bootstrap path first.
- Consequence: background failures never block a harness and surface only in
  explicit health status unless a future policy says otherwise.
- Retry policy: wake every five minutes, gate healthy synchronization to once
  per 24 hours, and persist deterministic equal-jitter exponential backoff
  between five minutes and 24 hours for transient remote failures. Permanent
  locally provable failures require repair or an explicit manual sync.
- Privacy boundary: persist and report only finite failure/action codes; never
  retain raw Git stderr, remote URLs, filesystem paths, or credentials in
  retry health.

## D-20260722-05: Use device-scoped immutable Git paths

- Status: accepted
- Decision: every device writes unique encrypted chunks under its own random
  identifier and never updates a shared event file.
- Reason: append-only unique paths avoid normal multi-device merge conflicts.
- Consequence: shared manifests must be derived locally or designed as
  independently mergeable records.

## D-20260722-06: Correlate across devices with a vault key

- Status: accepted
- Decision: use one vault-wide HMAC correlation key encrypted to per-device age
  recipients and an offline recovery recipient.
- Reason: cross-device episode construction needs stable pseudonyms without
  synchronizing raw paths or identifiers.
- Consequence: enrolling or revoking devices requires recipient and key-envelope
  management.

## D-20260722-07: Represent episode identity as versioned relationships

- Status: accepted
- Decision: store relationship evidence and confidence between events; derive
  episode membership through a versioned policy.
- Reason: task identity is gradual and can span harnesses and sessions. A fixed
  early grouping would corrupt history.
- Consequence: source events remain immutable and episode views can be
  recomputed as heuristics improve.

## D-20260722-08: Layer deterministic and model evaluation

- Status: accepted
- Decision: collect deterministic outcomes first, provide on-demand delayed
  model evaluation next, and later evaluate uncertain episodes in the
  background from metadata.
- Reason: deterministic evidence is cheap, reproducible, and privacy-safe;
  models are valuable for ambiguous outcomes but should not be on the critical
  path.
- Consequence: artifact-content access is explicit and evaluation provenance is
  stored without retaining artifact bodies by default.

## D-20260722-09: Return value through Episode Evidence Cards

- Status: accepted
- Decision: begin with `status`, `report`, and `inspect` CLI commands whose main
  output is a grounded Episode Evidence Card.
- Reason: a CLI can be used directly or composed by Claude Code and Codex, and
  tests the core value before a dashboard is justified.
- Consequence: model leaderboards are deferred until comparable episode samples
  and difficulty controls exist.

## D-20260722-10: Support explicit forgetting and best-effort purge

- Status: accepted
- Decision: distinguish derived-state `forget` from destructive `purge`, which
  rewrites the dedicated private data repository.
- Reason: user ownership requires a credible deletion path even though Git is
  history-preserving.
- Consequence: purge must preview scope, require explicit confirmation, and
  document that external caches or uncontrolled clones cannot be guaranteed to
  disappear.

## D-20260724-11: Keep recovery ownership outside the Vault

- Status: accepted
- Decision: `init` requires an externally created offline recovery recipient
  and never creates or stores its private identity.
- Reason: a recovery secret synchronized with the data it protects would not
  provide an independent recovery boundary.
- Consequence: setup has one explicit manual step, and losing both every
  enrolled device identity and the offline recovery identity makes the
  correlation key unrecoverable.

## D-20260724-12: Preserve a local plaintext correlation key

- Status: accepted
- Decision: retain the 32-byte correlation key locally as user-only
  `hash.key`, while synchronizing only its age-encrypted envelope.
- Reason: lifecycle hooks need cheap, fail-open HMAC correlation without
  invoking an external decryptor on every event.
- Consequence: `.gitignore` and the sync allowlist both exclude `hash.key`;
  local endpoint security remains part of the trust boundary.

## D-20260724-13: Authenticate the recipient registry

- Status: accepted
- Decision: assign every enrolled device a random ID and authenticate the
  device/recovery recipient registry with an HMAC derived from the Vault
  correlation key.
- Reason: public Git metadata can be edited independently of the encrypted
  envelope; blindly trusting an added recipient would turn an authorized
  device into a key-distribution confused deputy.
- Consequence: recipient changes require successful envelope decryption before
  metadata is accepted, and a new device uses `device join` to create its local
  identity, device ID, and `hash.key`.

## D-20260724-14: Content-address encrypted chunks with durable local retry

- Status: accepted
- Decision: derive each chunk ID from the Vault ID, producing device ID, and
  ordered canonical Event v1 bytes; keep atomically detached plaintext input in
  a Git-ignored queue until one immutable age artifact is verified as published.
- Reason: age encryption is probabilistic, so ciphertext identity cannot make
  interrupted retries converge. The canonical plaintext evidence can.
- Consequence: retry reuses a matching existing artifact, refuses a conflicting
  artifact without overwriting it, and removes plaintext pending state only
  after successful publication.

## D-20260725-15: Treat the private Git remote as untrusted transport

- Status: accepted
- Decision: synchronize with the provider-neutral `git` CLI, stage only the
  explicit Vault allowlist, and decrypt and validate every unseen or changed
  chunk before commit or local import.
- Reason: a private remote and a `.jsonl.age` suffix do not prove that a blob is
  encrypted, belongs to this Vault, or still represents the immutable chunk
  previously imported.
- Consequence: sync verifies Git entry modes, recipient metadata HMAC, chunk
  path/header/schema/content digest, and the imported Git blob OID. Network or
  validation failures retain the local encrypted artifact, commit, and
  Git-ignored pending-sync state without blocking harness hooks.

## D-20260725-16: Rebuild SQLite instead of migrating evidence in place

- Status: accepted
- Decision: treat `index/vault.sqlite` as a deterministic local projection.
  Full rebuilds publish a separately constructed current-schema database
  atomically; incremental imports accept only the exact current schema.
- Reason: immutable chunks and their validated import provenance are the source
  of truth. In-place evidence migration adds recovery risk without preserving
  information that cannot already be reconstructed.
- Consequence: schema metadata explicitly separates source projections from
  policy-versioned derived state. Unsupported or corrupt databases are
  recovered through full rebuild, and any failure leaves encrypted chunks,
  decoded cache, receipts, and the previous valid database unchanged.

## D-20260725-17: Version relationship context and derived episode policy

- Status: accepted
- Decision: preserve Event v1 and Chunk v1 compatibility; add exact Event v2
  relationship context containing only domain-separated HMAC identifiers and
  bounded changed-file fingerprints. Split mixed inboxes into homogeneous
  chunks. Project v2 context into rebuildable SQLite schema v2 and derive
  versioned relationship edges and episodes with integer-only policies.
- Reason: relationship identity is probabilistic and policy-dependent, while
  source evidence must remain immutable, privacy-safe, and reproducible.
  Contradictory explicit task IDs veto direct links and transitive component
  bridges. Singleton episodes preserve events with insufficient evidence.
- Consequence: policy views coexist and can be rebuilt without rewriting source
  events; a full rebuild restores the bundled view and owner-held custom
  policies must be reapplied explicitly.

## D-20260725-18: Authenticate Evidence Cards and preserve unknown values

- Status: accepted
- Decision: generate human and JSON Evidence Cards from one domain object only
  after comparing SQLite source rows with authenticated chunk provenance and
  rederiving the selected relationship policy in memory. Keep timestamp span,
  recorded metrics, and unavailable fields distinct.
- Reason: a structurally valid local database can still be forged, and a zero,
  success, task label, retry count, or confidence percentage invented from
  missing evidence would turn the value-return layer into a false signal.
- Consequence: `report` and `inspect` fail closed on source or graph drift;
  missing and partial evidence stays explicit, while `status` remains a
  network-free local health snapshot rather than proof of remote freshness.

## D-20260725-19: Classify deterministic facts before discarding tool content

- Status: accepted
- Decision: add Event v3 with only a finite operation kind and bounded tool
  outcome, then rebuild SQLite v3 deterministic evidence rows from canonical
  events. Derive each evidence ID from its collector version, source event,
  timestamp, type, state, and bounded value.
- Reason: test, build, lint, commit, pull-request, retry, duration, token, and
  cost signals are valuable before model evaluation, but retaining commands,
  output, diffs, or artifact bodies would violate the default privacy boundary.
- Consequence: only simple allowlisted invocations are classified. A recognized
  operation without a trustworthy outcome remains `missing`, distinct from
  `failure`. Card reads rederive and authenticate evidence rows, and an older
  local SQLite schema requires a full rebuild from the immutable chunks.

## D-20260725-20: Bound delayed evaluation with an executable protocol

- Status: accepted
- Decision: run an owner-selected episode through a local, versioned evaluator
  executable. Default to metadata-only input; require a scope-preview round
  trip before reading additional artifacts. Persist only finite rubric output,
  evaluator/model/timestamp provenance, evidence IDs, and artifact hashes.
- Reason: Claude Code and Codex need different invocation adapters, while the
  privacy and replay contract must remain provider-neutral. Free-form model
  output can repeat private source content and therefore cannot be a safe
  stored result.
- Consequence: evaluator adapters receive transient JSON on stdin and return a
  strict finite JSON object. Artifact access requires a keyed preview receipt;
  the executable identity is pinned by SHA-256 and runs with bounded output in
  a minimal environment. Evaluation records are atomic local state excluded
  from Vault Git in R1.2 and are part of purge rollback. A timeout, process
  failure, invalid response, changed evidence set, or unsafe artifact leaves
  existing episodes and evidence untouched.

## D-20260725-21: Bound automatic evaluation by local policy and two budgets

- Status: accepted
- Decision: run metadata-only evaluation after a successful scheduled sync,
  selecting only episodes below an owner-configured relationship-confidence
  threshold. Bound each run by episode count and integer micro-USD, and retain
  a local fingerprint ledger for failed attempts.
- Reason: automatic evaluation must remain outside hook and sync critical paths
  and must not repeatedly spend on unchanged evidence or ambiguous floating
  point cost comparisons.
- Consequence: automatic requests cannot include artifact content; records
  identify their background trigger and measured cost. Background failure uses
  a separate finite local status and cannot downgrade successful sync health.
  On-demand adapters remain on their exact v1 contract; budgeted background
  adapters use v2 with mandatory measured cost. The system reserves an attempt
  before invocation, serializes configure/run/purge, and requires an owner-held
  file for any non-default relationship policy.

## D-20260726-22: Keep raw sessions local and derive versioned semantic receipts

- Status: accepted
- Decision: treat an explicitly registered Claude Code or Codex session log as
  a local-only source. Send only an owner-selected line span to a trusted local
  evaluator and persist a bounded Semantic Receipt containing task, execution,
  result, assessment, and recorder-generated provenance. Never copy the raw
  session into the Vault or add source registrations or receipts to the Git
  sync allowlist.
- Reason: privacy-safe lifecycle metadata proves that work occurred but cannot
  explain its intent or result. Keeping the original local source available
  lets a later, stronger model rederive a better interpretation instead of
  freezing the current model's understanding.
- Consequence: source registrations may contain a local path but are owner-only
  state. The CLI returns only an opaque source reference, content digest, and
  size; it never returns the local path or raw content. Receipts store hashes
  and bounded model-derived prose, not raw source paths or bodies. Multiple
  model or rubric generations coexist without overwriting earlier receipts,
  and inspect keeps model-derived semantics separate from deterministic
  evidence. Background metadata evaluation skips evidence-free singleton
  episodes rather than paying a model to judge an empty envelope.

## D-20260726-23: Discover exact session spans in hooks and evaluate off-path

- Status: accepted
- Decision: after a canonical Stop Event is recorded, append a bounded
  local-only hint that binds its Event ID and HMAC correlation identifiers to
  an allowed session source, file identity, and captured byte boundary. Let a
  later worker evaluate only a uniquely closed Claude Code parent chain or
  Codex turn whose authenticated Episode members agree on harness and
  correlation identity.
- Reason: automatic use must require no per-task human classification, but a
  hook cannot safely block on model latency, scan broad local directories, or
  guess between multiple turns. The captured boundary makes later appends
  irrelevant to span selection, while exact-only matching keeps ambiguity from
  becoming paid false evidence.
- Consequence: active, missing, mixed, or ambiguous candidates never invoke the
  evaluator. Exact candidates receive a durable evidence/source/evaluator/
  rubric fingerprint reservation before protocol-v2 invocation, so completed
  and failed work is not automatically recharged. A paid response that fails
  semantic validation stops the rest of that run, every Episode member must
  carry the exact authenticated correlation hashes, and terminal hints are
  periodically compacted under the hook writer lock. Scheduler execution
  occurs only after successful sync and outside sync health. Hints, paths,
  attempts, and status stay owner-only and Git-ignored; public status exposes
  finite counts and measured micro-USD only.

## D-20260726-24: Use a tool-less Claude CLI adapter with a recorder child guard

- Status: accepted
- Decision: ship a standalone protocol-v2 adapter that invokes Claude Code in
  print and safe modes with structured output, no tools, no MCP servers, no
  Chrome, and no session persistence. Pass the dynamic request only on stdin
  and set `FLIGHT_RECORDER_EVALUATOR_CHILD=1` for the provider process.
- Reason: local OAuth/keychain authentication rules out bare mode, while safe
  mode alone may retain administrator-managed settings. The explicit Recorder
  child guard prevents recursive Event and hint creation without weakening
  provider authentication.
- Consequence: only provider `structured_output` and `total_cost_usd` cross
  back into the worker. Cost is rounded upward to integer micro-USD and
  over-budget output fails closed. The CLI resolves only this known bundled
  adapter relative to its own scripts directory rather than broadening the
  scheduler runtime path. Real provider calls remain disabled until the owner
  configures a positive local cost budget.

## D-20260727-25: Give the bundled Claude adapter cleanup room inside the worker deadline

- Status: accepted
- Decision: bound the production Claude child at 180 seconds and the automatic
  worker invocation of that bundled adapter at 240 seconds. Keep the existing
  60-second deadline for custom evaluators and ignore timeout-shortening
  environment variables outside the explicit test harness.
- Reason: real structured Semantic Receipt calls crossed the previous
  50-second child and 60-second worker deadlines even though authentication and
  a minimal structured-output call succeeded. Because the worker deadline
  starts before the adapter starts its child, a ten-second gap could also kill
  the adapter before process-group cleanup completed.
- Consequence: the bundled adapter has a finite 60-second cleanup margin while
  remaining under the Semantic Receipt protocol's 300-second maximum.
  Timeout failures stay fail-closed and their durable attempt reservation still
  prevents automatic recharging.

## D-20260731-26: Measure semantic lift with a transient minimized packet

- Status: accepted
- Decision: add a manual Meaning Lift pilot that deterministically extracts the
  first human message and final assistant message from one registered source
  span, redacts recognized private values, and sends only a bounded transient
  packet to a fixed five-field evaluator. Compare the result with deterministic
  metadata using the same questions for intent, deliverable, verification and
  outcome, reusable learning, and time and API cost. Derive the baseline only
  from real Evidence Card fields, and score `unknown` outcomes as partial
  rather than covered.
- Reason: lifecycle metadata is a strong execution skeleton but cannot explain
  most task meaning, while the existing Semantic Receipt sends a much larger
  raw span through a deep contract. Automatic integration is premature until a
  real task demonstrates that smaller, grounded semantics improve answerable
  coverage enough to justify model cost and privacy risk.
- Consequence: the packet is never persisted and tool input/output, thinking,
  intermediate assistant messages, and code fences never enter it. The model
  supplies bounded summaries and packet evidence references only; the Recorder
  supplies source/evaluator hashes, policy, measured micro-USD, latency, and
  time. Owner-only Meaning Cards are Git-ignored and content-addressed. An
  identical episode/span/packet/model/evaluator/contract reuses its existing
  Card rather than paying again. Automatic candidate selection, routing, and
  external export remain unchanged pending the pilot result. The first
  corrected real-task pilot increased the comparable score from `0.0` to
  `4.0/5.0`; deliverable and verification/outcome remained partial because the
  Card distinguished a completed turn from an unverified real-world outcome.
  Unattended provider calls remained blocked by local CLI authentication, and
  whole-graph evidence authentication dominated command latency, so automatic
  paid generation remains disabled.
