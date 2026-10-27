#!/usr/bin/env python3
"""Local retrieval measurement. No provider calls, vault writes, or self-adoption."""
from __future__ import annotations

import argparse
from collections import Counter
from contextlib import contextmanager
import hashlib
from functools import wraps
import threading
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


# Readers hold this through reference registration, not just loading the corpus.
# Nested calls share the outer lock; a shared-to-exclusive upgrade is forbidden.
_snapshot_locks = threading.local()


@contextmanager
def snapshot_lock(root, exclusive=False):
    root = _root(root)
    held = getattr(_snapshot_locks, 'held', {})
    key = str(root)
    if key in held:
        if exclusive and not held[key]:
            raise ValueError('snapshot lock upgrade unsupported')
        yield
        return
    fd = os.open(root / '.snapshot.lock', os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        held[key] = exclusive
        _snapshot_locks.held = held
        try:
            yield
        finally:
            del held[key]
    finally:
        os.close(fd)


def snapshot_operation(function):
    @wraps(function)
    def guarded(root, *args, **kwargs):
        with snapshot_lock(root):
            return function(root, *args, **kwargs)
    return guarded


def _snapshot(root, snapshot_id=None):
    root = _root(root)
    if snapshot_id is not None and (not isinstance(snapshot_id, str) or not re.fullmatch(r"[0-9a-f]{64}", snapshot_id)):
        raise ValueError("invalid snapshot identifier")
    from retrieval_archive import read as read_archive
    if snapshot_id is None:
        raw = safe_file(root / 'snapshot.json', MAX_SNAPSHOT_BYTES)
    else:
        try:
            raw = read_archive(root, snapshot_id)
        except FileNotFoundError:
            raw = safe_file(root / 'snapshot.json', MAX_SNAPSHOT_BYTES)
            current = json.loads(raw)
            if not isinstance(current, dict) or current.get('snapshot_id') != snapshot_id:
                # Publication can archive the old current while we open current.
                raw = read_archive(root, snapshot_id)
    value = json.loads(raw)
    if not isinstance(value, dict) or value.get("schema_version") != 1 or value.get("snapshot_id") != digest(value.get("documents")):
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
    with snapshot_lock(root):
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
        source_kind = item.get('source_kind')
        if source_kind not in (None, 'agent_consultation'):
            raise ValueError('invalid source kind')
        spans = item.get('message_spans')
        if spans is not None:
            from retrieval_context import validate_spans
            validate_spans(text, start, end, spans)
        key = (source, start, end)
        if key in unique and unique[key]["text"] != text:
            raise ValueError("conflicting raw text for source span")
        if key in unique and unique[key].get('source_kind') != source_kind:
            raise ValueError('conflicting source provenance')
        doc = unique.setdefault(key, dict(source_id=source, start_line=start, end_line=end,
                                          text=text, summaries=[], citation_id=""))
        if source_kind:
            doc['source_kind'] = source_kind
        if spans is not None:
            if 'message_spans' in doc and doc['message_spans'] != spans:
                raise ValueError('conflicting message spans')
            doc['message_spans'] = spans
        if 'turn_observations' in item:
            from retrieval_opportunities import validate_observations
            observations = validate_observations(item['turn_observations'], spans)
            if 'turn_observations' in doc and doc['turn_observations'] != observations:
                raise ValueError('conflicting turn observations')
            doc['turn_observations'] = observations
        doc["summaries"] = sorted(set(doc["summaries"]) | set(summaries))
        doc["citation_id"] = digest([source, start, end, text])
    source_kinds = {}
    for doc in unique.values():
        kind = doc.get('source_kind')
        if doc['source_id'] in source_kinds and source_kinds[doc['source_id']] != kind:
            raise ValueError('inconsistent source provenance')
        source_kinds[doc['source_id']] = kind
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


def publish_snapshot(root, manifest, *, storage_policy=None):
    """Publish atomically; optional retention preserves every referenced corpus."""
    value, raw = _build_snapshot(manifest, allow_empty=True)
    root = _root(root)
    with snapshot_lock(root, exclusive=True):
        previous = _snapshot(root)
        directory = root / "snapshots"
        directory.mkdir(mode=0o700, exist_ok=True)
        _root(directory)
        from retrieval_archive import exists, pack
        storage = None
        generations = {previous['snapshot_id']: canonical(previous).encode()}
        generations.setdefault(value['snapshot_id'], raw)
        missing = {identity: data for identity, data in generations.items() if not exists(root, identity)}
        import retrieval_shared as shared
        shared_mode = shared.enabled(root)
        prepared = {key: shared.prepare(data, key) for key, data in missing.items()} if shared_mode else {}
        if storage_policy is not None:
            from retrieval_retention import maintain
            if shared_mode:
                objects = {key: data for _, chunks in prepared.values() for key, data in chunks.items()}
                existing = shared.inventory(root)
                reserve = sum(len(meta) for meta, _ in prepared.values()) + sum(len(data) for key, data in objects.items() if key not in existing)
                storage = maintain(root, storage_policy, reserve_bytes=reserve,
                                   extra_protected=set(generations), protected_objects=set(objects))
            else:
                encoded = {identity: pack(data) for identity, data in missing.items()}
                storage = maintain(root, storage_policy, reserve_bytes=sum(map(len, encoded.values())),
                                   extra_protected=set(generations))
        else:
            encoded = missing
        # Archive old first. Fixed labs keep the legacy format; auto-refresh
        # writes compressed generations and leaves the live corpus uncompressed.
        for identity in generations:
            if exists(root, identity):
                _snapshot(root, identity)
            elif shared_mode:
                path = shared.write(root, identity, prepared[identity])
                if shared.read(path) != missing[identity]:
                    raise ValueError('shared publication mismatch')
            else:
                suffix = '.json.gz' if storage_policy is not None else '.json'
                _atomic_snapshot_file(directory / (identity + suffix), encoded[identity])
        _atomic_snapshot_file(root / "snapshot.json", raw)
        if storage is not None:
            storage.update(archive_bytes=storage['projected_bytes'], reserved_bytes=0,
                           archive_count=len({p.name[:64] for p in directory.glob('*.json*')}))
            from retrieval_retention import _save
            _save(root, storage)
    return dict(snapshot_id=value["snapshot_id"], previous_snapshot_id=previous["snapshot_id"],
                changed=value["snapshot_id"] != previous["snapshot_id"], documents=len(value["documents"]),
                summary_documents=sum(bool(d["summaries"]) for d in value["documents"]),
                import_report=value["import_report"], **({"storage": storage} if storage is not None else {}))


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
        hit["source_kind"] = d.get("source_kind", "unspecified")
        hit["rank"] = rank
        hits.append(hit)
    return dict(arm=arm, snapshot_id=snapshot["snapshot_id"], retrieval_version=VERSION, hits=hits,
                metrics=dict(elapsed_ms=(time.perf_counter() - started) * 1000,
                             scanned_bytes=scanned, returned_bytes=sum(len(h["text"].encode()) for h in hits),
                             input_tokens=None, output_tokens=None, cost_microusd=None))


@snapshot_operation
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


@snapshot_operation
def search_corrections(root, query, trigger, limit=3, purpose='task', task=None, session_id=None, need=None, retry_of=None):
    from retrieval_context import retrieve, TRIGGERS, VERSION as context_version
    if not isinstance(query, str) or not query.strip() or len(query) > MAX_QUERY or not tokens(query):
        raise ValueError('invalid correction query')
    if purpose not in ('task', 'verification'):
        raise ValueError('invalid context purpose')
    if trigger not in TRIGGERS:
        raise ValueError('invalid correction trigger')
    bounded_int(limit, 1, 5)
    started = time.perf_counter()
    for label in (task, session_id, need):
        if label is not None and (not isinstance(label, str) or not label.strip() or len(label) > 1000):
            raise ValueError('invalid invocation label')
    parent = None
    if retry_of is not None:
        with _connect(root) as db:
            parent = json.loads(_row(db, retry_of)['foreground'])
        if (parent.get('mode') != 'corrections' or not parent.get('decision_need')
                or parent.get('supplement') or parent['decision_need'].get('retry_of') or parent.get('purpose') != purpose):
            raise ValueError('retry requires an initial decision-need search with same purpose')
        if need is not None and need != parent['decision_need']['text']:
            raise ValueError('retry cannot change decision need')
        need = parent['decision_need']['text']
    scope = '\n'.join(value for value in (task, need) if value)
    result = retrieve(_snapshot(root), query, limit, scope=scope or None)
    environment_id = os.environ.get('CODEX_THREAD_ID')
    result['origin'] = dict(cwd=str(Path.cwd()), task=task,
        session_id=session_id or (environment_id[:1000] if environment_id else None),
        session_id_source='explicit' if session_id else ('CODEX_THREAD_ID' if environment_id else None))
    if parent and result['origin']['session_id'] != parent.get('origin', {}).get('session_id'):
        raise ValueError('retry must use the same caller session')
    state_file = Path(root) / 'refresh-state.json'
    try:
        state = json.loads(safe_file(state_file, 1024 * 1024))
        result['collection'] = {key: state.get(key) for key in ('status', 'last_success', 'last_attempt', 'error_type', 'collector_version', 'collection_complete', 'deferred_source_ids', 'last_published')}
    except (OSError, ValueError):
        result['collection'] = None
    result['metrics']['foreground_elapsed_ms'] = (time.perf_counter() - started) * 1000
    request_id = uuid.uuid4().hex
    if need:
        result['decision_need'] = dict(version=1, text=need, root_request_id=retry_of or request_id,
                                       retry_of=retry_of, recorded_before_results=True)
    result.update(request_id=request_id, trigger=trigger, purpose=purpose, sampled=False,
                  sampling_skip_reason='context_mode_has_no_paired_shadow')
    with _connect(root) as db:
        db.execute('BEGIN IMMEDIATE')
        if retry_of and any(json.loads(r[0]).get('decision_need', {}).get('retry_of') == retry_of
                            for r in db.execute('SELECT foreground FROM queries')):
            raise ValueError('only one focused retry per decision need')
        db.execute('INSERT INTO queries(id,created,query,snapshot_id,version,arm,limit_n,foreground,job_state) VALUES(?,?,?,?,?,?,?,?,?)',
                   (request_id, time.time(), query, result['snapshot_id'], context_version,
                    'recorder', limit, canonical(result), 'not_sampled'))
    return result


def _context_table(db):
    db.execute('CREATE TABLE IF NOT EXISTS context_uses (request_id TEXT PRIMARY KEY, state TEXT NOT NULL, citations TEXT NOT NULL, reason TEXT NOT NULL, recorded REAL NOT NULL)')
    db.execute('CREATE TABLE IF NOT EXISTS context_use_details (request_id TEXT PRIMARY KEY, reason_code TEXT, effect TEXT)')


def context_use(root, request_id, state, citations, reason, reason_code=None, effect=None, decision_match=None, reuse=None):
    if decision_match not in (None, 'found', 'partial', 'not_found', 'unknown'):
        raise ValueError('invalid decision match')
    allowed_reasons = {'applied': ('relevant',), 'not_applicable': ('wrong_scope', 'outdated', 'already_known', 'no_relevant_candidate'), 'unresolved': ('insufficient_context', 'collection_problem')}
    if reason_code is not None and reason_code not in allowed_reasons.get(state, ()):
        raise ValueError('reason code must match use state')
    if effect is not None and (state != 'applied' or effect not in ('confirmed', 'changed_plan', 'avoided_question')):
        raise ValueError('effect requires applied state')
    if state not in ('applied', 'not_applicable', 'unresolved'):
        raise ValueError('invalid context use state')
    if not isinstance(reason, str) or not reason.strip() or len(reason) > 1000:
        raise ValueError('context use requires a bounded reason')
    if not isinstance(citations, list) or len(citations) > 15 or any(not isinstance(c, str) for c in citations):
        raise ValueError('invalid context citations')
    with _connect(root) as db:
        row = _row(db, request_id)
        if json.loads(row['foreground']).get('mode') != 'corrections':
            raise ValueError('not a context search')
        result = json.loads(row['foreground'])
        known = {h[key]['citation_id'] for h in result['hits']
                 for key in ('utterance', 'request', 'prior_response') if h[key]}
        read = {r[0] for r in db.execute('SELECT citation_id FROM reads WHERE request_id=?', (request_id,))}
        if not set(citations) <= known & read or (state == 'applied' and not citations):
            raise ValueError('use requires read, returned citations')
        if decision_match is not None and not result.get('decision_need'):
            raise ValueError('decision match requires a prospectively recorded need')
        if decision_match in ('found', 'partial') and not citations:
            raise ValueError('decision match requires read citations')
        if decision_match in ('not_found', 'unknown') and state == 'applied':
            raise ValueError('applied decision cannot be not_found or unknown')
        reuse_report = None
        if reuse is not None:
            if state != 'applied' or not result.get('decision_need'):
                raise ValueError('reuse requires applied decision need')
            from retrieval_reuse import validate
            reuse_report = validate(root, row, citations, reuse)
        _context_table(db)
        db.execute('CREATE TABLE IF NOT EXISTS context_decision_matches (request_id TEXT PRIMARY KEY, match TEXT NOT NULL)')
        db.execute('DELETE FROM context_decision_matches WHERE request_id=?', (request_id,))
        if decision_match is not None:
            db.execute('INSERT INTO context_decision_matches VALUES(?,?)', (request_id, decision_match))
        db.execute('INSERT OR REPLACE INTO context_uses VALUES(?,?,?,?,?)',
                   (request_id, state, canonical(sorted(set(citations))), reason, time.time()))
        db.execute('INSERT OR REPLACE INTO context_use_details VALUES(?,?,?)', (request_id, reason_code, effect))
        if reuse_report is not None:
            db.execute('CREATE TABLE IF NOT EXISTS context_answer_reuse (seq INTEGER PRIMARY KEY, request_id TEXT NOT NULL, recorded REAL NOT NULL, report TEXT NOT NULL)')
            db.execute('INSERT INTO context_answer_reuse(request_id,recorded,report) VALUES(?,?,?)', (request_id, time.time(), canonical(reuse_report)))
    return dict(request_id=request_id, state=state, provenance='agent_self_report',
                notice='Not user feedback or verified task improvement.',
                reuse_recording=('recorded' if reuse_report else 'not_recorded'),
                supplement_command=('context-supplement ' + request_id
                    if decision_match == 'not_found' and row['limit_n'] == 3
                    and not result.get('supplement') and not result.get('decision_need', {}).get('retry_of') else None),
                next_step=('Only if you actually reused a past answer in this current adoption, use context-use-template to record it before the next user reply. Otherwise leave reuse omitted. Do not invent an avoided question or backfill old uses.'
                           if state == 'applied' and result.get('decision_need') and reuse_report is None else None))


def context_inspect(root, request_id):
    """Reconstruct one recorded invocation without rerunning search or marking read."""
    with _connect(root) as db:
        row = _row(db, request_id)
        result = json.loads(row['foreground'])
        if result.get('mode') != 'corrections':
            raise ValueError('not a context search')
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        use = db.execute('SELECT * FROM context_uses WHERE request_id=?', (request_id,)).fetchone() if 'context_uses' in tables else None
        details = db.execute('SELECT reason_code,effect FROM context_use_details WHERE request_id=?', (request_id,)).fetchone() if 'context_use_details' in tables else None
        match = db.execute('SELECT match FROM context_decision_matches WHERE request_id=?', (request_id,)).fetchone() if 'context_decision_matches' in tables else None
        return dict(decision_match=match[0] if match else None, request_id=request_id, created=row['created'], query=row['query'], result=result,
                    reads=[dict(r) for r in db.execute('SELECT * FROM reads WHERE request_id=? ORDER BY created', (request_id,))],
                    use=dict(use) if use else None, use_details=dict(details) if details else None,
                    reuse_reports=[dict(r, report=json.loads(r['report'])) for r in db.execute('SELECT * FROM context_answer_reuse WHERE request_id=? ORDER BY seq',(request_id,))] if 'context_answer_reuse' in tables else [],
                    notice='Recorded evidence only; missing historical fields are unknown. Use/effect are agent self-reports.')


def context_report(root, purpose=None):
    if purpose not in (None, 'task', 'verification'):
        raise ValueError('invalid purpose filter')
    with _connect(root) as db:
        rows = [r for r in db.execute('SELECT id,created,query,foreground FROM queries ORDER BY created')
                if json.loads(r['foreground']).get('mode') == 'corrections'
                and (purpose is None or json.loads(r['foreground']).get('purpose', 'task') == purpose)]
        ids = {r['id'] for r in rows}
        results = [json.loads(r['foreground']) for r in rows]
        read_ids = {r[0] for r in db.execute('SELECT DISTINCT request_id FROM reads')} & ids
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        uses = {r['request_id']: dict(r) for r in db.execute('SELECT * FROM context_uses') if r['request_id'] in ids} if 'context_uses' in tables else {}
        details = [dict(r) for r in db.execute('SELECT * FROM context_use_details') if r['request_id'] in ids] if 'context_use_details' in tables else []
        matches = {r['request_id']: r['match'] for r in db.execute('SELECT * FROM context_decision_matches')} if 'context_decision_matches' in tables else {}
        from retrieval_supplement import observations
        supplements = observations(db, rows)
        from retrieval_context import filter_observations
        candidate_filters = filter_observations(db, rows)
    from retrieval_needs import summarize
    from retrieval_followup import report as followup_report
    followups = None
    if purpose != 'verification':
        try:
            followups = {k:v for k,v in followup_report(root).items() if k != 'review_cases'}
        except (OSError, ValueError, KeyError, TypeError, RecursionError) as exc:
            followups = dict(status='error', error_type=type(exc).__name__)
    return dict(candidate_filters=candidate_filters, supplements=supplements, followups=followups, decision_needs=summarize(rows, uses, matches), searches=len(rows), triggers=dict(Counter(r['trigger'] for r in results)),
                purposes=dict(Counter(r.get('purpose', 'task') for r in results)), requests_with_reads=len(read_ids),
                uses=dict(Counter(u['state'] for u in uses.values())), unreported=len(ids - uses.keys()),
                reason_codes=dict(Counter(d['reason_code'] for d in details if d['reason_code'])),
                effects=dict(Counter(d['effect'] for d in details if d['effect'])),
                reason_code_missing=len(uses) - sum(bool(d['reason_code']) for d in details),
                origin_missing=sum(not r.get('origin', {}).get('session_id') for r in results),
                recent=[dict(request_id=r['id'], created=r['created'], query=r['query'],
                             state=uses.get(r['id'], {}).get('state')) for r in rows[-20:][::-1]],
                notice='Invocation and agent self-report only. Follow-up observations are separate; causal reduction in rework is unmeasured.')


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
        result["source_kind"] = d.get("source_kind", "unspecified")
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
        rows = db.execute("SELECT * FROM queries WHERE version=? ORDER BY created,id", (VERSION,)).fetchall()
        reads = db.execute("SELECT COUNT(*),COALESCE(SUM(r.returned_bytes),0) FROM reads r JOIN queries q ON q.id=r.request_id WHERE q.version=?", (VERSION,)).fetchone()
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
    context = subs.add_parser('corrections')
    context.add_argument('query')
    context.add_argument('--trigger', required=True, choices=('resume', 'ambiguous', 'explicit'))
    context.add_argument('--limit', type=int, default=3)
    context.add_argument('--purpose', choices=('task', 'verification'), default='task')
    context.add_argument('--need', help='past decision needed, recorded before seeing results')
    context.add_argument('--retry-of', help='initial request ID for one focused retry of the same need')
    context.add_argument('--task', help='short current task description, stored locally')
    context.add_argument('--session-id', help='caller session ID when runtime does not expose one')
    supplement = subs.add_parser('context-supplement')
    supplement.add_argument('request_id')
    inspect = subs.add_parser('context-inspect')
    inspect.add_argument('request_id')
    template = subs.add_parser('context-use-template')
    template.add_argument('request_id')
    usage = subs.add_parser('context-use')
    usage.add_argument('request_id')
    usage.add_argument('--file', type=Path, required=True, help='JSON: state, citations, reason; agent self-report')
    freeze = subs.add_parser('reuse-freeze')
    freeze.add_argument('request_id')
    freeze.add_argument('--case-id', required=True)
    replay = subs.add_parser('reuse-replay')
    replay.add_argument('--file', type=Path, required=True)
    subs.add_parser('followup-report')
    followup = subs.add_parser('followup-inspect')
    followup.add_argument('case_id')
    followup.add_argument('--blind', action='store_true')
    followup_review = subs.add_parser('followup-review')
    followup_review.add_argument('case_id')
    followup_review.add_argument('--file', type=Path, required=True)
    subs.add_parser('opportunity-report')
    opportunity = subs.add_parser('opportunity-inspect')
    opportunity.add_argument('case_id')
    summary = subs.add_parser('context-report')
    summary.add_argument('--purpose', choices=('task', 'verification'))
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
        elif args.command == 'corrections':
            result = search_corrections(root, args.query, args.trigger, args.limit, args.purpose, args.task, args.session_id, args.need, args.retry_of)
        elif args.command == 'context-supplement':
            from retrieval_supplement import open_supplement
            result = open_supplement(root, args.request_id)
        elif args.command == 'context-use-template':
            from retrieval_reuse import use_template
            result = use_template(root, args.request_id)
        elif args.command == 'context-use':
            value = json.loads(safe_file(args.file, 16384))
            result = context_use(root, args.request_id, **value)
        elif args.command == 'reuse-freeze':
            from retrieval_reuse import freeze
            result = freeze(root, args.request_id, args.case_id)
        elif args.command == 'reuse-replay':
            from retrieval_reuse import replay
            result = replay(root, json.loads(safe_file(args.file, 262144)))
        elif args.command == 'followup-report':
            from retrieval_followup import report as followup_report
            result = followup_report(root)
        elif args.command == 'followup-inspect':
            from retrieval_followup import inspect as followup_inspect
            result = followup_inspect(root, args.case_id, args.blind)
        elif args.command == 'followup-review':
            from retrieval_followup import review as followup_review
            result = followup_review(root, args.case_id, **json.loads(safe_file(args.file, 16384)))
        elif args.command == 'opportunity-inspect':
            from retrieval_opportunities import inspect as inspect_opportunity
            result = inspect_opportunity(root, args.case_id)
        elif args.command == 'opportunity-report':
            from retrieval_opportunities import report as opportunity_report
            result = opportunity_report(root)
        elif args.command == 'context-report':
            result = context_report(root, args.purpose)
        elif args.command == 'context-inspect':
            result = context_inspect(root, args.request_id)
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
        display = result
        if args.command == 'corrections':
            # Detailed score terms stay in the log; fetch them only for diagnosis.
            display = json.loads(canonical(result))
            for hit in display['hits']:
                hit['explanation'].pop('contributions', None)
            display['diagnostics_command'] = 'context-inspect ' + result['request_id']
        from retrieval_redaction import redact_payload
        print(canonical(redact_payload(display)), flush=True)
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
