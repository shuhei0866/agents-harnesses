# Retrieval measurement pilot

## Use case and boundary

Find an earlier decision and its reasoning, then return to the original
conversation. The first instrument measures retrieval, source access, explicit
feedback, and optional answer assessments. It does **not** equate a search hit,
resolvable citation, or lack of correction with a correct answer.

This is an opt-in CLI entry point, `scripts/flight-recorder-retrieval`. Using
`search` records a foreground run and samples a shadow comparison automatically.
Ordinary Claude Code/Codex conversations are not intercepted. There are no model
calls, network calls, scheduler changes, production-index rebuilds, automatic
configuration adoption, or paid evaluation in this pilot.

## Data ownership

- Existing application session logs remain the original source.
- Existing local Semantic Receipts remain the summary source.
- A dedicated local lab contains `snapshot.json` and `measurements.sqlite`.
  Each corpus generation is immutable, with a mutable measurement ledger.
  Optional refresh archives generations under `snapshots/` before atomic publication.
  Requests, queued shadows and evidence reads retain their original generation.
- Lab directories are owner-only, have an ignore-all `.gitignore`, and must live
  **outside the Vault and code checkout**. Questions, answers, gold labels, and
  original conversation text must never be committed or pushed.
- The importer reads only explicitly registered source logs and existing
  receipts. Freeze the corpus before running an experiment; do not register or
  import evaluation sessions into its successor corpus. For manually prepared corpora this exclusion is an operator responsibility.
  The optional live importer below also detects known retrieval tool invocations.

## Prepare once

Use a nonexistent lab directory whose parent exists. Example:

```sh
LAB_PARENT=$(mktemp -d)
LAB="$LAB_PARENT/recall"
scripts/flight-recorder-retrieval --lab "$LAB" prepare \
  --vault "$HOME/.local/state/agent-harness-flight-recorder"
```

This can work while the production evidence index is stale. It does not claim
the production index's authenticated seal: source prefixes and exact receipt
spans are checked against their registered digests in a local, owner-controlled
experiment. The snapshot content hash detects accidental changes, not malicious
rewriting by the owner.

The exporter selects the latest registration per source path and verifies the
registered byte prefix; later appends do not change the snapshot. It extracts
user/assistant text, omits tool I/O and thinking, and divides original JSONL line
positions into 40-line windows. Codex event-message mirrors are omitted to avoid
duplicating response-item messages. Both search arms receive **the same windows**.
Verified receipt summaries are attached to overlapping windows only. Missing or
changed sources, invalid spans, and bounded windows are counted in `import_report`.

This is conversational-text retrieval, not full tool-log search or whole-task
reconstruction. Registered logs may be a biased subset of all sessions. Windows
may cut across conversational boundaries. Summary text is often in a different
language than the query; this lexical pilot does not translate or embed it.

For synthetic data, `prepare --manifest corpus.json` accepts:

```json
{"schema_version":1,"documents":[
  {"source_id":"session-example","start_line":1,"end_line":4,
   "text":"We stopped waiting for Friday and publish finished drafts immediately.",
   "summaries":["Publication timing decision: waiting caused missed submissions."]}
]}
```

Same source/range/text is deduplicated; alternate summaries are merged. Conflicting
text for one range is rejected. Stable citation IDs include source, range and text.

## Natural use and shadow comparison

```sh
scripts/flight-recorder-retrieval --lab "$LAB" search 'publication timing'
scripts/flight-recorder-retrieval --lab "$LAB" read CITATION_ID --request-id REQUEST_ID
scripts/flight-recorder-retrieval --lab "$LAB" feedback REQUEST_ID relevant
scripts/flight-recorder-retrieval --lab "$LAB" report
```

The default arm is `recorder`; `--arm baseline` searches original conversation
text only. Recorder adds summary terms for ranking but returns original text as
evidence. Source IDs and filenames are not searchable features. Both arms use
the same English-word/Japanese-bigram scorer and bounded top-k (default 5).

By default, 10% of requests are selected using a request-ID hash. The CLI flushes
the foreground result before spawning a detached local worker. It never waits
for the shadow result. The worker has a 5-job, 10-second cooperative budget; the
queue reserves at most 100 shadow jobs per UTC day per lab. Each shadow uses the
same snapshot, query, k, and retrieval version. Idle labs run no processes.
Snapshot load and individual operations are additionally bounded by corpus size;
the time budget is cooperative, not a process-level hard real-time guarantee.

