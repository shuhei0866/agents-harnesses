# Session Atlas classification pilot

Date: 2026-08-11

## Question

Can Flight Recorder describe which sessions are comparable before it compares
their Value vectors, duration, cost, or outcomes?

The first Value pilot exposed the failure mode directly: an identity-merge code
change and a Git pull/repair operation both produced positive goal and quality
signals, but comparing them as equivalent work would be meaningless.

## Boundary

This pilot classifies the ten Episodes that already had a stored Semantic
Receipt. It is a one-off, analyst-guided classification of the bounded task
intent and deliverable fields in those receipts; it does not create production
Atlas Cards. It does not read raw session logs or registered source paths.

Classification input deliberately excludes model, harness, outcome,
verification, duration, cost, retry count, and Value. Those are treatments or
results to compare *inside* a cohort; using them to create the cohort would
introduce selection leakage.

Only ten of roughly 24,000 recorded Episodes had a semantic anchor at the time
of the pilot. The result demonstrates that a three-facet shape separates this
sample. It does not validate classifier accuracy, stability, production label
enums, or historical coverage.

## Taxonomy

Each Episode receives three independent facets:

- `domain`: the problem space;
- `activity`: the kind of work performed;
- `deliverable_kind`: the thing produced.

The labels below are provisional vocabulary observed in this sample, not a
production enum. They were assigned by reading each Receipt's bounded task
intent and deliverable, selecting one concise label per facet, and normalizing
obvious synonyms across the ten rows. A production classifier must version its
finite labels, retain evidence references and confidence, and permit `unknown`.
Unknown values do not make two Episodes comparable. The pilot stores no score,
distance, rank, or global cluster ID.

## Classified sample

| # | Session shorthand | Domain | Activity | Deliverable kind |
|---:|---|---|---|---|
| 1 | Camera/lens resale survey | cross-border commerce | research | analysis |
| 2 | Guard false-positive issue | software delivery | coordinate | issue |
| 3 | Worktree/commit audit | software delivery | audit | analysis |
| 4 | Camera resale thesis | cross-border commerce | analyze | analysis |
| 5 | Social-graph status document | social graph | document | documentation |
| 6 | Guard-config issue | software delivery | coordinate | issue |
| 7 | Follower-discovery estimate | social graph | analyze | analysis |
| 8 | Books/manga price survey | cross-border commerce | research | analysis |
| 9 | Identity-merge fix | social graph | implement | code |
| 10 | Git pull/fix verification | software delivery | operate | operational state |

Repeated exact cohorts appeared without forcing every item into a group:

- `cross-border commerce / research / analysis`: 2 Episodes;
- `software delivery / coordinate / issue`: 2 Episodes.

A looser, explicit `domain + deliverable_kind` query also finds three
cross-border-commerce analyses. The identity-merge fix and Git pull/fix
verification share no semantic facet and therefore remain outside each other's
comparison cohort.

## What can be compared today

Within an explicit cohort, Flight Recorder can display model and harness as
treatments and show deterministic outcome, verification, elapsed time, cost,
retry, Meaning/Receipt evidence, and Value vectors as result columns. It must
not collapse them into one scalar.

Current Value coverage is still sparse: two authenticated Value Cards were
published from the ten Receipt-anchored Episodes. Both inferred positive goal
achievement and deliverable quality, while the other six axes remained
unknown. One Episode lacked task duration and the other had partial duration;
task cost was absent. Accepted Value generation cost totaled 135,317 micro-USD
(67,658.5 average). In the final ten-candidate pass, eight provider results
were rejected. Across both real passes, 18 failed attempt records remain: ten
from the initial pass and eight from the final pass. Rejected-response provider
cost was not persisted, so total pilot spend is unknown.

## Operational finding

Batch authentication reduced ten-candidate full-graph authentication from 11
passes to at most 2 while preserving prepared-result recovery and fail-closed
publication. A single full authentication still took more than nine minutes
and peaked near 36.7 GB on the real vault. Production-wide Atlas queries or
background taxonomy generation therefore remain disabled until authenticated
hot-path reads are bounded.

## Production sequence

1. [#49](https://github.com/shuhei0866/agents-harnesses/issues/49): seal the authenticated evidence index for bounded hot queries.
2. [#51](https://github.com/shuhei0866/agents-harnesses/issues/51): materialize deterministic structural facets and query-time cohorts.
3. [#50](https://github.com/shuhei0866/agents-harnesses/issues/50): classify current semantic anchors in bounded background batches.

The production design has two layers: a deterministic structural projection
for all authenticated Episodes and a finite semantic overlay only where a
current Meaning Card or Semantic Receipt exists. Cohorts are constructed at
query time from explicit facet matches; semantic absence remains unknown.
