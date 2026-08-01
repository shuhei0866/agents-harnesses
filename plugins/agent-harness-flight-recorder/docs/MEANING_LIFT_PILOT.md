# Meaning Lift pilot

Date: 2026-07-31

This pilot tests whether a minimized semantic projection makes one real
Flight Recorder Episode more useful than lifecycle metadata alone. It is not
an automatic-routing benchmark.

## Input boundary

The selected completed task was a request to create an issue after checking
for duplicates. The registered source span contained 11 JSONL lines. The
deterministic extractor produced:

- a 743-byte `meaning-packet-v1`;
- two evidence items: a 10-character user intent and a 55-character final
  assistant result;
- no tool input/output, thinking, code body, source path, or recognized secret.

The packet was transient. The stored Meaning Card contains only bounded
summaries, evidence IDs, hashes, and recorder-generated provenance.

## Result

The deterministic baseline scored `0.0/5.0`. The Meaning Card scored
`4.0/5.0` on the same conservative comparison:

| Question | Baseline | Meaning |
| --- | --- | --- |
| Intent | uncovered | covered |
| Deliverable | uncovered | partial |
| Verification and outcome | uncovered | partial |
| Reusable learning | uncovered | covered |
| Time and API cost | uncovered | covered |

The most useful result was not the score itself. The lifecycle event
looked completed, while the semantic evidence only showed an intention to file
the issue. It did not prove that an issue was created. The Meaning Card
therefore recorded an `unknown` outcome with medium confidence. This is a
material distinction that the metadata-only baseline could not make, and it
kept both deliverable and verification/outcome at partial rather than awarding
full credit for fluent summaries.

The corrected interactive evaluator step took 239 ms and recorded zero
micro-USD. The full command took roughly four minutes because it authenticated
the complete 15,215-event relationship graph before and after evaluation. One local
content-addressed Card was stored, and a scan found no source path, recognized
secret, tool-output canary, or packet canary in local Card storage. The
automatic evaluator budget remained zero.

An earlier draft comparison reported `0/5` to `5/5`. Review found that its
baseline queried fields that do not exist on the deterministic Card and that
an `unknown` outcome was over-credited. That number is superseded by the
corrected `0.0` to `4.0/5.0` result above.

## Provider smoke results

The bundled Claude subprocess did not generate a Card. It returned a 401 API
error after 177.2 seconds, with zero provider cost and no structured output.
A separate ephemeral, read-only Codex CLI smoke reused the locally reported
ChatGPT login but failed its non-interactive stream with authentication errors
after 16.5 seconds and produced no final output.

The successful Card is therefore explicitly identified as an interactive
pilot, not as a successful unattended provider call. This keeps provenance
honest while still testing the packet, schema, validation, comparison,
content-addressing, privacy scan, and local storage path end to end.

## Decision

The semantic projection adds useful information, especially by separating
work completion from verified outcome. The experiment supports continuing the
Meaning Card direction, but it does not support enabling automatic paid
generation yet.

Before automatic integration:

1. establish a reliable non-interactive subscription-auth boundary for at
   least one evaluator;
2. replace whole-graph pre/post authentication with an authenticated
   per-Episode snapshot or equivalent bounded check;
3. retain the fixed five-question comparison, packet-only provider boundary,
   measured cost/latency, and no-retry fingerprint;
4. run several exact tasks with externally verifiable deliverables and compare
   semantic outcome against the actual artifact or issue state.