`--sample-rate 1` selects all requests within the daily cap. `--no-worker` records
and queues without launching; drain later with:

```sh
scripts/flight-recorder-retrieval --lab "$LAB" worker --max-jobs 5 --max-seconds 10
```

Atomic claims avoid duplicate work by concurrent workers. A crashed worker's
120-second lease can be reclaimed by a later invocation. There are no paid calls
to double-charge. Contract mismatches and exhausted time budgets are recorded as
errors rather than compared. Worker startup failure leaves jobs queued.

Feedback is explicit: `relevant`, `wrong_target`, or `unresolved`. Silence remains
`unknown`. Feedback applies only to the foreground; the shadow does not inherit
it. Corrections are retained in a timestamped history; the pilot does not infer
reformulation count from separate queries.

## Metrics and meaningful differences

Every run stores snapshot ID, retrieval version, arm, original query, ranked raw
citations, search-computation milliseconds, indexed UTF-8 bytes, and delivered
raw-text UTF-8 bytes. The foreground additionally measures snapshot load and
ledger work through its initial insert; CLI startup/serialization and final
commit are not included. Citation reads have their own latency and byte counts.
Provider tokens/cost stay `null`, not invented zero. The implementation makes no
provider calls; this is distinct from a measured provider usage report.

`report` returns totals plus `review_cases` only for:

- one-sided retrieval;
- a different first citation or different candidate membership;
- identical nonempty results with >=100 ms and >=2x search latency difference;
- explicit wrong-target feedback;
- unresolved answer citations, unsupported claims, or differing answer assessments.

These cases are **needs_review**, not automatic wins. Lower-rank reorderings
alone are suppressed. Source existence is a retrieval fact, not an answer-quality
score. The report deliberately has no combined scalar score or auto-adoption.

After inspecting a case, mark its current fingerprint as read:

```sh
scripts/flight-recorder-retrieval --lab "$LAB" acknowledge REQUEST_ID FINGERPRINT
```

It disappears from the default report, but remains available with
`report --include-reviewed`. Changed feedback or answer evidence creates a new
fingerprint and makes the case visible again. Acknowledgement never means correct
or improved. Per-arm aggregates include unpaired foreground requests; compare
performance on matched pairs or fixed benchmarks, not unequal aggregate cohorts.

## Answer assessment without confusing retrieval with correctness

An answering agent can register its answer and citation IDs:

```sh
scripts/flight-recorder-retrieval --lab "$LAB" answer REQUEST_ID \
  --arm recorder --file answer.json
scripts/flight-recorder-retrieval --lab "$LAB" review-packet REQUEST_ID
```

`answer.json` contains `{"text":"...","citations":["..."]}`. Both arms can be
recorded after paired retrieval finishes. `review-packet` exposes question,
answers, and cited original text under opaque candidate labels. It excludes
summary text, timing, scores, and arm names. A model or human may judge this
packet; the package does not automatically call a judge or provide a security
sandbox for an external model. Identical answer bodies/refs share an answer ID.

Record a judgment explicitly:

```sh
scripts/flight-recorder-retrieval --lab "$LAB" assess REQUEST_ID --file judgment.json
```

```json
{"answer_id":"...","grounded":"supported","unsupported":"absent",
 "provenance":"human-review-v1"}
```

Grounded values are `supported`, `unsupported`, `unknown`; unsupported-claim values
are `present`, `absent`, `unknown`. Provenance identifies the human rubric or
model/rubric, not a certification. Supported judgments require existing citations;
replacing an answer invalidates its prior judgment. Existing but irrelevant
citations can only be caught by the independent assessment. Human intent remains
separate from textual support.

## Fixed retrieval regression cases

Prepare gold cases from original text, independently of available summaries:

```json
[{"question":"Why did the publication schedule change?",
  "expected_citations":["citation-id-from-this-snapshot"]}]
```

```sh
scripts/flight-recorder-retrieval --lab "$LAB" benchmark --cases cases.json --repeats 2
```

This runs both arms, alternates their order across cases/repeats, and outputs
evidence-hit@5 and reciprocal rank observations alongside metrics. Gold citations
are never passed into retrieval, persisted as query history, or used to trigger
shadow work. The aggregate is **retrieval coverage**, not grounded-answer accuracy.
Gold answers, natural user intent, and held-out cases require independent curation.

