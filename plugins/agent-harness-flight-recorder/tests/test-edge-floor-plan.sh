#!/usr/bin/env bash
# Episode selection at the scale of a real index.
#
# Selection read an Episode's weakest link score with one join between
# episode_members and relationship_edges. Without sqlite_stat1, SQLite plans that
# join from relationship_edges, so every Episode walked every link edge in the
# index: instant on a fixture of a few hundred edges, hours on a few million.
# These tests build indexes with a realistic number of rows and pin the query
# plans, that an Episode's cost follows the Episode and not the index, and that a
# selection that finds nothing still ends.
# External dependencies: python3 only. Network access is not required.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_ROOT="$(mktemp -d)" || exit 1
[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] || {
  echo "failed to create temporary directory" >&2
  exit 1
}
PASS=0
FAIL=0

cleanup() {
  [[ -n "$TEST_ROOT" && "$TEST_ROOT" != "/" && -d "$TEST_ROOT" ]] || return
  [[ "${TEST_ROOT##*/}" == tmp.* ]] || return
  rm -rf -- "$TEST_ROOT"
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

# Builds an Evidence Index with the row counts and shapes of a real one, without
# running the pipeline: only the schema and the query planner matter here.
#   - `groups` Episodes of 200 events whose every pair is linked, except one pair
#     per group that is a component_conflict with a score below every link;
#   - one chain Episode of 1,100 events linked only to their neighbours, whose
#     weakest link sits in its third batch of 500 members;
#   - `singles` unrelated events, newest of all. Every 997th of the older ones
#     carries a passing test, so a few single-event Episodes can be candidates.
# Events are numbered in time order, so the groups are the oldest.
cat >"$TEST_ROOT/scale.py" <<'PY'
import datetime as dt
import sqlite3

import evidence_index

VERSION = "default-v1"
BASE = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
GROUP_SIZE = 200
CHAIN_SIZE = 1100
CHAIN_WEAKEST = 650
CONFLICT_SCORE = 1


def event_id(number):
    return f"event-{number:08d}"


def stamp(number):
    moment = BASE + dt.timedelta(seconds=number)
    return moment.isoformat().replace("+00:00", "Z")


def pair_score(left, right):
    # 501..800: every group has a link below the 700 uncertainty threshold.
    return 800 - ((left * 31 + right * 17) % 300)


def build(path, *, groups, singles):
    connection = sqlite3.connect(path)
    connection.execute("PRAGMA foreign_keys = OFF")
    connection.execute("PRAGMA journal_mode = OFF")
    connection.execute("PRAGMA synchronous = OFF")
    connection.executescript(evidence_index.SCHEMA)
    chain_start = groups * GROUP_SIZE
    singles_start = chain_start + CHAIN_SIZE
    total = singles_start + singles
    connection.execute(
        "INSERT INTO source_chunks VALUES "
        "('chunk-1','p','b','v','d','2026-01-01T00:00:00Z',3,?,'h')",
        (total,),
    )
    connection.executemany(
        "INSERT INTO source_events (event_id, chunk_id, ordinal, "
        "schema_version, recorded_at, harness, source_event, event_kind, "
        "canonical_event_json) VALUES (?,'chunk-1',?,3,?,'codex','Stop',"
        "'turn.completed','{}')",
        ((event_id(n), n, stamp(n)) for n in range(total)),
    )
    episodes = []
    members = []

    def episode(first, count):
        name = f"episode-{len(episodes):06d}"
        episodes.append((VERSION, name, count))
        members.extend(
            (VERSION, name, event_id(first + k), k) for k in range(count)
        )

    for group in range(groups):
        episode(group * GROUP_SIZE, GROUP_SIZE)
    episode(chain_start, CHAIN_SIZE)
    for number in range(singles_start, total):
        episode(number, 1)
    connection.executemany("INSERT INTO episodes VALUES (?,?,?)", episodes)
    connection.executemany(
        "INSERT INTO episode_members VALUES (?,?,?,?)", members
    )
    connection.execute(
        "INSERT INTO relationship_policies VALUES (?,1,'x','{}')", (VERSION,)
    )
    connection.execute(
        "INSERT INTO relationship_evidence VALUES (?,'e','{}')", (VERSION,)
    )

    def group_edges():
        for group in range(groups):
            first = group * GROUP_SIZE
            last = first + GROUP_SIZE - 1
            for left in range(first, last + 1):
                for right in range(left + 1, last + 1):
                    if (left, right) == (first, last):
                        yield (VERSION, event_id(left), event_id(right),
                               CONFLICT_SCORE, "component_conflict", "e")
                    else:
                        yield (VERSION, event_id(left), event_id(right),
                               pair_score(left, right), "link", "e")
        weakest = chain_start + 1050
        for left in range(chain_start, chain_start + CHAIN_SIZE - 1):
            yield (VERSION, event_id(left), event_id(left + 1),
                   CHAIN_WEAKEST if left == weakest else 900, "link", "e")

    connection.executemany(
        "INSERT INTO relationship_edges VALUES (?,?,?,?,?,?)", group_edges()
    )
    bearing = range(singles_start, total - 2000, 997)
    connection.executemany(
        "INSERT INTO deterministic_evidence VALUES (?,?,?,?,?,?,NULL)",
        (
            (f"evidence-{n:08d}", event_id(n), "deterministic-v1",
             stamp(n), "test", "success")
            for n in bearing
        ),
    )
    connection.commit()
    connection.close()


def normalized(plan):
    return [
        line.replace("SCAN TABLE ", "SCAN ").replace("SEARCH TABLE ", "SEARCH ")
        for line in plan
    ]
PY

cat >"$TEST_ROOT/build.py" <<'PY'
import sys

import scale

scale.build(sys.argv[1], groups=12, singles=30000)
scale.build(sys.argv[2], groups=3, singles=6000)
PY

setup_fixtures() {
  PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 "$TEST_ROOT/build.py" \
    "$TEST_ROOT/large.sqlite" "$TEST_ROOT/small.sqlite" \
    2>"$TEST_ROOT/build.err" || {
    cat "$TEST_ROOT/build.err" >&2
    return 1
  }
}

# The statements run by `action`, each with the plan SQLite chooses for it.
cat >"$TEST_ROOT/plans.py" <<'PY'
import sqlite3

from scale import normalized


def statements_of(connection, action):
    seen = []
    connection.set_trace_callback(seen.append)
    try:
        action()
    finally:
        connection.set_trace_callback(None)
    return [
        (sql, normalized(row[3] for row in connection.execute("EXPLAIN QUERY PLAN " + sql)))
        for sql in seen
        if sql.lstrip().upper().startswith("SELECT")
    ]


def vm_steps(connection, action, interval=25):
    count = [0]

    def tick():
        count[0] += interval
        return 0

    connection.set_progress_handler(tick, interval)
    try:
        action()
    finally:
        connection.set_progress_handler(None, 0)
    return count[0]


def episode_of_size(connection, size):
    return connection.execute(
        "SELECT episode_id FROM episodes WHERE member_count = ? ORDER BY episode_id LIMIT 1",
        (size,),
    ).fetchone()[0]


def newest_episode(connection):
    return connection.execute(
        "SELECT m.episode_id FROM source_events AS e "
        "JOIN episode_members AS m ON m.event_id = e.event_id "
        "ORDER BY e.recorded_at DESC LIMIT 1"
    ).fetchone()[0]


# What selection ran before: one join that SQLite plans from the edge table.
PREVIOUS_FLOOR = (
    "SELECT MIN(edge.score) FROM episode_members AS member "
    "JOIN relationship_edges AS edge "
    "ON edge.policy_version = member.policy_version "
    "AND edge.left_event_id = member.event_id "
    "WHERE member.policy_version = ? AND member.episode_id = ? "
    "AND edge.decision = 'link'"
)
PY

test_floor_plan_starts_from_the_members() {
  echo "test_floor_plan_starts_from_the_members:"
  local err="$TEST_ROOT/plan.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 - "$TEST_ROOT/large.sqlite" <<'PY' 2>"$err"
import sqlite3
import sys

import reporting
from plans import PREVIOUS_FLOOR, episode_of_size, newest_episode, statements_of
from scale import CHAIN_SIZE, GROUP_SIZE, VERSION, normalized

connection = sqlite3.connect(sys.argv[1])
# The planner must decide with its defaults, as on an index that was never analyzed.
assert connection.execute(
    "SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'sqlite_stat%'"
).fetchone()[0] == 0
links = connection.execute(
    "SELECT COUNT(*) FROM relationship_edges WHERE decision = 'link'"
).fetchone()[0]
members = connection.execute("SELECT COUNT(*) FROM episode_members").fetchone()[0]
assert links >= 200_000 and members >= 30_000, (links, members)

MEMBERS = ["SEARCH episode_members USING PRIMARY KEY (policy_version=? AND episode_id=?)"]
EDGES = ["SEARCH relationship_edges USING PRIMARY KEY (policy_version=? AND left_event_id=?)"]

group = episode_of_size(connection, GROUP_SIZE)
chain = episode_of_size(connection, CHAIN_SIZE)
single = newest_episode(connection)
for episode, edge_statements in ((group, 1), (chain, 3), (single, 0)):
    statements = statements_of(
        connection,
        lambda: reporting._episode_edge_floor(connection, VERSION, episode),
    )
    assert len(statements) == 1 + edge_statements, (episode, len(statements))
    # The first step is the Episode's own member rows, found by primary key...
    assert statements[0][1] == MEMBERS, statements[0]
    # ...and every edge lookup is a primary-key seek per member, never a scan.
    for _sql, plan in statements[1:]:
        assert plan == EDGES, plan

# Control: the previous statement starts from the edge table and scans it.
previous = [
    row[3] for row in connection.execute(
        "EXPLAIN QUERY PLAN " + PREVIOUS_FLOOR, (VERSION, group)
    )
]
reproduced = normalized(previous)[0].startswith("SEARCH edge USING PRIMARY KEY (policy_version=?)")
print("control: previous statement plans from the edge table: %s" % reproduced)
PY
  then
    pass "辺の下限は先に所属イベントを主キーで引き、辺は主キー前置の探索だけで読む(統計なし・25万辺規模)"
  else
    cat "$err" >&2
    fail "辺の下限は先に所属イベントを主キーで引き、辺は主キー前置の探索だけで読む(統計なし・25万辺規模)"
  fi
}

test_floor_cost_follows_the_episode_not_the_index() {
  echo "test_floor_cost_follows_the_episode_not_the_index:"
  local err="$TEST_ROOT/cost.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 - "$TEST_ROOT/large.sqlite" "$TEST_ROOT/small.sqlite" <<'PY' 2>"$err"
import sqlite3
import sys

import reporting
from plans import PREVIOUS_FLOOR, episode_of_size, newest_episode, vm_steps
from scale import CHAIN_SIZE, GROUP_SIZE, VERSION

large = sqlite3.connect(sys.argv[1])
small = sqlite3.connect(sys.argv[2])
edges = {
    name: connection.execute("SELECT COUNT(*) FROM relationship_edges").fetchone()[0]
    for name, connection in (("large", large), ("small", small))
}
assert edges["large"] >= 3 * edges["small"], edges


def floor_steps(connection, size):
    episode = (
        newest_episode(connection) if size == 1 else episode_of_size(connection, size)
    )
    return vm_steps(
        connection,
        lambda: reporting._episode_edge_floor(connection, VERSION, episode),
    )


for size in (1, GROUP_SIZE, CHAIN_SIZE):
    in_small, in_large = floor_steps(small, size), floor_steps(large, size)
    # The same Episode costs the same in an index four times larger.
    assert in_large <= in_small * 1.1 + 200, (size, in_small, in_large)
# And the cost is the Episode's own: its edges, never the index's.
assert floor_steps(large, GROUP_SIZE) < 40 * (GROUP_SIZE * (GROUP_SIZE - 1) // 2), "too much work"
assert floor_steps(large, 1) < 400

# Control: the previous statement scales with the index.
def previous_steps(connection):
    episode = episode_of_size(connection, GROUP_SIZE)
    return vm_steps(connection, lambda: connection.execute(PREVIOUS_FLOOR, (VERSION, episode)).fetchone())

before = (previous_steps(small), previous_steps(large))
print("control: previous statement, VM steps small=%d large=%d (x%.1f)" % (*before, before[1] / before[0]))
PY
  then
    pass "Episode一つの下限を読む仕事量は、indexが4倍になっても変わらない(Episodeの辺の数に比例)"
  else
    cat "$err" >&2
    fail "Episode一つの下限を読む仕事量は、indexが4倍になっても変わらない(Episodeの辺の数に比例)"
  fi
}

test_floor_is_the_exact_minimum_over_link_edges() {
  echo "test_floor_is_the_exact_minimum_over_link_edges:"
  local err="$TEST_ROOT/exact.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 - "$TEST_ROOT/large.sqlite" "$TEST_ROOT/small.sqlite" <<'PY' 2>"$err"
import sqlite3
import sys

import reporting
from plans import PREVIOUS_FLOOR, episode_of_size, newest_episode
from scale import (
    CHAIN_SIZE, CHAIN_WEAKEST, CONFLICT_SCORE, GROUP_SIZE, VERSION, pair_score,
)

large = sqlite3.connect(sys.argv[1])
small = sqlite3.connect(sys.argv[2])


def floor(connection, episode):
    return reporting._episode_edge_floor(connection, VERSION, episode)


group_links = [
    pair_score(left, right)
    for left in range(GROUP_SIZE)
    for right in range(left + 1, GROUP_SIZE)
    if (left, right) != (0, GROUP_SIZE - 1)
]
# The conflict is the weakest edge of the group but is not a link: it is ignored.
assert CONFLICT_SCORE < min(group_links)
group = episode_of_size(large, GROUP_SIZE)
assert floor(large, group) == {group: [{"score": min(group_links)}]}
# The chain's weakest link lies in the third batch of 500 members.
chain = episode_of_size(large, CHAIN_SIZE)
assert floor(large, chain) == {chain: [{"score": CHAIN_WEAKEST}]}
# A single event has no link edge to speak of, and an unknown Episode no member.
assert floor(large, newest_episode(large)) == {}
assert floor(large, "episode-missing") == {}

# The statement that selection used to run says the same, where it is affordable.
for episode in (episode_of_size(small, GROUP_SIZE), episode_of_size(small, CHAIN_SIZE)):
    previous = small.execute(PREVIOUS_FLOOR, (VERSION, episode)).fetchone()[0]
    assert floor(small, episode) == {episode: [{"score": previous}]}, episode
PY
  then
    pass "下限はlink辺だけの最小スコアで、500件ずつの束をまたいでも・単独や未知のEpisodeでも従来と同じ"
  else
    cat "$err" >&2
    fail "下限はlink辺だけの最小スコアで、500件ずつの束をまたいでも・単独や未知のEpisodeでも従来と同じ"
  fi
}

test_walk_plan_needs_no_scan_of_edges_or_sort() {
  echo "test_walk_plan_needs_no_scan_of_edges_or_sort:"
  local err="$TEST_ROOT/walk.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 - "$TEST_ROOT/large.sqlite" <<'PY' 2>"$err"
import datetime as dt
import pathlib
import re
import sqlite3
import sys

import background_evaluation
import reporting
from plans import statements_of
from relationship_graph import DEFAULT_POLICY, validate_policy

connection = sqlite3.connect(sys.argv[1])
policy = validate_policy(DEFAULT_POLICY)
utc = dt.timezone.utc


def walk_plan(episode_filter):
    def action():
        reporting._select_newest_first(
            pathlib.Path("."), connection, policy,
            forgotten=set(),
            start=dt.datetime(2000, 1, 1, tzinfo=utc),
            end=dt.datetime(2100, 1, 1, tzinfo=utc),
            accept=lambda card: False, limit=1,
            max_visits=1, max_seconds=60, stats=reporting.SelectionStats(),
            stored_evaluations=[], episode_filter=episode_filter,
        )

    walks = [
        plan for sql, plan in statements_of(connection, action)
        if sql.lstrip().startswith("SELECT e.event_id, e.recorded_at, m.episode_id")
    ]
    assert len(walks) == 1, walks
    return walks[0]


for label, episode_filter in (
    ("no filter", None),
    ("candidate filter", background_evaluation._candidate_filter()),
):
    plan = walk_plan(episode_filter)
    # Events come newest first straight from the time index, then each event's
    # Episode is one seek away; nothing is sorted and no table is scanned again.
    assert plan[0] == "SCAN e USING COVERING INDEX source_events_by_time", (label, plan)
    assert re.fullmatch(
        r"SEARCH m USING (COVERING )?INDEX sqlite_autoindex_episode_members_\d+ "
        r"\(policy_version=\? AND event_id=\?\)", plan[1]), (label, plan)
    assert plan[2] == "SEARCH ep USING PRIMARY KEY (policy_version=? AND episode_id=?)", (label, plan)
    assert not any("TEMP B-TREE" in line for line in plan), (label, plan)
    scans = [line for line in plan if line.startswith("SCAN")]
    assert scans == plan[:1], (label, plan)
    if episode_filter is not None:
        assert any(
            line.startswith("SEARCH d USING") and "deterministic_evidence_by_source" in line
            for line in plan
        ), plan
PY
  then
    pass "選別の走査は時刻indexを新しい順に1回なぞるだけで、並べ替えも他表の全走査も出ない"
  else
    cat "$err" >&2
    fail "選別の走査は時刻indexを新しい順に1回なぞるだけで、並べ替えも他表の全走査も出ない"
  fi
}

test_selection_without_candidates_ends() {
  echo "test_selection_without_candidates_ends:"
  local err="$TEST_ROOT/ends.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 - "$TEST_ROOT/large.sqlite" <<'PY' 2>"$err"
import datetime as dt
import itertools
import pathlib
import sqlite3
import sys

import background_evaluation
import reporting

connection = sqlite3.connect(sys.argv[1])
from relationship_graph import DEFAULT_POLICY, validate_policy

policy = validate_policy(DEFAULT_POLICY)
utc = dt.timezone.utc
total_events = connection.execute("SELECT COUNT(*) FROM source_events").fetchone()[0]


def select(*, accept=lambda card: False, visits=1000, seconds=20.0,
           episode_filter=None, clock=None):
    stats = reporting.SelectionStats()
    kwargs = {} if clock is None else {"clock": clock}
    found = reporting._select_newest_first(
        pathlib.Path("."), connection, policy,
        forgotten=set(),
        start=dt.datetime(2000, 1, 1, tzinfo=utc),
        end=dt.datetime(2100, 1, 1, tzinfo=utc),
        accept=accept, limit=10, max_visits=visits, max_seconds=seconds,
        stats=stats, stored_evaluations=[], episode_filter=episode_filter,
        **kwargs,
    )
    return found, stats


# 1. Thirty thousand Episodes and nothing to take: the visit bound ends the walk.
found, stats = select()
assert (found, stats.visited, stats.stopped) == ([], 1000, "visit_limit"), (found, stats)
found, stats = select(visits=50)
assert (found, stats.visited, stats.stopped) == ([], 50, "visit_limit"), (found, stats)

# 2. The time bound, read by the walk between two Episodes. The clock advances
#    one second per reading, so five seconds are over after a handful of Episodes.
ticks = itertools.count()
found, stats = select(seconds=5, clock=lambda: next(ticks))
assert found == [] and stats.stopped == "time_limit" and stats.visited < 10, stats

# 3. A statement that produces no row for a long time never reaches the walk's
#    own clock check, so SQLite is told to give up on it. This filter excludes
#    every Episode (a member count is never negative, which SQLite cannot know
#    in advance): the scan would go through every event and return nothing.
original = reporting.SELECTION_PROGRESS_STEPS
reporting.SELECTION_PROGRESS_STEPS = 100
try:
    ticks = itertools.count()
    found, stats = select(
        seconds=5, clock=lambda: next(ticks),
        episode_filter=reporting.EpisodeFilter("ep.member_count < 0"),
    )
    assert found == [] and stats.visited == 0 and stats.stopped == "time_limit", stats
    # The interrupted scan did not run its course: far fewer than one reading per
    # event was needed to reach the deadline.
    assert next(ticks) < total_events // 20
finally:
    reporting.SELECTION_PROGRESS_STEPS = original
# The deadline does not outlive the selection: the connection is usable again.
assert connection.execute("SELECT COUNT(*) FROM source_events").fetchone()[0] == total_events

# 4. Only our own deadline ends a selection quietly.
real_card = reporting._episode_card
try:
    for message, seconds in (("disk I/O error", 20.0), ("interrupted", 20.0)):
        def broken(*_args, **_kwargs):
            raise sqlite3.OperationalError(message)

        reporting._episode_card = broken
        try:
            select(seconds=seconds)
        except sqlite3.OperationalError as error:
            assert str(error) == message
        else:
            raise AssertionError("a database error must not be treated as the deadline: " + message)
finally:
    reporting._episode_card = real_card

# 5. A selection that finds what it wants is not reported as cut short. The
#    filter lets through the Episodes that might be candidates: the single events
#    that carry a passing test, which are newer than every group and the chain.
bearing = connection.execute("SELECT COUNT(*) FROM deterministic_evidence").fetchone()[0]
found, stats = select(
    accept=lambda card: card["event_count"] > 1,
    episode_filter=background_evaluation._candidate_filter(),
)
assert len(found) == 10 and stats.stopped is None, (found, stats)
assert stats.visited == bearing + 10, (stats.visited, bearing)
PY
  then
    pass "候補がなくても選別は終わる: 訪問数・時間の上限、SQLite内の期限、他のDBエラーは握りつぶさない"
  else
    cat "$err" >&2
    fail "候補がなくても選別は終わる: 訪問数・時間の上限、SQLite内の期限、他のDBエラーは握りつぶさない"
  fi
}

test_candidate_filter_reaches_candidates_behind_the_cap() {
  echo "test_candidate_filter_reaches_candidates_behind_the_cap:"
  local err="$TEST_ROOT/filter.err"
  if PYTHONPATH="$PLUGIN_DIR/scripts:$TEST_ROOT" python3 - "$TEST_ROOT/large.sqlite" <<'PY' 2>"$err"
import datetime as dt
import pathlib
import sqlite3
import sys

import background_evaluation
import reporting
from relationship_graph import DEFAULT_POLICY, validate_policy

connection = sqlite3.connect(sys.argv[1])
policy = validate_policy(DEFAULT_POLICY)
utc = dt.timezone.utc
config = {"uncertainty_score_below": 700}
accept = lambda card: background_evaluation._is_candidate(config, card)


def select(*, limit, visits, seconds=3600, episode_filter=None):
    stats = reporting.SelectionStats()
    found = reporting._select_newest_first(
        pathlib.Path("."), connection, policy,
        forgotten=set(),
        start=dt.datetime(2000, 1, 1, tzinfo=utc),
        end=dt.datetime(2100, 1, 1, tzinfo=utc),
        accept=accept, limit=limit, max_visits=visits, max_seconds=seconds,
        stats=stats, stored_evaluations=[], episode_filter=episode_filter,
    )
    return found, stats


everyone = background_evaluation._candidate_filter()
# Every candidate lies behind thousands of newer single-event Episodes. With the
# visit bound alone the run gives up before the first one...
found, stats = select(limit=10, visits=1000)
assert found == [] and stats.stopped == "visit_limit", (found, stats)
# ...so the bound is only usable when Episodes that cannot be candidates are not
# counted: the filter finds them in the same statement that walks the events.
found, stats = select(limit=10, visits=1000, episode_filter=everyone)
assert len(found) == 10 and stats.visited == 10 and stats.stopped is None, (found, stats)

# The filter only skips work: it never drops an Episode that would be accepted.
exhaustive, every_card = select(limit=10**6, visits=10**9)
filtered, plausible = select(limit=10**6, visits=10**9, episode_filter=everyone)
assert filtered == exhaustive and len(exhaustive) > 30, (len(filtered), len(exhaustive))
assert plausible.visited < every_card.visited // 100, (plausible.visited, every_card.visited)
assert found == exhaustive[:10]
PY
  then
    pass "候補になりえないEpisodeを走査の中で除くと、上限の奥にいる候補にも届き、受理されるEpisodeは一つも落ちない"
  else
    cat "$err" >&2
    fail "候補になりえないEpisodeを走査の中で除くと、上限の奥にいる候補にも届き、受理されるEpisodeは一つも落ちない"
  fi
}

echo "=== Flight Recorder Edge Floor Plan Tests (real-index cardinality) ==="
if ! setup_fixtures; then
  echo "fixture setup failed" >&2
  exit 1
fi
test_floor_plan_starts_from_the_members
test_floor_cost_follows_the_episode_not_the_index
test_floor_is_the_exact_minimum_over_link_edges
test_walk_plan_needs_no_scan_of_edges_or_sort
test_selection_without_candidates_ends
test_candidate_filter_reaches_candidates_behind_the_cap

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
