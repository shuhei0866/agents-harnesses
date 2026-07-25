# Agent Harness Flight Recorder

Local, privacy-first lifecycle telemetry for Claude Code and Codex.

This first slice only observes work. It does not route models, score developers,
upload data, or call an evaluator model. The purpose is to create a trustworthy
`work episode` event stream before adding recommendations.

The accepted product architecture and release boundaries are documented in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). The reasons behind the major
choices are preserved in [`docs/DECISIONS.md`](docs/DECISIONS.md).

## What it records

The shared hook configuration observes four lifecycle events:

| Harness event | Canonical event |
|---|---|
| `SessionStart` | `session.started` |
| `UserPromptSubmit` | `turn.prompted` |
| `PostToolUse` | `tool.completed` |
| `Stop` | `turn.completed` |

Both harnesses write the same JSONL schema. The recorder uses Codex's
`PLUGIN_ROOT` environment variable to distinguish Codex from Claude Code;
payload fields such as `model` overlap and are never used as the discriminator.

## Privacy contract

The recorder is allowlist-based. Unknown input fields are discarded.

Stored:

- harness and lifecycle event names
- model, permission mode, and tool name when present
- a fixed allowlist of numeric duration, token, and cost metrics
- random event ID and timestamp
- truncated HMAC-SHA-256 identifiers for session, turn, and workspace correlation
- domain-separated HMAC identifiers for tasks, branches/worktrees, and up to
  128 allowlisted changed-file paths, with explicit missing/truncated state

Never stored by default:

- prompts or assistant messages
- commands, code, file contents, or tool output
- transcript contents or transcript paths
- raw session IDs, turn IDs, or workspace paths
- raw task IDs, branch/worktree names, or changed-file paths
- unknown future hook fields

The HMAC key is generated locally beside the event log with user-only
permissions, so low-entropy workspace paths cannot be checked against the log
without the installation-local key. The recorder never opens `transcript_path`;
it treats hook input as the only source and selects safe metadata from it.

## Failure behavior

Recording is fail-open. Empty input, malformed JSON, missing Python, an invalid
destination, or a write failure produces no hook decision and exits successfully.
The original Claude Code or Codex action continues.

Input is capped at 1 MiB; oversized hook payloads are skipped. Each event is
serialized before an advisory-locked `O_APPEND` write that handles short writes.
This keeps concurrent hook invocations from interleaving JSONL records on the
supported macOS/Linux development environments.

## Storage

Default:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/agent-harness-flight-recorder/inbox/events.jsonl
```

Override the file for testing or local policy:

```bash
export AGENT_FLIGHT_RECORDER_PATH=/path/to/events.jsonl
```

For an explicit event path, the correlation key defaults to `hash.key` beside
that file. In a Vault it remains at the Vault root. Its path can be overridden
with `AGENT_FLIGHT_RECORDER_KEY_PATH`; an externally managed secret can instead
be supplied through `AGENT_FLIGHT_RECORDER_HASH_KEY`.

New directories and files are created with user-only permissions where the
platform honors POSIX modes.

`FLIGHT_RECORDER_STATE_DIR` must be absolute (a leading `~` is expanded).
Relative overrides are rejected by the CLI and ignored fail-open by hooks so a
workspace-dependent current directory cannot split one logical Vault.

## Initialize an encrypted Vault

Install [`age`](https://github.com/FiloSottile/age), then create an offline
recovery identity outside the Vault and keep that private file backed up:

```bash
age-keygen -o /secure/offline-recovery.agekey
age-keygen -y /secure/offline-recovery.agekey
```

Pass only the printed public recipient to the initializer:

```bash
scripts/flight-recorder init \
  --remote git@github.com:you/private-flight-recorder.git \
  --recovery-recipient age1...
```

`init` is local-only: it records the future private Git remote but does not
connect to or clone it. The Vault defaults to the same state directory as the
hook recorder and can be overridden with `FLIGHT_RECORDER_STATE_DIR`.

The initializer creates a device-specific age identity, a random Vault and
device ID, and one 32-byte correlation key. The key remains available locally
as the recorder's user-only `hash.key` and is also encrypted to both the device
and recovery recipients in `keys/correlation-key.age`. Each enrolled device is
recorded as a random device ID plus its public recipient. That recipient
registry is authenticated with the correlation key before any re-encryption.

To pre-enroll another device's already-generated public recipient from an
authorized device:

```bash
scripts/flight-recorder device add --recipient age1...
```

On a new device, first obtain the Git-synchronized `.gitignore`, `vault.json`,
and `keys/correlation-key.age`, then bootstrap its local-only identity and
`hash.key`:

```bash
scripts/flight-recorder device join \
  --identity /secure/offline-recovery.agekey