## Remaining steps

This release provides the search/measurement entry point, automatic sampled
local shadows, citation reads, explicit feedback, blinded assessment packets,
and reproducible retrieval regression. It does not yet provide automatic
answer generation/judging, model-cost accounting, cross-session task joining,
automatic search-policy changes. Opt-in refresh and evidence-preserving retention
are described below.
Those should be added only with measured benefit and separately bounded budgets.

Run the contracts:

```sh
bash tests/test-retrieval-lab.sh
python3 -m unittest discover -s tests -p 'test_retrieval_snapshot.py'
```


## Optional automatic conversation addition

`retrieval_refresh.py` wraps the same CLI and starts a detached local refresh
**after a successful search**, at most once per 15 minutes. It does not install a
scheduler. Idle labs do no work. The initiating search uses the last valid corpus;
new messages become searchable after the refresh finishes. This avoids adding
collection latency to foreground retrieval. Fixed labs keep their existing behavior.

Opt in by creating owner-only `refresh-config.json` inside the existing lab:

```json
{"schema_version":1,"roots":[
  {"adapter":"claude-code","path":"/absolute/path/to/claude/projects"},
  {"adapter":"codex","path":"/absolute/path/to/codex/sessions"},
  {"adapter":"codex","path":"/absolute/path/to/codex/archived_sessions"}
],"interval_seconds":900,"exclude_sessions":["evaluation-session-id"]}
```

Use `python3 scripts/retrieval_refresh.py --lab "$LAB" search 'earlier decision'`
in your local command wrapper. `refresh --force` performs the initial import or
an explicit retry; `refresh-status` shows counts, last success, and failures.
Initial refresh scans configured roots; subsequent runs read changed files with
a 60-second overlap, replacing those sources rather than appending duplicate windows.
Changing config triggers a full recollection. Include `archived_sessions` explicitly
alongside `sessions` to retain access when a Codex conversation is archived.
The successful source inventory also detects new paths whose original mtime was
preserved by a move. A complete scan retires vanished paths from the current
corpus, preventing duplicate windows after archive/unarchive moves. If a configured
root is missing or a directory changes during the scan, previously indexed paths
are retained until a complete scan. An incomplete scan after configuration changes
keeps the entire last valid corpus and successful watermark.
Historical snapshots and request-bound citations remain unchanged; this is not
secure erasure or retention cleanup.

Only complete JSONL lines containing user/assistant text enter the corpus.
Oversized conversational messages are omitted and counted; malformed sessions
are quarantined as whole sources and counted, without stopping other imports. Tool
output and reasoning are omitted. Entire conversations invoking
low-level measurement commands or explicit verification are excluded, including
commands wrapped in tool code; ordinary recall retains user text as described below;
subagent sessions are also excluded. Explicit `exclude_sessions` is required for
other evaluation sessions or custom wrappers that the detector does not recognize.
This is a conservative filter, not proof that every evaluation session is detectable.
An already searched snapshot remains immutable even if a later refresh excludes a source.

No new summaries or paid calls are generated. Optional `source_vault` points to
registration metadata for mapping summaries from the old registered corpus;
only identical source/span/text can inherit existing summaries. Newly added raw-only
windows are identical across both search arms. Summary coverage must therefore be
considered when interpreting recorder-versus-baseline differences.

JSONL collection streams one record at a time, rather than loading entire logs.
Limits are 256 MiB per source, 4 GiB actually read per refresh, and 8 MiB per raw
record. A raw record above that limit quarantines its whole source: blindly
skipping it could hide a retrieval/evaluation command. Subagent and evaluation
sources stop reading as soon as exclusion is established. Late exclusion still
discards all earlier messages from that source. The existing 100,000-character
message/window, 20,000-document and 60 MiB manifest limits remain in force.
Status reports `oversized_records` and `excluded_oversized_sessions` separately
from oversized conversational text. File identity, size and modification time
are checked around streamed reads, including early exclusions.

Collection and publication are bounded. An unstable read, oversized corpus or
other import failure preserves the last good corpus and successful watermark;
the next eligible search retries. A local lock prevents simultaneous refreshes.
Automatic refresh retains all snapshots referenced by measurement database
rows (including historical opportunity/follow-up revisions), the current corpus,
and local text artifacts. It removes only unreferenced archive generations,
keeping up to three recent spare generations when space permits. The default
archive budget is 1 GiB. Cleanup runs before collection to recover an already-full
archive, and admission reserves space for the next generation before publication.
Protected evidence is never evicted to fit the budget: if it cannot fit, publication
stops without advancing the successful collection watermark.

