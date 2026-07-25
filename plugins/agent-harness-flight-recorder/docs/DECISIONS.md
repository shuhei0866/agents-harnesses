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
