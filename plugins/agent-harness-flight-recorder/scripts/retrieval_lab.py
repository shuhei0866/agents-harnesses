#!/usr/bin/env python3
"""Local retrieval measurement. No provider calls, vault writes, or self-adoption."""
from __future__ import annotations

import argparse
from collections import Counter
from contextlib import contextmanager
import hashlib
import fcntl
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import sys
import time
import uuid

VERSION = "lexical-bigram-v1"
ARMS = ("baseline", "recorder")
MAX_SNAPSHOT_BYTES = 64 * 1024 * 1024
MAX_DOCUMENTS = 20000
MAX_TEXT = 100000
MAX_QUERY = 2000
MAX_SHADOWS_PER_DAY = 100


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def bounded_int(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise ValueError("integer outside supported range")
    return value


def safe_file(path, maximum):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    fd = os.open(path, flags)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise ValueError("input is not a bounded regular file")
        data = stream.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("input exceeds size bound")
    return data


def _root(root):
    root = Path(root).absolute()
    if root.is_symlink():
        raise ValueError("lab path must not be a symlink")
    root = root.resolve()
    info = root.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError("lab must be an owner-only directory")
    return root


def _snapshot(root, snapshot_id=None):
    root = _root(root)
    if snapshot_id is not None and (not isinstance(snapshot_id, str) or not re.fullmatch(r"[0-9a-f]{64}", snapshot_id)):
        raise ValueError("invalid snapshot identifier")
    path = root / "snapshot.json"
    if snapshot_id is not None:
        directory = root / "snapshots"
        if directory.is_symlink():
            raise ValueError("unsafe snapshot directory")
        historical = directory / (snapshot_id + ".json")
        if historical.exists() or historical.is_symlink():
            path = historical
    value = json.loads(safe_file(path, MAX_SNAPSHOT_BYTES))
    # A legacy reader can race the first publication between checking the archive
    # and opening current. Publication archives the old generation before switching.
    if snapshot_id is not None and value.get("snapshot_id") != snapshot_id and path.name == "snapshot.json":
        value = json.loads(safe_file(root / "snapshots" / (snapshot_id + ".json"), MAX_SNAPSHOT_BYTES))
    if value.get("schema_version") != 1 or value.get("snapshot_id") != digest(value.get("documents")):
        raise ValueError("snapshot identity mismatch")
    if snapshot_id is not None and value["snapshot_id"] != snapshot_id:
        raise ValueError("historical snapshot unavailable")
    return value


@contextmanager
def _connect(root):
    root = _root(root)
    path = root / "measurements.sqlite"
    if path.is_symlink() or not path.is_file():
        raise ValueError("measurement database unavailable")
    db = sqlite3.connect(str(path), timeout=5)
    db.row_factory = sqlite3.Row
    try:
        with db:
            yield db
    finally:
        db.close()


def _build_snapshot(manifest, *, allow_empty=False):
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise ValueError("unsupported corpus schema")
    documents = manifest.get("documents")
    if not isinstance(documents, list) or not (0 if allow_empty else 1) <= len(documents) <= MAX_DOCUMENTS:
        raise ValueError("corpus document count outside supported range")
    unique = {}
    for item in documents:
        if not isinstance(item, dict):
            raise ValueError("invalid document")
        source = item.get("source_id")
        text = item.get("text")
        summaries = item.get("summaries", [])
        if not isinstance(source, str) or not re.fullmatch(r"[A-Za-z0-9:._-]{1,128}", source):
            raise ValueError("source_id must be an opaque identifier")
        start = bounded_int(item.get("start_line"), 1, 100000000)
        end = bounded_int(item.get("end_line"), start, 100000000)
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
            raise ValueError("document text invalid or oversized")
        if not isinstance(summaries, list) or len(summaries) > 100 or any(
            not isinstance(s, str) or len(s) > MAX_TEXT for s in summaries
        ):
            raise ValueError("summaries invalid or oversized")
        key = (source, start, end)
        if key in unique and unique[key]["text"] != text:
            raise ValueError("conflicting raw text for source span")
        doc = unique.setdefault(key, dict(source_id=source, start_line=start, end_line=end,
                                          text=text, summaries=[], citation_id=""))
        doc["summaries"] = sorted(set(doc["summaries"]) | set(summaries))
        doc["citation_id"] = digest([source, start, end, text])
    docs = [unique[key] for key in sorted(unique)]
    value = dict(schema_version=1, snapshot_id=digest(docs), documents=docs,
                 import_report=manifest.get("import_report", {}))
    raw = canonical(value).encode()
    if len(raw) > MAX_SNAPSHOT_BYTES:
        raise ValueError("snapshot too large")
    return value, raw


def _atomic_snapshot_file(path, raw):
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    try:
        fd = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


def publish_snapshot(root, manifest):
    """Publish a complete validated generation, retaining every previous corpus."""
    value, raw = _build_snapshot(manifest, allow_empty=True)
    root = _root(root)
    lock_fd = os.open(root / ".snapshot.lock", os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(lock_fd, "r+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        previous = _snapshot(root)
        directory = root / "snapshots"
        directory.mkdir(mode=0o700, exist_ok=True)
        _root(directory)
        # Archive old first: a search racing the switch can always resolve its generation.
        for generation, data in ((previous, canonical(previous).encode()), (value, raw)):
            path = directory / (generation["snapshot_id"] + ".json")
            if path.exists() or path.is_symlink():
                _snapshot(root, generation["snapshot_id"])
            else:
                _atomic_snapshot_file(path, data)
        _atomic_snapshot_file(root / "snapshot.json", raw)
    return dict(snapshot_id=value["snapshot_id"], previous_snapshot_id=previous["snapshot_id"],
                changed=value["snapshot_id"] != previous["snapshot_id"], documents=len(value["documents"]),
                summary_documents=sum(bool(d["summaries"]) for d in value["documents"]),
                import_report=value["import_report"])


def create_lab(root: Path, manifest: dict) -> dict:
    value, raw = _build_snapshot(manifest)
    docs = value["documents"]
    root = Path(root).absolute()
    root = root.parent.resolve() / root.name
    root.mkdir(mode=0o700, parents=False, exist_ok=False)
    for name, data in [("snapshot.json", raw), (".gitignore", b"*\n")]:
        fd = os.open(root / name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
    path = root / "measurements.sqlite"
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    with _connect(root) as db:
        db.executescript("""
            CREATE TABLE queries (
                id TEXT PRIMARY KEY, created REAL NOT NULL, query TEXT NOT NULL,
                snapshot_id TEXT NOT NULL, version TEXT NOT NULL, arm TEXT NOT NULL,
                limit_n INTEGER NOT NULL, foreground TEXT NOT NULL, shadow TEXT,
                job_state TEXT NOT NULL, lease_until REAL, error_code TEXT,
                feedback TEXT NOT NULL DEFAULT 'unknown', feedback_events TEXT NOT NULL DEFAULT '[]',
                answers TEXT NOT NULL DEFAULT '{}', assessments TEXT NOT NULL DEFAULT '{}'
            );
            CREATE TABLE reads (request_id TEXT NOT NULL, citation_id TEXT NOT NULL,
                created REAL NOT NULL, elapsed_ms REAL NOT NULL, returned_bytes INTEGER NOT NULL);
            CREATE INDEX queue_pending ON queries(job_state,created);
        """)
    return dict(snapshot_id=value["snapshot_id"], documents=len(docs),
                summary_documents=sum(bool(d["summaries"]) for d in docs),
                import_report=value["import_report"])


def tokens(text):
    # English words and Japanese/CJK character bigrams; no model or network.
    result = []
    for part in re.findall(r"[a-z0-9_]+|[\u3040-\u30ff\u3400-\u9fff]+", text.lower()):
        if re.fullmatch(r"[a-z0-9_]+", part) or len(part) == 1:
            result.append(part)
        else:
            result.extend(part[i:i + 2] for i in range(len(part) - 1))
    return result


def _retrieve(snapshot, query, arm, limit, deadline=None):
    started = time.perf_counter()
    q = set(tokens(query))
    indexed, frequency = [], Counter()
    scanned = 0
    for d in snapshot["documents"]:
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError("shadow time budget exhausted")
        text = d["text"] + ("\n" + "\n".join(d["summaries"]) if arm == "recorder" else "")
        scanned += len(text.encode())
        ts = set(tokens(text))
        frequency.update(ts & q)
        indexed.append((d, ts))
    scored = []
    for d, ts in indexed:
        score = sum(math.log(1 + len(indexed) / (1 + frequency[t])) for t in q & ts)
        if score:
            scored.append((score, d))
    scored.sort(key=lambda pair: (-pair[0], pair[1]["citation_id"]))
    hits = []
    for rank, (_, d) in enumerate(scored[:limit], 1):
        hit = {k: d[k] for k in ("citation_id", "source_id", "start_line", "end_line", "text")}
        hit["rank"] = rank
        hits.append(hit)
    return dict(arm=arm, snapshot_id=snapshot["snapshot_id"], retrieval_version=VERSION, hits=hits,
                metrics=dict(elapsed_ms=(time.perf_counter() - started) * 1000,
                             scanned_bytes=scanned, returned_bytes=sum(len(h["text"].encode()) for h in hits),
                             input_tokens=None, output_tokens=None, cost_microusd=None))


def search(root, query, arm="recorder", limit=5, sample_rate=0.1):
    started = time.perf_counter()
    if not isinstance(query, str) or not query.strip() or len(query) > MAX_QUERY or not tokens(query):
        raise ValueError("query must contain searchable text, maximum 2000 characters")
    if arm not in ARMS:
        raise ValueError("unsupported arm")
    bounded_int(limit, 1, 20)
    if type(sample_rate) not in (int, float) or not math.isfinite(sample_rate) or not 0 <= sample_rate <= 1:
        raise ValueError("sample rate must be 0..1")
    snapshot = _snapshot(root)
    result = _retrieve(snapshot, query, arm, limit)
    request_id = uuid.uuid4().hex
    sampled = int(digest([snapshot["snapshot_id"], request_id])[:16], 16) / 2**64 < sample_rate
    result.update(request_id=request_id, sampled=sampled)
    with _connect(root) as db:
        db.execute("BEGIN IMMEDIATE")
        day_start = int(time.time() // 86400) * 86400
        reserved = db.execute("SELECT COUNT(*) FROM queries WHERE created>=? AND job_state!='not_sampled'", (day_start,)).fetchone()[0]
        if sampled and reserved >= MAX_SHADOWS_PER_DAY:
            sampled = False
            result["sampled"] = False
            result["sampling_skip_reason"] = "daily_shadow_limit"
        db.execute("INSERT INTO queries(id,created,query,snapshot_id,version,arm,limit_n,foreground,job_state) VALUES(?,?,?,?,?,?,?,?,?)",
                   (request_id, time.time(), query, snapshot["snapshot_id"], VERSION, arm, limit, canonical(result),
                    "pending" if sampled else "not_sampled"))
        result["metrics"]["foreground_elapsed_ms"] = (time.perf_counter() - started) * 1000
        db.execute("UPDATE queries SET foreground=? WHERE id=?", (canonical(result), request_id))
    return result


def drain(root, max_jobs=5, max_seconds=10):
    bounded_int(max_jobs, 0, 100)
    if type(max_seconds) not in (int, float) or not math.isfinite(max_seconds) or not 0 < max_seconds <= 60:
        raise ValueError("shadow time budget must be >0 and <=60 seconds")
    deadline = time.monotonic() + max_seconds
    processed = failed = 0
    while processed + failed < max_jobs and time.monotonic() < deadline:
        with _connect(root) as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("UPDATE queries SET job_state='pending' WHERE job_state='running' AND lease_until<?", (time.time(),))
            row = db.execute("SELECT * FROM queries WHERE job_state='pending' ORDER BY created,id LIMIT 1").fetchone()
            if row is None:
                break
            db.execute("UPDATE queries SET job_state='running',lease_until=? WHERE id=?", (time.time() + 120, row["id"]))
        error = None
        try:
            snapshot = _snapshot(root, row["snapshot_id"])
            if row["version"] != VERSION:
                raise ValueError("comparison contract mismatch")
            arm = "baseline" if row["arm"] == "recorder" else "recorder"
            shadow = _retrieve(snapshot, row["query"], arm, row["limit_n"], deadline)
        except (ValueError, OSError, TimeoutError) as exc:
            error = "time_budget_exhausted" if isinstance(exc, TimeoutError) else "contract_mismatch"
        with _connect(root) as db:
            db.execute("UPDATE queries SET job_state=?,shadow=?,error_code=?,lease_until=NULL WHERE id=?",
                       ("error" if error else "complete", None if error else canonical(shadow), error, row["id"]))
        if error:
            failed += 1
        else:
            processed += 1
    with _connect(root) as db:
        pending = db.execute("SELECT COUNT(*) FROM queries WHERE job_state IN ('pending','running')").fetchone()[0]
    return dict(processed=processed, failed=failed, pending=pending)


def _row(db, request_id):
    row = db.execute("SELECT * FROM queries WHERE id=?", (request_id,)).fetchone()
    if row is None:
        raise ValueError("unknown request")
    return row


def feedback(root, request_id, state):
    if state not in ("relevant", "wrong_target", "unresolved"):
        raise ValueError("feedback must be explicit")
    with _connect(root) as db:
        db.execute("BEGIN IMMEDIATE")
        row = _row(db, request_id)
        history = json.loads(row["feedback_events"])
        history.append(dict(state=state, recorded_at=time.time()))
        db.execute("UPDATE queries SET feedback=?,feedback_events=? WHERE id=?", (state, canonical(history), request_id))
    return dict(request_id=request_id, feedback=state)


def read_citation(root, citation_id, request_id=None):
    started = time.perf_counter()
    snapshot_id = None
    if request_id is not None:
        with _connect(root) as db:
            snapshot_id = _row(db, request_id)["snapshot_id"]
    snapshot = _snapshot(root, snapshot_id)
    for d in snapshot["documents"]:
        if d["citation_id"] != citation_id:
            continue
        result = {k: d[k] for k in ("citation_id", "source_id", "start_line", "end_line", "text")}
        if request_id is not None:
            with _connect(root) as db:
                row = _row(db, request_id)
                if row["snapshot_id"] != snapshot["snapshot_id"]:
                    raise ValueError("citation snapshot mismatch")
                db.execute("INSERT INTO reads VALUES(?,?,?,?,?)", (request_id, citation_id, time.time(),
                           (time.perf_counter() - started) * 1000, len(result["text"].encode())))
        return result
    raise ValueError("citation is not in this snapshot")


def record_answer(root, request_id, arm, text, citations):
    if arm not in ARMS or not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT:
        raise ValueError("invalid answer")
    if not isinstance(citations, list) or len(citations) > 20 or any(not isinstance(c, str) for c in citations):
        raise ValueError("invalid citations")
    with _connect(root) as db:
        db.execute("BEGIN IMMEDIATE")
        row = _row(db, request_id)
        snapshot = _snapshot(root, row["snapshot_id"])
        known = {d["citation_id"] for d in snapshot["documents"]}
        answer = dict(text=text, citations=sorted(set(citations)), recorded_at=time.time(),
                      citation_resolution={c: c in known for c in citations})
        answer["answer_id"] = digest([snapshot["snapshot_id"], text, answer["citations"]])
        available = {row["arm"]}
        if row["job_state"] == "complete":
            available.add(json.loads(row["shadow"])["arm"])
        if arm not in available:
            raise ValueError("answer arm has no retrieval run")
        answers = json.loads(row["answers"])
        answers[arm] = answer
        assessments = json.loads(row["assessments"])
        assessments.pop(arm, None)
        db.execute("UPDATE queries SET answers=?,assessments=? WHERE id=?",
                   (canonical(answers), canonical(assessments), request_id))
    return answer


def review_packet(root, request_id):
    with _connect(root) as db:
        row = _row(db, request_id)
        answers = json.loads(row["answers"])
    snapshot = _snapshot(root, row["snapshot_id"])
    docs = {d["citation_id"]: d for d in snapshot["documents"]}
    order = sorted(answers, key=lambda arm: digest([request_id, arm]))
    return dict(request_id=request_id, question=row["query"],
                instruction="Judge relevance and support only from the cited original text. Missing evidence is unknown. Labels hide retrieval arms; summaries are not evidence.",
                candidates=[dict(label=f"candidate-{i + 1}", answer_id=answers[arm]["answer_id"],
                                 answer=answers[arm]["text"], citations=[
                                     {k: docs[c][k] for k in ("citation_id", "source_id", "start_line", "end_line", "text")}
                                     if c in docs else dict(citation_id=c, state="missing")
                                     for c in answers[arm]["citations"]]) for i, arm in enumerate(order)])


def assess(root, request_id, answer_id, grounded, unsupported, provenance):
    if grounded not in ("supported", "unsupported", "unknown") or unsupported not in ("present", "absent", "unknown"):
        raise ValueError("invalid assessment state")
    if not isinstance(provenance, str) or not provenance.strip() or len(provenance) > 256:
        raise ValueError("assessment requires human or model/rubric provenance")
    with _connect(root) as db:
        db.execute("BEGIN IMMEDIATE")
        row = _row(db, request_id)
        answers, assessments = json.loads(row["answers"]), json.loads(row["assessments"])
        arms = [arm for arm, value in answers.items() if value["answer_id"] == answer_id]
        if not arms:
            raise ValueError("unknown or superseded answer")
        for arm in arms:
            a = answers[arm]
            if grounded == "supported" and (not a["citations"] or not all(a["citation_resolution"].values()) or unsupported == "present"):
                raise ValueError("supported answer requires resolvable citations and no asserted unsupported claims")
            assessments[arm] = dict(answer_id=answer_id, grounded=grounded, unsupported_claims=unsupported,
                                    provenance=provenance, recorded_at=time.time())
        db.execute("UPDATE queries SET assessments=? WHERE id=?", (canonical(assessments), request_id))
    return dict(request_id=request_id, assessed_answers=len(arms))


def report(root, include_reviewed=False):
    with _connect(root) as db:
        rows = db.execute("SELECT * FROM queries ORDER BY created,id").fetchall()
        reads = db.execute("SELECT COUNT(*),COALESCE(SUM(returned_bytes),0) FROM reads").fetchone()
        acknowledgements = {}
        if db.execute("SELECT 1 FROM sqlite_master WHERE name='review_acknowledgements'").fetchone():
            acknowledgements = dict(db.execute("SELECT request_id,fingerprint FROM review_acknowledgements"))
    cases, states, feedbacks = [], Counter(), Counter()
    arm_metrics = {arm: dict(runs=0, search_ms=0.0, returned_bytes=0, assessed_answers=0,
                            supported_answers=0, unsupported_claim_answers=0) for arm in ARMS}
    reviewed = 0
    for row in rows:
        states[row["job_state"]] += 1
        feedbacks[row["feedback"]] += 1
        fg = json.loads(row["foreground"])
        shadow = json.loads(row["shadow"]) if row["shadow"] else None
        for run in (fg, shadow):
            if run is not None:
                summary = arm_metrics[run["arm"]]
                summary["runs"] += 1
                summary["search_ms"] += run["metrics"]["elapsed_ms"]
                summary["returned_bytes"] += run["metrics"]["returned_bytes"]
        reasons = []
        if shadow:
            a, b = [h["citation_id"] for h in fg["hits"]], [h["citation_id"] for h in shadow["hits"]]
            if bool(a) != bool(b):
                reasons.append("one_sided_retrieval")
            elif a[:1] != b[:1]:
                reasons.append("top_citation_changed")
            elif set(a) != set(b):
                reasons.append("candidate_membership_changed")
            # Suppress millisecond noise; compare search computation only.
            t1, t2 = fg["metrics"]["elapsed_ms"], shadow["metrics"]["elapsed_ms"]
            if a == b and a and abs(t1 - t2) >= 100 and max(t1, t2) >= 2 * max(min(t1, t2), 1):
                reasons.append("same_results_large_latency_difference")
        if row["feedback"] == "wrong_target":
            reasons.append("explicit_wrong_target")
        answers, assessments = json.loads(row["answers"]), json.loads(row["assessments"])
        for arm, assessment in assessments.items():
            arm_metrics[arm]["assessed_answers"] += 1
            arm_metrics[arm]["supported_answers"] += assessment["grounded"] == "supported"
            arm_metrics[arm]["unsupported_claim_answers"] += assessment["unsupported_claims"] == "present"
        if any(not all(a["citation_resolution"].values()) for a in answers.values()):
            reasons.append("unresolvable_answer_citation")
        if any(a["unsupported_claims"] == "present" for a in assessments.values()):
            reasons.append("unsupported_answer_claim")
        if len(assessments) == 2 and len({(a["grounded"], a["unsupported_claims"]) for a in assessments.values()}) > 1:
            reasons.append("answer_assessment_differs")
        if reasons:
            fingerprint = digest([reasons, fg, shadow, row["feedback"], answers, assessments])
            is_reviewed = acknowledgements.get(row["id"]) == fingerprint
            reviewed += is_reviewed
            if is_reviewed and not include_reviewed:
                continue
            cases.append(dict(request_id=row["id"], question=row["query"], reason=reasons, fingerprint=fingerprint,
                              feedback=row["feedback"], foreground=fg, shadow=shadow,
                              assessments=assessments, state="reviewed" if is_reviewed else "needs_review"))
    for metrics in arm_metrics.values():
        metrics["mean_search_ms"] = metrics["search_ms"] / metrics["runs"] if metrics["runs"] else None
        metrics["supported_fraction_of_assessed"] = (metrics["supported_answers"] / metrics["assessed_answers"]
                                                     if metrics["assessed_answers"] else None)
    return dict(schema_version=1, measurement_scope="retrieval; answer quality only where explicitly assessed",
                total_queries=len(rows), completed_pairs=states["complete"], pending_pairs=states["pending"] + states["running"],
                failed_pairs=states["error"], feedback_unknown=feedbacks["unknown"], feedback=dict(feedbacks),
                citation_reads=reads[0], citation_read_bytes=reads[1], reviewed_cases=reviewed,
                arm_metrics=arm_metrics, review_cases=cases,
                comparison_note="Arm aggregates include unpaired foregrounds; assess speed differences on paired cases or benchmark only.")


def acknowledge(root, request_id, fingerprint):
    cases = report(root, include_reviewed=True)["review_cases"]
    if not any(c["request_id"] == request_id and c["fingerprint"] == fingerprint for c in cases):
        raise ValueError("review case changed or unavailable; read current report")
    with _connect(root) as db:
        db.execute("CREATE TABLE IF NOT EXISTS review_acknowledgements (request_id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL)")
        db.execute("INSERT OR REPLACE INTO review_acknowledgements VALUES(?,?)", (request_id, fingerprint))
    return dict(request_id=request_id, state="reviewed")


def benchmark(root, cases, repeats=1):
    bounded_int(repeats, 1, 3)
    snapshot = _snapshot(root)
    known = {d["citation_id"] for d in snapshot["documents"]}
    if not isinstance(cases, list) or not 1 <= len(cases) <= 100:
        raise ValueError("benchmark needs 1..100 cases")
    results = []
    for i, case in enumerate(cases):
        expected = case.get("expected_citations")
        query = case.get("question")
        if not isinstance(expected, list) or not expected or not all(isinstance(c, str) and c in known for c in expected):
            raise ValueError("gold citations must exist in snapshot")
        if not isinstance(query, str) or not query.strip() or len(query) > MAX_QUERY or not tokens(query):
            raise ValueError("invalid benchmark question")
        for repeat in range(repeats):
            for arm in (ARMS if (i + repeat) % 2 == 0 else tuple(reversed(ARMS))):
                # Gold never enters retrieval inputs, query history, or the shadow queue.
                result = _retrieve(snapshot, query, arm, 5)
                ranks = [h["rank"] for h in result["hits"] if h["citation_id"] in expected]
                results.append(dict(case=i + 1, repeat=repeat + 1, arm=arm,
                                    evidence_hit=bool(ranks), reciprocal_rank=1 / min(ranks) if ranks else 0,
                                    metrics=result["metrics"]))
    return dict(snapshot_id=snapshot["snapshot_id"], retrieval_version=VERSION,
                measurement_scope="evidence retrieval, not grounded answer accuracy", results=results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lab", required=True, type=Path, help="dedicated owner-only local experiment directory")
    subs = parser.add_subparsers(dest="command", required=True)
    init = subs.add_parser("prepare")
    inputs = init.add_mutually_exclusive_group(required=True)
    inputs.add_argument("--manifest", type=Path)
    inputs.add_argument("--vault", type=Path)
    query = subs.add_parser("search")
    query.add_argument("query")
    query.add_argument("--arm", choices=ARMS, default="recorder")
    query.add_argument("--limit", type=int, default=5)
    query.add_argument("--sample-rate", type=float, default=.1)
    query.add_argument("--no-worker", action="store_true")
    worker = subs.add_parser("worker")
    worker.add_argument("--max-jobs", type=int, default=5)
    worker.add_argument("--max-seconds", type=float, default=10)
    rep = subs.add_parser("report")
    rep.add_argument("--include-reviewed", action="store_true")
    ack = subs.add_parser("acknowledge")
    ack.add_argument("request_id")
    ack.add_argument("fingerprint")
    read = subs.add_parser("read")
    read.add_argument("citation_id")
    read.add_argument("--request-id")
    fb = subs.add_parser("feedback")
    fb.add_argument("request_id")
    fb.add_argument("state", choices=("relevant", "wrong_target", "unresolved"))
    answer = subs.add_parser("answer")
    answer.add_argument("request_id")
    answer.add_argument("--arm", required=True, choices=ARMS)
    answer.add_argument("--file", required=True, type=Path, help="JSON with text and citations")
    review = subs.add_parser("review-packet")
    review.add_argument("request_id")
    judge = subs.add_parser("assess")
    judge.add_argument("request_id")
    judge.add_argument("--file", required=True, type=Path, help="JSON with answer_id,grounded,unsupported,provenance")
    bench = subs.add_parser("benchmark")
    bench.add_argument("--cases", type=Path, required=True)
    bench.add_argument("--repeats", type=int, default=1)
    args = parser.parse_args()
    root = args.lab.absolute()
    try:
        if args.command == "prepare":
            if args.vault:
                from retrieval_snapshot import export_vault
                manifest = export_vault(args.vault)
            else:
                manifest = json.loads(safe_file(args.manifest, MAX_SNAPSHOT_BYTES))
            result = create_lab(root, manifest)
        elif args.command == "search":
            result = search(root, args.query, args.arm, args.limit, args.sample_rate)
        elif args.command == "worker":
            result = drain(root, args.max_jobs, args.max_seconds)
        elif args.command == "report":
            result = report(root, args.include_reviewed)
        elif args.command == "acknowledge":
            result = acknowledge(root, args.request_id, args.fingerprint)
        elif args.command == "read":
            result = read_citation(root, args.citation_id, args.request_id)
        elif args.command == "feedback":
            result = feedback(root, args.request_id, args.state)
        elif args.command == "answer":
            value = json.loads(safe_file(args.file, 1024 * 1024))
            result = record_answer(root, args.request_id, args.arm, value["text"], value["citations"])
        elif args.command == "review-packet":
            result = review_packet(root, args.request_id)
        elif args.command == "assess":
            value = json.loads(safe_file(args.file, 65536))
            result = assess(root, args.request_id, **value)
        else:
            result = benchmark(root, json.loads(safe_file(args.cases, 1024 * 1024)), args.repeats)
        print(canonical(result), flush=True)
        if args.command == "search" and result["sampled"] and not args.no_worker:
            # User output has already been flushed. Child is a bounded, local-only worker.
            try:
                subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--lab", str(root), "worker"],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True, close_fds=True)
            except OSError:
                print("Shadow worker unavailable; comparison remains queued.", file=sys.stderr)
        return 0
    except (ValueError, OSError, KeyError, TypeError, sqlite3.Error) as exc:
        print(canonical(dict(error=type(exc).__name__, message="Retrieval operation failed; check inputs and local lab state.")), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