`storage-status` previews the protected/removable counts and projected bytes
without deleting anything. `refresh-status.storage` and `storage-state.json` expose
usage, the latest cleanup counts, and a fixed warning/error code. At 80% of budget,
`warning=snapshot_capacity_high` appears even if collection succeeds. Foreground
searches print a brief warning; the existing scheduler observer preserves it in
its status rather than discarding the refresh result. A throttled retry retains
both the warning and the previous collection failure. This is local status, not
an independent notification service.

Optional `refresh-config.json` settings:

```json
{"retention":{"budget_bytes":1073741824,"warning_percent":80,"keep_recent":3}}
```

The budget covers the actual bytes of `snapshots/*.json` and `*.json.gz`,
not the current corpus, database, or other
lab files. Local `.json`, `.jsonl`, `.md`, `.txt`, `.py`, `.log`, `.diff`, `.err`
artifacts and all text/blob fields in local `.sqlite` databases conservatively pin
matching snapshot hashes, even under unfamiliar field names. The scan is bounded
at 10,000 files and 256 MiB of reference data; unreadable/corrupt databases,
unsafe paths, exceeded scan bounds, missing required evidence, or corrupt
candidates abort deletion. No raw content is copied into storage diagnostics.

Before creating an external or otherwise unrecognized fixture, run
`snapshot-pin SNAPSHOT_ID`; this validates and atomically records the pin in
`snapshot-pins.json`. Keep that pin for the lifetime of the fixture. Custom
artifact writers must pin before writing or hold `retrieval_lab.snapshot_lock`
through reading and saving their reference. Merely holding an in-memory snapshot
outside the lock is not a persistent reference. Automatic readers hold a shared
lock through search and reference registration; refresh, publication and cleanup
hold the exclusive lock. Deploy by draining old runtime processes first, since
older releases do not participate in the shared-reader protocol. Fixed labs
without automatic refresh keep their existing retention behavior. Questions, content and errors containing raw paths/text are not logged by
refresh status. All state remains owner-local, outside Git and the Vault.


### Lossless archive compression

Automatic refresh writes each new archived generation as an independent gzip file
(`SNAPSHOT_ID.json.gz`, level 6). The live `snapshot.json` stays uncompressed, so
foreground searches do not decompress the archive. Request-bound citations,
follow-up/opportunity inspection and historical replay accept both formats without
changing snapshot IDs, citation IDs, queries, feedback, or evidence content.

Legacy archives convert in batches of at most two per refresh, before capacity
admission, including when storage is already full. `storage-compress` explicitly
converts up to five generations per call and reports remaining plain generations.
It then reapplies the same evidence-preserving retention policy. This is a format
migration; it does not count as successful search use or improved retrieval.

Conversion validates the original generation, writes gzip through an fsynced
atomic rename, reads it back with a bounded decoder, and compares **all original
bytes** before unlinking the plain file and syncing the directory. Modification
times are preserved for spare-generation ordering. If interrupted between the
rename and unlink, both formats can coexist; a retry verifies equality before
removing the redundant plain copy. A conflicting or corrupt twin is an error,
never a reason to delete the original. Both physical files count toward storage
until reconciliation, but retention counts one generation and evicts twins together
only when that generation is unreferenced. Expanded data remains bounded at 64 MiB;
CRC/truncation errors and snapshot document-hash mismatches are rejected.

The temporary compressed file needs additional free disk space during conversion;
it is not charged as permanent archive growth. Filesystem write failure keeps the
original. Each gzip is independently recoverable with standard gzip tools, without
a chain of deltas or another generation. Use the updated storage reader for custom
evaluation scripts; a frozen ranker can remain unchanged while its storage reader
is upgraded. Older runtime releases cannot read gzip archives: restore plain
archives before rolling back to a pre-compression reader, or keep the compatible
reader. Do not simply switch an old launcher back over a compressed archive.

Generation-level compression intentionally avoids document-level shared objects:
there is no new reference graph or garbage collector. Protected generations still
accumulate and remain subject to the same 80% warning and hard storage limit.


### Human correction retrieval pilot

