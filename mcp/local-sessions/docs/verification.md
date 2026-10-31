# Verification scope

Automated tests run without provider credentials using synthetic executables
named `codex` and `claude`, temporary state directories, and isolated config.

Coverage includes duplicate/concurrent sends and dialogue starts, native ID
consistency, delta prompts, persisted history, usage/cache scope and privacy,
stale workers/coordinators, success/failure/timeout/interruption, and stop vs.
reservation races. Dialogue tests cover pause/resume handoff, unfinished-reply
pagination, remaining budgets, an independent child deadline, and a simulated
wall-clock jump while a child is running. MCP tests disconnect and reconnect
the host while a detached dialogue is paused and resumed.

The installed-wheel check runs the full suite from outside the source tree.
Wheel and sdist contents must pass distribution allowlists. Fixtures are
synthetic; provider credentials and real transcripts are not included.

Passing tests verifies modeled control flow, not provider billing, every CLI
version, all OS cleanup behaviors, or idea quality. The time limit is observed
by local supervision with termination grace; it is not a billing ceiling.

## Local validation

The 0.2 preparation was tested on macOS with Python 3.13. Source and installed
wheel tests pass. Linux and Python 3.11 are configured in CI; consult the checks
for the actual revision rather than treating this local run as a CI result.

An authorized source-checkout smoke test used existing CLI authentication and
a separate private registry. With Codex 0.164.0 and Claude Code 2.1.312, a bounded
two-round discussion completed four alternating replies. It paused after the
first reply, disconnected the MCP host, then resumed through a new host using
the same two native IDs. Both providers reported cached input. A separate
resumed Claude probe retained a synthetic marker and reported cache reads.

This establishes a small live path, not hours-long endurance or guaranteed
cache reuse. Real native-history compaction, forced worker death during network
acceptance, and physical machine suspend were not exercised. Synthetic tests
cover conservative failure handling and deadline checks. The live test did
not migrate an existing MCP installation; adoption under that installation's
outer sandbox remains a separate acceptance step.

## Carryover validation

Synthetic tests cover one-line validation, concurrent/idempotent saves, explicit
scope isolation, legacy dialogues, read-only pagination, non-consuming rotation,
close/reopen, and immutable reservation snapshots. An MCP reconnect test saves a
fragment, restarts the host, and verifies that the synthetic CLI actually receives
it before a fresh prompt without manual copying. Continued dialogues deliver the
same opening notes to both partners once and retain native resume on later turns.
These checks establish routing and persistence, not model attention or idea quality.

## Accounting interpretation

The tested Codex JSONL adapter emits session totals on `turn.completed`.
Store those as `token_scope=session_cumulative`; adding resumed snapshots would
double-count earlier calls. Claude result token usage covers the current main
loop, while its estimated cost restores session totals on recent releases.
Missing metrics stay unknown; old CLI releases may have different semantics.
These values do not establish actual subscription or API billing.
