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
retention automation, periodic corpus refresh, or automatic search-policy changes.
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
root is missing, previously indexed paths are retained until a complete scan.
Historical snapshots and request-bound citations remain unchanged; this is not
secure erasure or retention cleanup.

Only complete JSONL lines containing user/assistant text enter the corpus.
Oversized conversational messages are omitted and counted; malformed sessions
are quarantined as whole sources and counted, without stopping other imports. Tool
output and reasoning are omitted. Entire conversations invoking known recall or
measurement commands are excluded, including commands wrapped in tool code;
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
Limits are 256 MiB per source, 2 GiB actually read per refresh, and 8 MiB per raw
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
At 1 GiB of archived snapshots, automatic publication stops and `refresh-status`
reports an error; archives are never silently deleted because measurements refer
to them. Questions, content and errors containing raw paths/text are not logged by
refresh status. All state remains owner-local, outside Git and the Vault.