The first value hypothesis is avoiding repeated user corrections by retrieving
an earlier correction and its rationale before acting. Measure three separate
steps: retrieving the original, using it in a decision, and avoiding repeated
rework. Positive tone, continuation, silence, and automated evaluator feedback
are not success labels.

Live collection excludes sessions whose first user message matches the bundled
session-card distiller or exploration evaluator frame (including its structural
markers). Their copied transcripts otherwise compete with original conversations.
The `excluded_generated_sessions` counter reports exclusions. This is a narrow
known-template filter, not general human-authorship detection. Later discussion
and quoted examples stay searchable. Other generated prompts and in-session hook
messages may remain; callers must inspect originals before interpreting feedback.

Collector upgrades force a complete recollection even when source mtimes have
not changed. Failed or over-budget scans retain the previous corpus and
collector version. Incomplete inventory during a collector/configuration change
also retains the previous corpus. With unchanged collection settings, an
incomplete incremental inventory may publish scanned updates while retaining
unseen sources. Old request-bound citations remain readable. The streamed
aggregate scan budget is 4 GiB; the 256 MiB source, 8 MiB record and 60 MiB manifest
limits are unchanged. No model calls are needed.

Evaluate on a fixed local corpus with queries fixed before reading the new
ranking. Count known generated hits separately from genuine correction hits;
removing duplicates alone does not demonstrate reduced rework. Keep real logs,
queries and annotations in the private measurement lab, not this repository.


### Connecting user-turn context recall

`corrections QUERY --trigger resume|ambiguous|explicit --limit 3` searches user
turns with BM25 and a small preceding-context contribution. The name describes
the use case; results are candidates, not automatically classified corrections.
Only collector-produced `message_spans` are used, never role markers parsed from
quoted text. Legacy documents are counted and skipped until recollected.

Each result includes the user turn, preceding user request and assistant response,
original citation IDs, the pinned snapshot and a request ID. The snippets are
bounded; use `read CITATION --request-id REQUEST` for original evidence, including
context citations when needed. Sources never mix, future responses are excluded,
and prior context is explicitly provisional rather than a guaranteed task link.

After interpreting the result, record `context-use REQUEST --file FILE` with
JSON `{ "state": "applied|not_applicable|unresolved", "citations": [], "reason": "..." }`.
Applied use requires at least one returned citation already read for that request.
The record is an agent self-report, separate from user feedback and independent
assessment. `context-report` summarizes invocation triggers, original reads, and
self-reported use. No search means no observation: missed opportunities and actual
rework reduction are not measured by this report. Context mode does not schedule
a misleading baseline/summary shadow pair. Ordinary search is unchanged.

The discoverable skill is `skills/recall-history/SKILL.md`. Install it in the
runtime's skill directory alongside a `recall-history` wrapper using the same
release's scripts. Its description offers proactive use for relevant resumption
or scope ambiguity; it does not force every task to search. No global hook or
universal preference is created. Selection still depends on the agent; command
E2E does not prove autonomous skill selection. Skills already loaded into a
conversation may require a new session to discover the updated description.

Use `--purpose verification` for installation checks; the default is `task`.
`context-report` counts purposes separately so smoke checks are visible rather
than silently presented as organic use. Aggregate read/use totals include both.


### Ordinary recall retention

Collector v7 keeps user-role messages in ordinary `recall-history` sessions,
including subsequent corrections. It preserves assistant context before the invoking user turn, then omits
assistant messages from that turn onwards so retrieved quotations cannot be
recycled or paired with later user turns as stale context. This deliberately sacrifices assistant context in recall
sessions; it does not prove that every user-role message is human-authored.
Known injected skill/agent frames are omitted. Tool results are never indexed.
Explicit exclusions, generated evaluations, subagents, low-level retrieval tools,
and `--purpose verification` still quarantine entire sources. Custom evaluations
must be explicitly excluded. A collector-version change triggers recollection;
previous request-pinned snapshots remain readable.

Import reports expose retained_recall_sessions, omitted_recall_assistant_messages,
and omitted_injected_messages separately from excluded_retrieval_sessions.


### Inspecting daily invocations

`corrections QUERY --trigger resume --task 'current task and target'` records
cwd and an allowlisted CODEX_THREAD_ID when available. `--session-id` is an
explicit fallback; absent values stay null. These are caller-supplied context,
not verified project identity or authority. No other environment variables are
collected. Paths and task descriptions remain in the owner-only lab.