```

`device join` preserves the Vault ID, generates a new random device ID and age
identity, adds its recipient to the same envelope, and materializes the same
correlation key for the local recorder. If `--identity` is a pre-enrolled
device identity, `join` adopts that identity and its existing device ID instead
of creating a duplicate. Otherwise, use a recovery identity to create a new
device registration.

Rotate complete inbox records into an immutable encrypted chunk:

```bash
scripts/flight-recorder rotate
```

Rotation detaches the live inbox under a short-lived stable lock, validates
each event, quarantines invalid bytes locally, and encrypts the canonical chunk
to every enrolled device and recovery recipient. Only
`devices/<device-id>/<YYYY>/<MM>/<DD>/<digest>.jsonl.age`, `.gitignore`,
`vault.json`, and the encrypted key envelope are Git-sync candidates. Plaintext
inbox, retry queue, quarantine, keys, device identities, indexes, and temporary
files remain local-only. The recovery private key must never be placed inside
the Vault.

Synchronize the Vault through its configured private Git remote:

```bash
scripts/flight-recorder sync
```

`sync` rotates pending events, initializes the Vault root as a dedicated Git
working tree when needed, commits only the explicit allowlist, pulls with
rebase, imports unseen encrypted chunks into the local-only cache, and pushes
to `main`. It uses the `git` CLI and the remote in `vault.json`; it does not use
GitHub-specific APIs.

Every candidate chunk is decrypted and its path, Chunk v1 header, Vault/device
IDs, date, homogeneous Event v1 or v2 records, count, and content digest are
verified before it
can enter a local commit or import cache. Existing imports record the Git blob
OID so replacing an immutable ciphertext at the same path is rejected. A
failed pull, import, or push keeps the encrypted artifact, local commit, and
`queue/pending-sync.json` for a later retry. Network work never holds the
hook's inbox lock, so recording remains fail-open and independent of sync.

Install the same sync core as an unconscious user-level background job:

```bash
scripts/flight-recorder scheduler install
scripts/flight-recorder scheduler uninstall
```

macOS uses a managed `launchd` LaunchAgent with `RunAtLoad`; Linux uses a
`systemd --user` service and timer. Both wake the local policy every five
minutes. The policy performs a healthy sync at most once per 24 hours, while a
transient failure uses deterministic equal-jitter exponential backoff from
five minutes up to 24 hours. These settings catch the next login or wake after
a missed run. Install and uninstall are idempotent and refuse to overwrite an existing
same-name configuration that was not generated by Flight Recorder. A
user-only local install manifest records the managed paths and content hashes;
the OS scheduler's loaded origin is checked against it before any same-name job
is replaced or stopped. This also permits a config created from an older clone
path to be safely upgraded or removed. The whole local `scheduler/` state
directory is Git-ignored, including migration of the preceding managed
`.gitignore`, so absolute local paths and health timestamps are never
published by normal or broad Git staging.

The scheduler calls `flight-recorder scheduler run`, which takes a
non-blocking scheduler lock and then invokes the same `sync()` implementation
as the manual command only when the persisted retry deadline is due.
Concurrent starts and process restarts are harmless. Remote-operation failures
are transient; locally provable configuration, rebase-conflict, and integrity
failures are permanent until repaired. Both classes are recorded with finite,
secret-free diagnostic and next-action codes in `flight-recorder status`.
Handled background failures and early wakeups return success to the OS
scheduler. Unsafe roots, locks, or tampered scheduler state still exit non-zero
and fail closed. An explicit `flight-recorder sync` bypasses automatic backoff
and records its own success or failure, so a repaired permanent error can
become an automatically retried transient error without stale health.

For a second device, clone the private repository into that device's state
directory, run `device join`, then run `sync`. Pre-enrolling the device
recipient before older chunks are created lets its adopted identity decrypt
those chunks; otherwise retain access to the recovery identity when historical
import is required.

Build the local SQLite evidence index and bundled `default-v1` relationship
view from validated imported chunks:

```bash
scripts/flight-recorder rebuild-index
```

This performs a deterministic full rebuild into a temporary database, verifies
foreign keys and SQLite integrity, then atomically publishes
`index/vault.sqlite`. A corrupt or unsupported existing database is replaced
only after the new index is complete. Full rebuild restores the bundled
`default-v1` relationship view; custom views are derived local state and must
be reapplied from their owner-held policy files. To add only unseen chunks to
a current schema-v2 database, use:

```bash
scripts/flight-recorder rebuild-index --incremental
```

Incremental import is transactional and idempotent. Existing chunk, event, and
provenance rows must match their immutable source exactly; a conflict rolls
back without changing the encrypted artifacts, decoded cache, or import
receipt. Every canonical stored policy version is rebuilt in the same
transaction, so custom views remain current; an invalid or conflicting stored
policy rolls back the entire import. The SQLite database is derived local
state, has user-only permissions, and remains outside the Git sync allowlist.

Event v2 adds privacy-safe relationship context: domain-separated HMACs for
explicit tasks and branches/worktrees plus a bounded set of changed-file
fingerprints. Raw identifiers and paths are discarded. Mixed Event v1/v2
inboxes are rotated into homogeneous Chunk v1 files.

Recompute one versioned relationship view without changing source evidence:

```bash
scripts/flight-recorder rebuild-relationships
scripts/flight-recorder rebuild-relationships --policy /path/to/policy.json
```

Policies use integer weights and thresholds. Different versions coexist, and
an invalid policy or failed rebuild leaves every existing view unchanged.

Read local health and grounded Episode Evidence Cards without a dashboard:

```bash
scripts/flight-recorder status
scripts/flight-recorder report --last 7d
scripts/flight-recorder inspect sha256:<episode-digest>
```

Add `--json` to any command for a canonical, single-document JSON response that
Claude Code, Codex, or another local tool can consume. `report` and `inspect`
use `default-v1`; `--policy-version default-v1` states that default explicitly.
Reports include episodes whose last recorded event is inside the requested UTC
window; durations accept a positive integer followed by `s`, `m`, `h`, `d`, or
`w`. Custom views require their owner-held policy file through `--policy`, which
also supplies the version; selecting a custom version stored only in the
derived database is rejected.

Before displaying a card, the CLI reauthenticates the receipt/cache projection
against the SQLite source rows and deterministically rederives the requested
relationship view. An internally consistent but forged local database is
rejected. Timestamp span (`elapsed_ms`) remains separate from recorded duration
metrics. Missing task type, retry count, model, metric, cost, or outcome evidence
stays `null`, `missing`, or `partial`; it is never silently converted to zero,
success, or a guessed label. Numeric metric values are labeled as the sum of
recorded values and include coverage counts. Confidence is the minimum
supporting relationship score and policy threshold, not an invented percentage.

### Forget and best-effort purge

Logical removal keeps immutable source evidence but excludes one episode from
normal reports and later evaluation:

```bash
scripts/flight-recorder forget <episode-id>
```

Destructive purge is a two-step operation. The default command only previews
the encrypted chunks that would be removed:

```bash
scripts/flight-recorder purge <episode-id>
scripts/flight-recorder purge <episode-id> --apply
```

`--apply` removes matching local cache/index state, rewrites the dedicated
Vault Git history, and force-pushes its `main` branch. An episode can share an
immutable chunk with other events, so inspect the preview before applying.
Deletion from independent or uncontrolled clones, provider caches, and backups
cannot be guaranteed; purge is best-effort outside repositories the owner
controls.

## Local development

Claude Code can load the plugin directly for one session:

```bash
claude --plugin-dir /absolute/path/to/plugins/agent-harness-flight-recorder
```

Codex loads this plugin from a configured marketplace. For hook development
without publishing a marketplace, use the same `hooks/hooks.json` definition
and replace `${CLAUDE_PLUGIN_ROOT}` with the plugin's absolute path in a local
`~/.codex/hooks.json` or trusted project `.codex/hooks.json`. Also replace
`--harness auto` with `--harness codex`; `auto` relies on the plugin-provided
`PLUGIN_ROOT` signal and cannot identify a manually copied Codex hook reliably.

Run the contract tests:

```bash
bash plugins/agent-harness-flight-recorder/tests/test-record-event.sh
bash plugins/agent-harness-flight-recorder/tests/test-vault-init.sh
bash plugins/agent-harness-flight-recorder/tests/test-vault-init-age-e2e.sh
bash plugins/agent-harness-flight-recorder/tests/test-chunk-rotation.sh
bash plugins/agent-harness-flight-recorder/tests/test-chunk-rotation-age-e2e.sh
bash plugins/agent-harness-flight-recorder/tests/test-git-sync.sh
bash plugins/agent-harness-flight-recorder/tests/test-git-sync-age-e2e.sh
bash plugins/agent-harness-flight-recorder/tests/test-evidence-index.sh
bash plugins/agent-harness-flight-recorder/tests/test-relationship-graph.sh
bash plugins/agent-harness-flight-recorder/tests/test-reporting.sh
bash plugins/agent-harness-flight-recorder/tests/test-retention.sh
bash plugins/agent-harness-flight-recorder/tests/test-retry-policy.sh
bash plugins/agent-harness-flight-recorder/tests/test-scheduler.sh
```

The tests exercise official-shape fixtures for both harnesses, privacy canaries,
fail-open behavior, optional fields, shared auto-detection, and 50 concurrent
writers. Reporting tests also cover human/JSON parity, policy scope, unknown
values, sync health, and forged source/relationship projections. The stable
source contracts are in `schema/event-v1.schema.json`,
`schema/event-v2.schema.json`, `schema/vault-v1.schema.json`, and
`schema/chunk-v1.schema.json`.
