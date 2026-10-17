#!/usr/bin/env bash
# Relationship edge compaction contract tests (D-20261017-35).
#
# The index persists only the relationship decisions that readers consume
# (link, component_conflict, hard_veto) and generates only the pairs that can
# receive one of them. These tests compare the optimized pipeline with a
# brute-force model of the previous behaviour: every pair inside the window or
# sharing an explicit task was scored and stored, including no_link.
# External dependencies: python3. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

# Shared helpers: events, policies, and the previous (store everything) model.
cat >"$TEST_ROOT/model.py" <<'PY'
import datetime as dt
import itertools
import random

from relationship_graph import Components, Event, score_pair, validate_policy

BASE = dt.datetime(2026, 10, 1, tzinfo=dt.timezone.utc)
FIELDS = ("explicit_task_match", "workspace_match",
          "branch_or_worktree_match", "changed_file_overlap")


def stamp(seconds):
    moment = BASE + dt.timedelta(seconds=seconds)
    text = moment.strftime("%Y-%m-%dT%H:%M:%S")
    if moment.microsecond:
        text += f".{moment.microsecond:06d}"
    return text + "Z"


def random_policy(rng, number):
    buckets, previous = [], -1
    for _ in range(rng.randint(0, 3)):
        choices = [m for m in (0, 30, 60, 300, 900, 3600, 7200) if m > previous]
        if not choices:
            break
        previous = rng.choice(choices)
        buckets.append(
            {"max_seconds": previous, "contribution": rng.choice([0, 25, 100, 300])}
        )
    return validate_policy({
        "schema_version": 1,
        "policy_version": f"prop-{number}",
        "threshold": rng.choice([0, 1, 100, 250, 400, 500, 650, 900]),
        "weights": {name: rng.choice([0, 50, 100, 150, 600]) for name in FIELDS},
        "time_buckets": buckets,
        "time_window_seconds": rng.choice([0, 60, 300, 900, 3600]),
        "hard_veto": {"contradictory_task_ids": rng.choice([True, False])},
    })


def random_events(rng, count):
    gaps = [0, 0, 1, 2, 59, 60, 61, 299, 300, 301, 899, 900, 901,
            3599, 3600, 3601, 7200, 90000]
    fractions = [0, 0, 0, 0.25, 0.5, 0.999]
    seconds = 0.0
    events = []
    for number in range(count):
        seconds += rng.choice(gaps) * rng.choice([1, 1, 0.5]) + rng.choice(fractions)
        files = tuple(sorted(rng.sample(["f1", "f2", "f3"], rng.randint(0, 2))))
        events.append(Event(
            f"e{number:03d}",
            stamp(seconds),
            rng.choice([None, "w1", "w1", "w2"]),
            rng.choice([None, None, None, "t1", "t2"]),
            rng.choice([None, "b1", "b1", "b2"]),
            files,
            rng.choice(["complete", "complete", "partial", "missing"]),
        ))
    rng.shuffle(events)
    return events


def previous_candidates(events, policy):
    """Pairs the previous generator produced: in the window or same task."""
    from chunk_rotation import parse_time
    window = policy["time_window_seconds"]
    for left, right in itertools.combinations(events, 2):
        seconds = abs(
            (parse_time(left.recorded_at) - parse_time(right.recorded_at))
            .total_seconds()
        )
        same_task = left.task_id is not None and left.task_id == right.task_id
        if seconds <= window or same_task:
            yield tuple(sorted((left.event_id, right.event_id)))


def previous_model(events, policy, new_ids=None):
    """All scored decisions of the previous behaviour, keyed by pair."""
    by_id = {event.event_id: event for event in events}
    result = {}
    for pair in previous_candidates(events, policy):
        if new_ids is not None and not new_ids.intersection(pair):
            continue
        result[pair] = score_pair(by_id[pair[0]], by_id[pair[1]], policy)
    return result


def persisted(model):
    return {pair: row for pair, row in model.items() if row[1] != "no_link"}


