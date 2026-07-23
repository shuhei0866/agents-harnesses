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
  move quickly to daily OS scheduling with a durable retry queue in R1.1.
- Reason: invisible operation is a core product property, but Git, encryption,
  and recovery semantics need an observable bootstrap path first.
- Consequence: background failures never block a harness and surface only in
  explicit health status unless a future policy says otherwise.

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