`context-report --purpose task` separates everyday use from verification and
lists recent request IDs. `context-inspect REQUEST` joins the original query,
origin, snapshot/version, refresh status at invocation, ranked candidates, score
contributions per token/field, original reads, and use decision. It neither reruns
retrieval nor records a citation read. Older records keep missing data unknown.
BM25 scores are ranking values, not calibrated relevance confidence.

`context-use` accepts optional reason_code and effect fields. Reason codes are
state-specific: applied/relevant; not_applicable/wrong_scope, outdated,
already_known, no_relevant_candidate; unresolved/insufficient_context,
collection_problem. Effects apply only to applied: confirmed, changed_plan,
avoided_question. Reasons and effects remain agent self-report and do not update
human feedback or independent assessments. Missing details are not inferred.

Retrieval metrics omit model cost when unknown. Foreground time covers snapshot
loading and ranking, not end-to-end agent deliberation. Caller cwd may be a hub
or worktree, not the intended target repository; the task label supplies scope.

Context ranking v2 treats identifiers such as `APP-587` as complete tokens;
a bare `587` in an unrelated pull request no longer matches the ticket suffix.
Token contributions are stored in the invocation log and returned by inspect;
normal CLI results omit the detailed contributions to limit context overhead.

CLI output masks recognized credential formats (including common key prefixes,
Bearer headers, private-key blocks, and labeled key/password assignments). A
changed display carries `display_redacted: true`. This is best-effort masking,
not a guarantee that arbitrary secrets can be identified. Owner-only originals,
query evidence and citation hashes remain unchanged; masking is at display time
and applies equally to search, read, and inspect.


### Agent consultation provenance and Japanese single-character queries

Collector v8 labels a source `agent_consultation` when its first user message
starts with the exact known consultation-bridge envelope (including the explicit
caller-provenance sentence). Later unwrapped followups share that provenance.
A prefix fragment, quoted example, or the envelope later in an ordinary
conversation does not classify that conversation. `consultation_sources` counts
these sources in the import report. This is a narrow known-format detector,
not proof of human authorship for all remaining sources.

Consultation content and advice remain in the corpus for ordinary `search` and
request-bound `read`, which display the source kind. `corrections` excludes those
sources and reports `consultation_sources_skipped`. A known model-review envelope
is also excluded from correction candidates, without deleting it from history.
This keeps generated advice available without presenting agent prompts as human
corrections. Collector-version recollection adds provenance to unchanged sources;
old snapshots and citations remain available unchanged.

Context ranker v4 matches a single-character Japanese query term inside longer
unsegmented sentences. Previously a query containing a standalone character
could miss that same character in a sentence because only character bigrams were
indexed. Occurrences are counted once, including standalone occurrences. Other
query tokenization and BM25 weights are unchanged. Detailed score contributions
still disclose the matched terms. The change requires no model or provider call.


Context ranker v5 reduces hiragana-only query token contributions to half when
other token types are also present. Long conversational queries otherwise give
many small wording matches enough combined weight to outrank the subject.
Hiragana-only queries retain full weights; no tokens, candidates, negations, or
original text are removed. This script-based heuristic can also downweight
meaningful hiragana words, so it is not semantic intent recognition.
Diagnostics v2 exposes `query_weights` and each contribution's `query_weight`;
the scores still sum to the displayed total. Historical results are not rewritten.
Opportunity replay cache keys include the ranker version, and new packets record
`retrieval_version`. Reports select the current composite version; old case IDs
remain inspectable. A ranker update can produce new retrospective packets for the
same turn without mixing old and new rankings in the current cohort.

For a private regression, freeze the original request, the eligible earlier
cross-session corpus, and the expected source/citation/line separately. Pass only
the original request and corpus to the ranker, never the expected answer or later
correction. Keep fixtures and reports outside Git and task-use measurements.
Record the corpus hash, ranker version, and before/after ranks. A case used to
develop the weighting is a development regression, not held-out evidence of
benefit. Replay earlier adopted citations too, and distinguish agent-reported
adoption from user-confirmed correctness. Corpus presence now does not establish
availability at the original turn or causal savings in real work.


### Prospective decision-need measurement