def components_of(events, rows):
    components = Components(events)
    conflicts = set()
    links = sorted(
        ((row[0], pair[0], pair[1])
         for pair, row in rows.items() if row[1] == "link"),
        key=lambda item: (-item[0], item[1], item[2]),
    )
    for _score, left, right in links:
        if not components.join(left, right):
            conflicts.add((left, right))
    groups = {}
    for event in events:
        groups.setdefault(components.find(event.event_id), []).append(event.event_id)
    return sorted(sorted(group) for group in groups.values()), conflicts
PY

test_generator_matches_previous_persisted_decisions() {
  echo "test_generator_matches_previous_persisted_decisions:"
  local err="$TEST_ROOT/generator.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 - <<'PY' 2>"$err"
import random

from model import (
    persisted, previous_candidates, previous_model, random_events, random_policy,
)
from chunk_rotation import parse_time
from relationship_graph import _candidate_ids, score_pair

rng = random.Random(20261017)
checked_pairs = 0
pruned = 0
vetoes = 0
beyond_window = 0
for trial in range(400):
    policy = random_policy(rng, trial)
    events = random_events(rng, rng.randint(2, 24))
    by_id = {event.event_id: event for event in events}
    previous = persisted(previous_model(events, policy))
    for new_ids in (None, {event.event_id for event in rng.sample(events, max(1, len(events) // 3))}):
        yielded = list(_candidate_ids(events, policy, new_ids))
        assert len(yielded) == len(set(yielded)), (trial, "duplicate candidate")
        assert set(yielded) <= set(previous_candidates(events, policy)), trial
        assert all(pair == tuple(sorted(pair)) for pair in yielded)
        if new_ids is not None:
            assert all(new_ids.intersection(pair) for pair in yielded), trial
        scored = {
            pair: score_pair(by_id[pair[0]], by_id[pair[1]], policy)
            for pair in yielded
        }
        expected = (
            previous if new_ids is None
            else {p: r for p, r in previous.items() if new_ids.intersection(p)}
        )
        assert persisted(scored) == expected, (trial, new_ids is None, policy)
        checked_pairs += len(expected)
        pruned += len(list(
            pair for pair in previous_model(events, policy, new_ids)
        )) - len(yielded)
        vetoes += sum(1 for row in expected.values() if row[1] == "hard_veto")
        beyond_window += sum(
            1 for pair in expected
            if abs((parse_time(by_id[pair[0]].recorded_at)
                    - parse_time(by_id[pair[1]].recorded_at)).total_seconds())
            > policy["time_window_seconds"]
        )
# The comparison must exercise the interesting decisions, not only easy links.
assert checked_pairs > 2000 and pruned > 2000, (checked_pairs, pruned)
assert vetoes > 100 and beyond_window > 500, (vetoes, beyond_window)
print("trials=400 persisted_pairs_checked=%d pruned_candidates=%d hard_veto=%d "
      "beyond_window_task_pairs=%d" % (checked_pairs, pruned, vetoes, beyond_window))
PY
  then
    pass "候補生成は旧挙動が保存していたlink/hard_veto/component_conflict対を過不足なく再現する(ランダム方針・全件/増分)"
  else
    cat "$err" >&2
    fail "候補生成は旧挙動が保存していたlink/hard_veto/component_conflict対を過不足なく再現する(ランダム方針・全件/増分)"
  fi
}

test_rebuild_matches_previous_episodes_and_links() {
  echo "test_rebuild_matches_previous_episodes_and_links:"
  local err="$TEST_ROOT/rebuild.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 - "$TEST_ROOT" <<'PY' 2>"$err"
import json
import pathlib
import random
import sqlite3
import sys

from evidence_index import configure, create_schema
from model import components_of, persisted, previous_model, random_events, random_policy
from relationship_graph import DEFAULT_POLICY, rebuild_relationships, validate_policy


def database(events, trial):
    connection = sqlite3.connect(pathlib.Path(sys.argv[1]) / f"rebuild-{trial}.sqlite")
    configure(connection)
    create_schema(connection)
    connection.execute(
        "INSERT INTO source_chunks VALUES (?,?,?,?,?,?,?,?,?)",
        ("chunk", "devices/chunk", "blob", "vault", "device",
         "2026-10-01T00:00:00Z", 2, len(events), "digest"),
    )
    for ordinal, event in enumerate(sorted(events, key=lambda e: e.event_id)):
        connection.execute(
            "INSERT INTO source_events VALUES (" + ",".join("?" * 23) + ")",
            (event.event_id, "chunk", ordinal, 2, event.recorded_at, "codex",
             "Stop", "turn.completed", None, None, event.workspace_id, None,
             None, None, None, None, None, event.task_id, None, event.branch_id,
             json.dumps(list(event.files)) if event.files else "[]",
             event.files_state, "{}"),
        )
    connection.commit()
    return connection


rng = random.Random(7)
compared = 0
conflict_rows = 0
for trial in range(60):
    policy = random_policy(rng, trial)
    events = random_events(rng, rng.randint(2, 22))
    connection = database(events, trial)
    edge_count, episode_count = rebuild_relationships(connection, policy)
    rows = persisted(previous_model(events, policy))
    groups, conflicts = components_of(events, rows)

    stored = {
        (left, right): (score, decision)
        for left, right, score, decision in connection.execute(
            "SELECT left_event_id,right_event_id,score,decision "
            "FROM relationship_edges WHERE policy_version=?",
            (policy["policy_version"],),
        )
    }
    expected = {
        pair: (row[0], "component_conflict" if pair in conflicts else row[1])
        for pair, row in rows.items()
    }
    assert stored == expected, (trial, policy)
    assert edge_count == len(expected), (trial, edge_count, len(expected))
    assert "no_link" not in {decision for _score, decision in stored.values()}
    members = {}
    for episode_id, event_id in connection.execute(
        "SELECT episode_id,event_id FROM episode_members WHERE policy_version=?",
        (policy["policy_version"],),
    ):
        members.setdefault(episode_id, []).append(event_id)
    assert sorted(sorted(group) for group in members.values()) == groups, trial
    assert episode_count == len(groups)
    assert connection.execute("PRAGMA foreign_key_check").fetchall() == []
    # Evidence is only kept for the edges that exist.
    orphans = connection.execute(
        "SELECT COUNT(*) FROM relationship_evidence AS ev WHERE NOT EXISTS ("
        "SELECT 1 FROM relationship_edges AS re WHERE re.policy_version=ev.policy_version "
        "AND re.evidence_id=ev.evidence_id)"
    ).fetchone()[0]
    assert orphans == 0, (trial, orphans)
    compared += len(expected)
    conflict_rows += len(conflicts)
    assert {
        pair for pair, (_score, decision) in stored.items()
        if decision == "component_conflict"
    } == conflicts, trial
    connection.close()
assert compared > 200 and conflict_rows > 20, (compared, conflict_rows)
print("trials=60 stored_edges_compared=%d component_conflicts=%d" % (compared, conflict_rows))
PY
  then
    pass "full rebuildのepisodeと保存edgeが旧挙動(総当たり)と一致し、no_linkと孤立evidenceを持たない"
  else
    cat "$err" >&2
    fail "full rebuildのepisodeと保存edgeが旧挙動(総当たり)と一致し、no_linkと孤立evidenceを持たない"
  fi
}

test_incremental_refresh_continues_an_index_that_still_stores_no_link() {
  echo "test_incremental_refresh_continues_an_index_that_still_stores_no_link:"
  local err="$TEST_ROOT/legacy.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 - "$TEST_ROOT" <<'PY' 2>"$err"
import json
import pathlib
import random
import sqlite3
import sys

from evidence_index import configure, create_schema, validate_database
from model import components_of, persisted, previous_model, random_events, random_policy
from relationship_graph import (
    _evidence_id, rebuild_relationships, refresh_relationships_incremental,
)


def insert(connection, events, start):
    for ordinal, event in enumerate(events, start):
        connection.execute(
            "INSERT INTO source_events VALUES (" + ",".join("?" * 23) + ")",
            (event.event_id, "chunk", ordinal, 2, event.recorded_at, "codex",
             "Stop", "turn.completed", None, None, event.workspace_id, None,
             None, None, None, None, None, event.task_id, None, event.branch_id,
             json.dumps(list(event.files)) if event.files else "[]",
             event.files_state, "{}"),
        )


rng = random.Random(99)
legacy_rows_kept = 0
for trial in range(40):
    policy = random_policy(rng, trial)
    events = random_events(rng, rng.randint(6, 24))
    cut = rng.randint(2, len(events) - 2)
    old_events, new_events = events[:cut], events[cut:]
    connection = sqlite3.connect(pathlib.Path(sys.argv[1]) / f"legacy-{trial}.sqlite")
    configure(connection)
    create_schema(connection)
    connection.execute(
        "INSERT INTO source_chunks VALUES (?,?,?,?,?,?,?,?,?)",
        ("chunk", "devices/chunk", "blob", "vault", "device",
         "2026-10-01T00:00:00Z", 2, len(events), "digest"),
    )
    insert(connection, old_events, 0)
    connection.commit()
    # Build the index the way the previous release did: every candidate pair
    # is stored, including no_link, and the evidence dictionary covers them.
    rebuild_relationships(connection, policy)
    old_model = previous_model(old_events, policy)
    legacy = {p: r for p, r in old_model.items() if r[1] == "no_link"}
    for pair, (score, decision, evidence) in legacy.items():
        evidence_id = _evidence_id(evidence)
        connection.execute(
            "INSERT OR IGNORE INTO relationship_evidence VALUES (?,?,?)",
            (policy["policy_version"], evidence_id, evidence),
        )
        connection.execute(
            "INSERT INTO relationship_edges VALUES (?,?,?,?,?,?)",
            (policy["policy_version"], pair[0], pair[1], score, decision, evidence_id),
        )
    connection.commit()
    legacy_total = connection.execute(
        "SELECT COUNT(*) FROM relationship_edges WHERE decision='no_link'"
    ).fetchone()[0]
    assert legacy_total == len(legacy)

    insert(connection, new_events, len(old_events))
    connection.commit()
    refresh_relationships_incremental(
        connection, policy, {event.event_id for event in new_events}
    )
    connection.commit()
    validate_database(connection)

    rows = persisted(previous_model(events, policy))
    groups, conflicts = components_of(events, rows)
    stored = {
        (left, right): (score, decision)
        for left, right, score, decision in connection.execute(
            "SELECT left_event_id,right_event_id,score,decision "
            "FROM relationship_edges WHERE policy_version=? AND decision<>'no_link'",
            (policy["policy_version"],),
        )
    }
    expected = {
        pair: (row[0], "component_conflict" if pair in conflicts else row[1])
        for pair, row in rows.items()
    }
    assert stored == expected, (trial, policy)
    # Legacy rows are left untouched and nothing new is added to them.
    assert connection.execute(
        "SELECT COUNT(*) FROM relationship_edges WHERE decision='no_link'"
    ).fetchone()[0] == legacy_total
    legacy_rows_kept += legacy_total
    members = {}
    for episode_id, event_id in connection.execute(
        "SELECT episode_id,event_id FROM episode_members WHERE policy_version=?",
        (policy["policy_version"],),
    ):
        members.setdefault(episode_id, []).append(event_id)
    assert sorted(sorted(group) for group in members.values()) == groups, trial
    connection.close()
assert legacy_rows_kept > 100, legacy_rows_kept
print("trials=40 legacy_no_link_rows_preserved=%d" % legacy_rows_kept)
PY
  then
    pass "no_linkを全件持つ旧形式のindexへ新コードの増分refreshを当てても、旧行を保ったまま同じepisodeとlinkに到達する"
  else
    cat "$err" >&2
    fail "no_linkを全件持つ旧形式のindexへ新コードの増分refreshを当てても、旧行を保ったまま同じepisodeとlinkに到達する"
  fi
}

test_dense_unrelated_work_no_longer_grows_edges() {
  echo "test_dense_unrelated_work_no_longer_grows_edges:"
  local err="$TEST_ROOT/dense.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 - <<'PY' 2>"$err"
import itertools

from model import persisted, previous_model, stamp
from relationship_graph import (
    DEFAULT_POLICY, Event, _candidate_ids, score_pair, validate_policy,
)

policy = validate_policy(DEFAULT_POLICY)
# 60 parallel sessions touch one hour of work in their own branches, plus a
# short burst of related work in a single branch. The previous behaviour stored
# a row for every pair in the hour; the new behaviour stores only related pairs.
events = []
for number in range(240):
    events.append(Event(
        f"p{number:03d}", stamp(number * 14.0), "w1", None,
        f"branch-{number % 60}", ("f1",), "complete",
    ))
for number in range(12):
    events.append(Event(
        f"r{number:03d}", stamp(2000 + number * 20.0), "w1", None,
        "shared", ("f9", "f1"), "complete",
    ))
previous = previous_model(events, policy)
kept = persisted(previous)
candidates = list(_candidate_ids(events, policy))
by_id = {event.event_id: event for event in events}
scored = {
    pair: score_pair(by_id[pair[0]], by_id[pair[1]], policy) for pair in candidates
}
assert persisted(scored) == kept
# Only the burst of related work links (every pair of its 12 events). The
# parallel sessions are 14 seconds apart but 840 seconds from the next event in
# their own branch, so none of their pairs can link.
assert set(kept) == {
    tuple(sorted(pair))
    for pair in itertools.combinations([f"r{n:03d}" for n in range(12)], 2)
}, sorted(kept)[:3]
assert len(kept) == 66 and len(kept) < len(previous) * 0.01, (len(kept), len(previous))
assert len(candidates) < len(previous) // 10, (len(candidates), len(previous))
print("previous_rows=%d persisted_rows=%d candidates_scored=%d" % (
    len(previous), len(kept), len(candidates)))
PY
  then
    pass "並走セッションの無関係なpairはedgeとして保存されず、採点対象も1/10未満になる"
  else
    cat "$err" >&2
    fail "並走セッションの無関係なpairはedgeとして保存されず、採点対象も1/10未満になる"
  fi
}

test_link_plan_follows_the_policy() {
  echo "test_link_plan_follows_the_policy:"
  local err="$TEST_ROOT/plan.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 - <<'PY' 2>"$err"
import copy

from relationship_graph import DEFAULT_POLICY, LinkPlan, link_plan, validate_policy

default = link_plan(validate_policy(DEFAULT_POLICY))
# Without a shared task the best score is workspace+branch+files (400) plus the
# 5-minute bucket (100) = 500, so only those pairs can link.
assert default == LinkPlan(300, True, True, True), default

def variant(**changes):
    policy = copy.deepcopy(DEFAULT_POLICY)
    policy["policy_version"] = "plan-test"
    for key, value in changes.items():
        if key == "weights":
            policy["weights"].update(value)
        else:
            policy[key] = value
    return validate_policy(policy)

# Every pair links: nothing may be pruned.
assert link_plan(variant(threshold=0)) == LinkPlan(3600, False, False, False)
# The workspace is optional once branch+files+time reach the threshold alone.
relaxed = link_plan(variant(weights={"workspace_match": 0}, threshold=400))
assert relaxed.horizon == 300 and not relaxed.block_workspace, relaxed
# A longer bucket extends the horizon; buckets beyond the window are clipped.
wide = link_plan(variant(time_buckets=[{"max_seconds": 900, "contribution": 100}]))
assert wide.horizon == 900, wide
clipped = link_plan(variant(
    time_buckets=[{"max_seconds": 7200, "contribution": 100}],
    time_window_seconds=600,
))
assert clipped.horizon == 600, clipped
# No combination can reach the threshold: only explicit tasks can link.
assert link_plan(variant(threshold=10_000)) == LinkPlan(None, False, False, False)
PY
  then
    pass "link_planは方針の重み・時間bucket・windowから必要条件を導く"
  else
    cat "$err" >&2
    fail "link_planは方針の重み・時間bucket・windowから必要条件を導く"
  fi
}

test_generator_matches_previous_persisted_decisions
test_rebuild_matches_previous_episodes_and_links
test_incremental_refresh_continues_an_index_that_still_stores_no_link
test_dense_unrelated_work_no_longer_grows_edges
test_link_plan_follows_the_policy

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
