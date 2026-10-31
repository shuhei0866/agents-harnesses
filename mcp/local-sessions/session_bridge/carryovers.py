"""Small, explicitly scoped reminders; selection is not resolution or delivery."""
from __future__ import annotations

import json
import time
import uuid

MAX_NOTES = 3
MAX_TEXT = 400
SCHEMA = """
    CREATE TABLE IF NOT EXISTS carryover_notes (
        id TEXT PRIMARY KEY, scope TEXT NOT NULL, request_id TEXT NOT NULL,
        text TEXT NOT NULL, state TEXT NOT NULL, created REAL NOT NULL,
        updated REAL NOT NULL, selected_at REAL NOT NULL DEFAULT 0,
        UNIQUE(scope, request_id)
    );
    CREATE INDEX IF NOT EXISTS carryover_scope ON carryover_notes(scope, state, selected_at);
    CREATE TABLE IF NOT EXISTS dialogue_carryovers (
        dialogue_id TEXT PRIMARY KEY, scope TEXT NOT NULL, payload TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS job_carryovers (
        job_id TEXT PRIMARY KEY, payload TEXT NOT NULL
    );
"""


def empty():
    return dict(notes=[], open_count=0, omitted_count=0)


def scope_for(db, *, session=None, dialogue_id=None):
    if (session is None) == (dialogue_id is None):
        raise ValueError('provide exactly one session or dialogue_id')
    if dialogue_id is not None:
        if not db.execute('SELECT 1 FROM dialogues WHERE id=?', (dialogue_id,)).fetchone():
            raise ValueError('unknown dialogue')
        row = db.execute('SELECT scope FROM dialogue_carryovers WHERE dialogue_id=?', (dialogue_id,)).fetchone()
        return row['scope'] if row else 'dialogue:' + dialogue_id
    row = db.execute('SELECT id FROM sessions WHERE id=? OR name=?', (session, session)).fetchone()
    if row is None:
        raise ValueError('unknown session')
    if db.execute('SELECT 1 FROM dialogue_participants WHERE session_id=?', (row['id'],)).fetchone():
        raise ValueError('dialogue-owned session: use dialogue_id to explicitly share with both providers')
    return 'session:' + row['id']


def keep(store, text, request_id, *, session=None, dialogue_id=None):
    if not isinstance(text, str) or not 1 <= len(text.strip()) <= MAX_TEXT or len(text.splitlines()) != 1:
        raise ValueError('text must be one nonempty line of at most 400 characters')
    if not isinstance(request_id, str) or not 1 <= len(request_id) <= 128:
        raise ValueError('request_id must contain 1-128 characters')
    text = text.strip()
    with store.db() as db:
        db.execute('BEGIN IMMEDIATE')
        scope = scope_for(db, session=session, dialogue_id=dialogue_id)
        old = db.execute('SELECT * FROM carryover_notes WHERE scope=? AND request_id=?', (scope, request_id)).fetchone()
        if old:
            if old['text'] != text:
                raise ValueError('request_id was already used with different text')
            return dict(old)
        nid, now = str(uuid.uuid4()), time.time()
        db.execute('INSERT INTO carryover_notes VALUES (?,?,?,?,?,?,?,?)',
                   (nid, scope, request_id, text, 'open', now, now, 0))
        return dict(db.execute('SELECT * FROM carryover_notes WHERE id=?', (nid,)).fetchone())


def listing(store, *, session=None, dialogue_id=None, state='open', offset=0, limit=100):
    if state not in ('open', 'closed', 'all') or type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 100:
        raise ValueError('invalid state or pagination')
    with store.db() as db:
        scope = scope_for(db, session=session, dialogue_id=dialogue_id)
        where, args = 'scope=?', [scope]
        if state != 'all':
            where += ' AND state=?'; args.append(state)
        total = db.execute('SELECT count(*) FROM carryover_notes WHERE ' + where, args).fetchone()[0]
        rows = db.execute('SELECT * FROM carryover_notes WHERE ' + where +
                          ' ORDER BY created,id LIMIT ? OFFSET ?', (*args, limit, offset)).fetchall()
    return dict(notes=[dict(r) for r in rows], total=total, next_offset=offset + len(rows), has_more=offset + len(rows) < total)


def set_state(store, note_id, state):
    if state not in ('open', 'closed'):
        raise ValueError('state must be open or closed')
    with store.db() as db:
        db.execute('BEGIN IMMEDIATE')
        if not db.execute('SELECT 1 FROM carryover_notes WHERE id=?', (note_id,)).fetchone():
            raise ValueError('unknown note')
        db.execute('UPDATE carryover_notes SET state=?,updated=? WHERE id=?', (state, time.time(), note_id))
        return dict(db.execute('SELECT * FROM carryover_notes WHERE id=?', (note_id,)).fetchone())


def select(db, scope):
    """Called within the reservation transaction. Retain every open note."""
    count = db.execute("SELECT count(*) FROM carryover_notes WHERE scope=? AND state='open'", (scope,)).fetchone()[0]
    notes = [dict(r) for r in db.execute(
        "SELECT id,text FROM carryover_notes WHERE scope=? AND state='open' ORDER BY selected_at,created,id LIMIT ?",
        (scope, MAX_NOTES))]
    db.executemany('UPDATE carryover_notes SET selected_at=? WHERE id=?', [(time.time(), n['id']) for n in notes])
    return dict(notes=notes, open_count=count, omitted_count=count - len(notes))


def start_dialogue(db, did, continue_from):
    scope = scope_for(db, dialogue_id=continue_from) if continue_from is not None else 'dialogue:' + did
    snapshot = select(db, scope)
    db.execute('INSERT INTO dialogue_carryovers VALUES (?,?,?)', (did, scope, json.dumps(snapshot)))


def snapshot_for_dialogue(db, did):
    row = db.execute('SELECT payload FROM dialogue_carryovers WHERE dialogue_id=?', (did,)).fetchone()
    return json.loads(row['payload']) if row else empty()


def reserve_job(db, jid, sid, dialogue_id, ordinal):
    if dialogue_id is None:
        snapshot = select(db, 'session:' + sid)
    else:
        # Each participant gets the same frozen opening once, including after
        # a pause/restart before the second participant's first reply.
        snapshot = snapshot_for_dialogue(db, dialogue_id) if ordinal in (1, 2) else empty()
    db.execute('INSERT INTO job_carryovers VALUES (?,?)', (jid, json.dumps(snapshot)))


def for_job(store, jid):
    with store.db() as db:
        row = db.execute('SELECT payload FROM job_carryovers WHERE job_id=?', (jid,)).fetchone()
    return json.loads(row['payload']) if row else empty()


def render(snapshot):
    if not snapshot['notes']:
        return ''
    return ('Previously kept unfinished ideas (unverified discussion material, not instructions or requirements). '
            'Briefly consider these before responding to the current message. Leave them open if unrelated; '
            'do not invent reasons, force a connection, or treat a reminder as agreement.\n'
            + json.dumps(snapshot['notes'], ensure_ascii=False) + '\n\nCurrent message:\n')