`corrections --need 'Which past decision is needed now?'` stores the need with the
query before results are returned. `--retry-of REQUEST` links one focused retry;
the original need, purpose and caller session cannot change. Older calls without
a need remain a separate legacy cohort. No retroactive labels are inferred.

`context-use` optionally accepts `decision_match`: `found`, `partial`, `not_found`,
or `unknown`. New workflow calls include it in the existing use record. Found and
partial require returned citations actually read under that request. Finding a
past decision and applying it are separate: found + not_applicable is valid.
The reason describes the answer to the need and its present applicability.

`context-report --purpose task` adds `decision_needs`: unique needs, statuses,
initial/retry discovery counts, unknown/unreported counts, known caller sessions,
and up to 20 recent review cases (non-found or recovered by retry). A retry does
not enlarge the need denominator. Every attempt keeps its own snapshot, results,
reads, use and timestamps for `context-inspect`. Verification calls are excluded
by the purpose filter. Missing IDs remain unknown; no new-session claim is made
for them. The ordinary ranking algorithm and collection are unchanged.

This runs through the installed skill during normal work, with no user scoring,
extra model call, scheduler or external transmission. Invocation and citation
reads are observations; decision match and effect remain agent self-reports.
Sessions without searches are outside the denominator. This does not establish
recall over all needed decisions, user satisfaction, causal benefit or reduced
rework. Silence and abandonment never become positive feedback.

The combined status is the latest attempt, so a later unresolved retry does not
keep an optimistic found total. Review cases preserve every `attempt_reports`
match, citation and reason, including earlier partial evidence; latest not_found
does not mean all earlier evidence was absent or retracted.


### Passive uninvoked-recall opportunity candidates

Collector v9 adds timestamp, native session identity, known recall-tool marker,
assistant-observed and next-user-boundary flags to user turns. Old citation IDs
remain unchanged; snapshots include the new metadata. Unknown or regressing
source timestamps are excluded from temporal replay. Consultation/evaluation,
generated, subagent and explicitly excluded sources retain their exclusions.
A known marker is conservative: a tool command mentioning help may count; aliases
and other retrieval tools may not. It is not an execution-success detector.

Opt in through the lab refresh config:

```json
"opportunities": {"since": 0, "prospective_since": 0}
```

Use actual Unix epoch boundaries when deploying. `since` bounds the bootstrap
window; `prospective_since` separates later observations. On refresh, up to ten
unseen candidates run with an eight-second between-case budget. A single bounded
retrieval may finish after that budget. Cases persist idempotently in the existing
owner-only measurements DB, separately from query/use/evaluation counts.

Candidates are narrow history-reference cues, or the request preceding a later
correction. Later correction text only discovers the case and is never query
input. Same-source, same-UTC-day non-cue turns provide deterministic controls
where available; unmatched counts are visible. Replays use at most 600 characters
of the anchor request, and earlier user text from other native sessions. Same
native-ID archive copies and exact anchor-text copies are excluded. Arbitrary
fork lineage is not resolved. No tool/assistant or future text enters ranking.
Reports retain exact source lines, immutable snapshot/citation IDs and excerpts.

The current corpus may contain old text collected after the turn. Therefore
`availability_at_turn=unknown`: these are current-corpus replays, not historical
retrievability claims. A lexical hit proves neither a decision nor relevance or
benefit. Review candidates and controls, not a fabricated recall/success rate.
Final turns without a subsequent user boundary remain pending, including sessions
that ended normally. Silence and abandonment are not evaluated as success.

For search-independent execution, the existing recorder scheduler calls an
optional `scheduler/recall-observer.json` before deciding whether Vault sync is
due. Configuration is local and ignored by Git:

```json
{"schema_version":1,"command":"/absolute/path/to/recall-history"}
```

The owner-controlled non-symlink command is invoked as an argument vector with
`refresh`, a 120-second timeout and no inherited stdin/output. The lab's existing
refresh throttle controls scan frequency; no new timer, external transmission or
model call is added. Failure writes `scheduler/recall-observer-status.json` and
must not stop sync. Disable by removing this opt-in configuration; existing
snapshots and observations remain. `opportunity-report` shows the audit status,
bootstrap/prospective cohorts and up to ten candidate/control packets each.

Known question-reply envelopes are interpreted using their human answer only
for cue detection and replay ranking; model-authored questions and wrapper IDs
remain solely in the inspectable raw source. Cue detection uses the same bounded
request prefix as replay. Detector versions have separate case IDs/cohorts, so
retired detector candidates are preserved for inspection but not current totals.

