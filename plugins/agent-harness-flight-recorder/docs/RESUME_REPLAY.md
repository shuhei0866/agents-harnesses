# Historical work-resumption pilot

## Hypothesis

A short, cited memo of previous decisions, unresolved questions and planned next
steps helps an assistant propose an appropriate next action when work resumes.
This pilot tests historical **proposals**, not actual work or user time saved.

The no-memo and memo-assisted planners receive identical pre-resumption history
and the same resumption request. Only the assisted planner receives an additional
memo. It therefore isolates the aid of organizing existing context; it does not
measure the value of retrieving otherwise unavailable history.

## Local use

Use an existing owner-only retrieval lab outside Git and the Vault. The existing
`measurements.sqlite` stores immutable case sets and replay results in `resume_*`
tables. Retrieval snapshots and normal query records are unaffected.

```sh
scripts/flight-recorder-resume --lab "$LAB" mine \
  --config "$LAB/refresh-config.json" --limit 10
scripts/flight-recorder-resume --lab "$LAB" select SET_ID --file selections.json
scripts/flight-recorder-resume --lab "$LAB" evaluate SELECTED_SET_ID \
  --max-cases 10 --max-calls 40 --budget-usd 3
scripts/flight-recorder-resume --lab "$LAB" evaluate SELECTED_SET_ID \
  --provider codex --max-cases 10 --max-calls 40 --budget-tokens 200000
scripts/flight-recorder-resume --lab "$LAB" report BATCH_ID
scripts/flight-recorder-resume --lab "$LAB" memo BATCH_ID CASE_ID
```

Mining reads only configured Claude Code/Codex roots. Each case requires a short
explicit resumption cue, at least a 30-minute timestamp gap, preceding history,
and a subsequent assistant response. At most one newest eligible case per source
is selected. Automated task notifications, compaction prompts and local-command messages
are excluded. Codex ambient wrappers are removed for cue selection only, while
history citations retain original text. Fewer than ten eligible cases are reported honestly. This selection
is a small convenience sample, not representative of every interruption.

Raw JSONL line numbers and the exact preceding-byte digest define the cutoff.
Histories are bounded to 24 messages / 30,000 characters; holdouts to six messages /
12,000 characters. Whole messages omitted for bounds are counted. Both arms see
the identical bounded history; missing earlier decisions can affect both.

## Isolation and measurement

1. Memo generation sees only the historical prefix, with citations.
2. Separate planners propose one next action with and without that memo.
3. A fresh judge sees anonymous A/B proposals in counterbalanced order. It may
   inspect the observed continuation, which is **not authoritative gold**.
4. The report shows differing preferences/labels and uncertain cases for human
   inspection. Model judgments remain explicitly provisional; ties remain counted
   even when omitted from the difference list.

Known retrieval/evaluation sessions, subagents, explicit session exclusions and
malformed sources are omitted. Tools and thinking are never extracted. Do not
paste replay results into future evaluation inputs; custom evaluation tools may
need explicit session exclusion.

`evaluate` is explicit and consumes the existing authenticated Claude CLI's
usage. No new API key is required. It runs with safe mode, no tools or MCP, no
persisted session, and an empty working directory so current project files and
future task state cannot be inspected. Default CLI model selection is preserved and pinned within a comparison batch;
actual reported model identifiers and token/cache usage are stored per call.
Do not describe this evaluation as free: the CLI's dollar figure is an
API-equivalent usage estimate, not necessarily a subscription invoice.

One case takes at most four calls: memo, two plans, and judge. Calls have a
120-second timeout. Budget and call limits apply cumulatively to the cached
batch; changing limits resumes completed stages without rerunning them. Unknown
usage or a failed/ambiguous stage is never silently retried. Repeated mining of
identical cases reuses the same identity regardless of timing telemetry.

The report records provider-reported usage and wall time. Memo generation time
and usage must be included in the assisted condition. These are one-shot model
measurements, sensitive to cache, output length and default-model changes—not
proof of faster work. Actual first useful action, re-reading, and human correction
rates require a later real-use trial before automatic daily adoption.

## Verification

```sh
bash tests/test-resume-replay.sh
```

Synthetic tests cover temporal cutoffs, session exclusion, blinded labels,
invalid citations, memo structure, immutable cases, cache reuse, budget extension,
unknown usage and failure handling. No private conversations belong in commits.


### Codex adapter

`--provider codex` uses the existing Codex login when Claude is unavailable.
Only the top-level model and credential-store preferences are forwarded; user configuration, project
instructions, plugins, memories, hooks, shell, browser and other tool features are
disabled for replay. An ephemeral run in an empty directory is additionally
checked against an allowlist of model-message events: any tool execution or
unknown event invalidates the call. CLI startup warnings before a model turn are
counted; errors during the model turn invalidate the call. See the official
[configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

Codex reports tokens rather than a dollar quote. Its `--budget-tokens` gate uses
actual cumulative input plus output tokens; cached input is already included in
input and is not added twice. Input usage is only known after execution, so the
last call can cross this cooperative threshold. Output tokens are capped at
2,000 per call. Call count and 120-second timeout also bound the pilot. No dollar
cost is invented. Provider conditions use separate caches and are never mixed in
one comparison batch.


### Screening every mined candidate

Every mined case, including an explicit-cue case, requires selection review before
evaluation. A cue can refer to a different topic; it is not proof of continuity.
`selections.json` maps reviewed case IDs to reasons, for example:

```json
{"sha256:case-id-from-mining":"The request resumes the pending action in the prefix."}
```

If explicit cues yield no cases, `mine --include-gap-candidates` offers same-session
human requests following a >=30-minute gap. These too are **candidates**, not confirmed
work resumptions. `evaluate` refuses all unscreened mined cases. Inspect prefix history
and the resumption request, without reading the holdout outcome. Exclude topic
changes, closing acknowledgements and other evaluation sessions.

Use `select SET_ID --file selections.json`, where the file maps selected case IDs
to short reasons. Selection creates a new immutable set and records screening
as operator judgment, not outcome correctness. Empty candidate searches return a
count and diagnostic report without creating a set. Initial bad samples can be
invalidated locally in `resume_invalid_sets`; no model call may use an invalidated set.

Changing the configured Codex model cannot resume a partially cached batch with a
different model. Completed outputs remain bound to the original model. Claude
likewise pins the first response's reported model for subsequent stages.
