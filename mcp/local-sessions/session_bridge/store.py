from __future__ import annotations

import json
import os
import re
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path

ACTIVE = ("queued", "running")
DEFAULT_TIMEOUT = 600
ROOT = Path(__file__).resolve().parent.parent


def default_state_root():
    override = os.environ.get("SESSION_BRIDGE_HOME")
    if override:
        path = Path(override).expanduser()
        if not path.is_absolute():
            raise ValueError("SESSION_BRIDGE_HOME must be an absolute path")
        return path
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share").expanduser()
    if not data.is_absolute():
        data = Path.home() / ".local" / "share"
    return data / "local-session-bridge"


class Store:
    def __init__(self, root: str | Path | None = None):
        self.root = Path(root if root is not None else default_state_root()).expanduser().resolve()
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.db() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS sessions (
                    id TEXT PRIMARY KEY, name TEXT UNIQUE NOT NULL,
                    provider TEXT NOT NULL, model TEXT, cwd TEXT NOT NULL,
                    instructions TEXT NOT NULL, native_id TEXT, created REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                    request_id TEXT NOT NULL, prompt TEXT NOT NULL,
                    status TEXT NOT NULL, response TEXT NOT NULL DEFAULT '',
                    error TEXT, created REAL NOT NULL, updated REAL NOT NULL,
                    cancel INTEGER NOT NULL DEFAULT 0, timeout REAL NOT NULL,
                    UNIQUE(session_id, request_id)
                );
                CREATE UNIQUE INDEX IF NOT EXISTS one_active_job ON jobs(session_id)
                    WHERE status IN ('queued','running');
                CREATE TABLE IF NOT EXISTS dialogues (
                    id TEXT PRIMARY KEY, request_id TEXT UNIQUE NOT NULL, config TEXT NOT NULL,
                    codex_session TEXT NOT NULL, claude_session TEXT NOT NULL,
                    status TEXT NOT NULL, control TEXT, reason TEXT, error TEXT,
                    remaining_seconds REAL NOT NULL, deadline REAL,
                    created REAL NOT NULL, updated REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS dialogue_participants (
                    session_id TEXT PRIMARY KEY, dialogue_id TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS dialogue_turns (
                    dialogue_id TEXT NOT NULL, ordinal INTEGER NOT NULL,
                    job_id TEXT NOT NULL UNIQUE, deadline REAL NOT NULL, PRIMARY KEY(dialogue_id, ordinal)
                );
                CREATE TABLE IF NOT EXISTS job_usage (
                    job_id TEXT PRIMARY KEY REFERENCES jobs(id), payload TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS job_progress (
                    job_id TEXT PRIMARY KEY REFERENCES jobs(id), payload TEXT NOT NULL
                );
            """)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.root / "registry.sqlite3", timeout=10)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def create(self, name, provider, model=None, cwd=None, instructions=""):
        if not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", name):
            raise ValueError("name must be 1-64 letters, numbers, underscores or hyphens")
        if provider not in ("codex", "claude"):
            raise ValueError("provider must be codex or claude")
        if model is not None and (not model or len(model) > 128):
            raise ValueError("invalid model")
        if len(instructions) > 16000:
            raise ValueError("instructions exceed 16000 characters")
        sid = str(uuid.uuid4())
        if cwd:
            path = Path(cwd).expanduser().resolve()
            if not path.is_dir():
                raise ValueError("cwd must be an existing directory")
        else:
            path = self.root / "workspaces" / sid
            path.mkdir(mode=0o700, parents=True)
        with self.db() as db:
            db.execute("INSERT INTO sessions VALUES (?,?,?,?,?,?,?,?)",
                       (sid, name, provider, model, str(path), instructions, None, time.time()))
        return self.session(sid)

    def session(self, name_or_id):
        with self.db() as db:
            row = db.execute("SELECT * FROM sessions WHERE id=? OR name=?",
                             (name_or_id, name_or_id)).fetchone()
        if row is None:
            raise ValueError("unknown session")
        return dict(row)

    def sessions(self):
        with self.db() as db:
            return [dict(r) for r in db.execute("SELECT s.*, j.id AS active_job_id, j.status AS active_status "
                "FROM sessions s LEFT JOIN jobs j ON s.id=j.session_id "
                "AND j.status IN ('queued','running') ORDER BY s.created")]

    def reserve(self, name_or_id, prompt, request_id, timeout=DEFAULT_TIMEOUT, *, dialogue_id=None, ordinal=None):
        if not prompt or len(prompt) > 32000:
            raise ValueError("prompt must contain 1-32000 characters")
        if not request_id or len(request_id) > 128:
            raise ValueError("request_id must contain 1-128 characters; reuse it only for a retry")
        if not 5 <= timeout <= 600:
            raise ValueError("timeout must be 5-600 seconds")
        session = self.session(name_or_id)
        with self.db() as db:
            db.execute("BEGIN IMMEDIATE")
            owner = db.execute("SELECT dialogue_id FROM dialogue_participants WHERE session_id=?",
                               (session["id"],)).fetchone()
            if owner and owner[0] != dialogue_id:
                raise ValueError("session is owned by a dialogue; use dialogue controls")
            if dialogue_id:
                dialogue = db.execute("SELECT * FROM dialogues WHERE id=?", (dialogue_id,)).fetchone()
                if not owner or owner[0] != dialogue_id or not dialogue:
                    raise ValueError("invalid dialogue participant")
                if dialogue["status"] != "running" or dialogue["control"] is not None:
                    raise ValueError("dialogue is not accepting a new turn")
                if not dialogue["deadline"] or dialogue["deadline"] - time.time() < timeout:
                    raise ValueError("dialogue has insufficient time for this turn")
                count = db.execute("SELECT count(*) FROM dialogue_turns WHERE dialogue_id=?", (dialogue_id,)).fetchone()[0]
                if ordinal != count + 1:
                    raise ValueError("dialogue turn already reserved or out of order")
            old = db.execute("SELECT * FROM jobs WHERE session_id=? AND request_id=?",
                             (session["id"], request_id)).fetchone()
            if old:
                if old["prompt"] != prompt:
                    raise ValueError("request_id was already used with a different prompt")
                return dict(old), False
            active = db.execute("SELECT id FROM jobs WHERE session_id=? AND status IN ('queued','running')",
                                (session["id"],)).fetchone()
            if active:
                raise ValueError(f"session is busy; check job {active['id']}")
            uncertain = db.execute("SELECT id FROM jobs WHERE session_id=? AND status='uncertain'",
                                   (session["id"],)).fetchone()
            if uncertain:
                raise ValueError("session has an uncertain job; inspect native history and use a new partner until recovered")
            jid = str(uuid.uuid4())
            now = time.time()
            db.execute("INSERT INTO jobs(id,session_id,request_id,prompt,status,created,updated,timeout) "
                       "VALUES (?,?,?,?,?,?,?,?)", (jid, session["id"], request_id, prompt, "queued", now, now, timeout))
            if dialogue_id:
                db.execute("INSERT INTO dialogue_turns VALUES (?,?,?,?)", (dialogue_id, ordinal, jid, dialogue["deadline"]))
        return self.job(jid), True

    def job(self, job_id):
        with self.db() as db:
            row = db.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        if row is None:
            raise ValueError("unknown job")
        return dict(row)

    def update(self, job_id, **values):
        allowed = {"status", "response", "error", "cancel"}
        if not values.keys() <= allowed:
            raise ValueError("invalid job fields")
        values["updated"] = time.time()
        with self.db() as db:
            db.execute("UPDATE jobs SET " + ",".join(f"{k}=?" for k in values) + " WHERE id=?",
                       (*values.values(), job_id))

    def set_native(self, session_id, native_id):
        # Refuse accidental switches to an unrelated native conversation.
        uuid.UUID(native_id)
        with self.db() as db:
            old = db.execute("SELECT native_id FROM sessions WHERE id=?", (session_id,)).fetchone()[0]
            if old is not None and old != native_id:
                raise ValueError("provider returned a different native session ID")
            db.execute("UPDATE sessions SET native_id=? WHERE id=?", (native_id, session_id))

    def save_progress(self, job_id, progress):
        # Only runner-created counters/timings go here, never provider payloads.
        with self.db() as db:
            db.execute("INSERT INTO job_progress VALUES (?,?) ON CONFLICT(job_id) "
                       "DO UPDATE SET payload=excluded.payload",
                       (job_id, json.dumps(progress)))

    def progress(self, job_id):
        with self.db() as db:
            row = db.execute("SELECT payload FROM job_progress WHERE job_id=?", (job_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def job_deadline(self, job_id):
        with self.db() as db:
            row = db.execute("SELECT deadline FROM dialogue_turns WHERE job_id=?", (job_id,)).fetchone()
        return row[0] if row else None

    def save_usage(self, job_id, usage):
        with self.db() as db:
            db.execute("INSERT INTO job_usage VALUES (?,?) ON CONFLICT(job_id) "
                       "DO UPDATE SET payload=excluded.payload", (job_id, json.dumps(usage)))

    def usage(self, job_id):
        with self.db() as db:
            row = db.execute("SELECT payload FROM job_usage WHERE job_id=?", (job_id,)).fetchone()
        return json.loads(row[0]) if row else None

    def history(self, session, limit=10):
        sid = self.session(session)["id"]
        with self.db() as db:
            rows = db.execute("SELECT * FROM jobs WHERE session_id=? ORDER BY created DESC LIMIT ?",
                              (sid, max(1, min(100, limit)))).fetchall()
        return [dict(r) | {"usage": self.usage(r["id"])} for r in reversed(rows)]

    def public_job(self, job_id):
        job = self.job(job_id)
        session = self.session(job["session_id"])
        end = time.time() if job["status"] in ACTIVE else job["updated"]
        progress = self.progress(job_id)
        if progress and progress.get("last_event_at"):
            progress["seconds_since_last_event"] = round(max(0, end - progress["last_event_at"]), 1)
        return {k: job[k] for k in ("id", "session_id", "request_id", "status", "response", "error", "created", "updated")} | {
            "native_session_id": session["native_id"], "name": session["name"],
            "timeout_seconds": job["timeout"], "elapsed_seconds": round(end - job["created"], 1),
            "progress": progress, "usage": self.usage(job_id)}