Cue-free sessions are also sampled: deterministically select 10% of eligible
native-session/UTC-day groups, at most one non-cue turn per selected group. These
control packets carry `control_origin=background_sample`; cue-matched controls
carry `matched`. Sampling is not a universal denominator or a gold negative.
This exposes possible silent opportunities without requiring an explicit cue.


### Natural follow-up observation

Opt in with `"followups": {"since": <unix timestamp>}` in the existing local
`refresh-config.json`. Use deployment time to start a prospective cohort. The
existing refresh/scheduler invokes the observer even without another search;
there is no new timer or provider call. At most 100 needs are checked per refresh,
with least-recently checked needs first. Collection failures and observer status
remain visible; no forced collection or success claim is made by a report.

Only task-purpose searches with prospectively recorded decision needs enter this
cohort. A retry stays with its root need. Native session identity and timestamps
link the first search to its preceding user turn; absent IDs, ambiguous or missing
timestamps, missing sources and anchors without an observed assistant response
remain unlinked. This is a time-based association, not a verified tool-to-turn ID.
No cwd or textual similarity is used to guess a caller. Identical archive copies
are deduplicated and known injected frames do not consume the observation window.

Observe up to three following user turns within seven days. Store their original
citation/line references and lexical restatement/correction cues. Distinguish
pending, observing, window_complete, no_followup_observed and unlinked. A full
window without detected cues is an observed negative for this detector, never
proof that no correction or dissatisfaction occurred. Silence is not success.
Short follow-ups can refer to new requirements; a lexical cue is not a verdict.

`followup-report` exposes cue-prioritized cases, unique turn counts, overlapping
windows, and descriptive counts stratified by ranker version, trigger and the
agent's decision-match report. Only reads and use/match reports recorded before
the first follow-up count as prior exposure; late reports remain visible on the
need but cannot retroactively explain the earlier response. Current use records
are replaceable, so a missing historical early report is unknown, not recovered
from a later report. Counts are per need, not independent tasks. Do not sum
subgroup counts into user correction events; use the deduplicated turn counts.
`context-report --purpose task` includes the compact observation summary.

`followup-inspect CASE --blind` returns cited original user text without retrieval
results or self-reports. Review that text first, then consult the search and prior
evidence. `followup-review CASE --file JSON` records an agent retrospective label:
`repeated_prior_decision`, `new_requirement`, `other`, or `uncertain`, plus observed
follow-up `citations` and a bounded `reason`. A repeated-decision label additionally
requires `prior_decisions` references with exact `citation_id` and `line`, validated
as user turns earlier than the anchor in the fixed snapshot. This validates timing
and provenance, not the semantic review. Review records never alter user feedback,
search use, or success metrics.

Evidence revisions are immutable and deduplicated; a separate current pointer
allows reports or collection state to change back to an existing revision without
silently keeping a stale state. Historical case IDs remain inspectable and their
reviews stay tied to those revisions. All data lives in the existing owner-only
lab database and snapshot archive, never the public repo or vault sync.

This measures observable follow-up evidence, not causal time saved. The cohort
excludes searches without needs, uninvoked searches and other-session follow-ups;
legacy-search counts and linkage gaps are explicit. Found/not-found groups differ
in task difficulty and are not randomized controls. Keep existing opportunity
sampling separate; no result from it is silently promoted to an observed failure.


### Refresh health and interrupted workers

`refresh-status` separates the persisted collection `status` from derived `health`.
A successful exit or a throttled/busy refresh is not evidence of fresh collection.
`health` becomes error after two configured intervals plus the 120-second worker
allowance without success, when a running record no longer has a refresh lock
owner, or when follow-up/opportunity observation fails. The scheduler preserves
freshness and timeout failure reasons; empty/legacy health reports fail closed.
An active worker is reported as running, not completed.

Each attempt persists its current `stage`, bounded `stage_ms`, and a sanitized
`error_code`. Exception text, source paths, and conversation excerpts are omitted.
A source changing during collection retries the whole export once. A second
failure preserves the previous snapshot and successful watermark. Other errors
are not automatically retried. The worker timeout allows bounded retention and
collection work within the existing five-minute scheduler wakeup. SIGKILL or
power loss cannot write a final record; the next status check detects the released
lock and the next refresh records the interruption before retrying when due.
