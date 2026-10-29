from __future__ import annotations

import fcntl
import json
import math
import os
import selectors
import shutil
import signal
import subprocess
import sys
import threading
import tempfile
import time
import tomllib
from pathlib import Path

from .store import ACTIVE, DEFAULT_TIMEOUT, ROOT, Store


def claude_budget():
    raw = os.environ.get("SESSION_BRIDGE_CLAUDE_MAX_BUDGET_USD", "10")
    try:
        value = float(raw)
    except ValueError:
        raise ValueError("SESSION_BRIDGE_CLAUDE_MAX_BUDGET_USD must be positive and finite") from None
    if not math.isfinite(value) or value <= 0:
        raise ValueError("SESSION_BRIDGE_CLAUDE_MAX_BUDGET_USD must be positive and finite")
    return raw


def command(session):
    binary = shutil.which(session["provider"])
    if not binary:
        raise ValueError(f"{session['provider']} CLI is not on PATH")
    if session["provider"] == "codex":
        args = [binary, "-a", "never", "-s", "read-only", "-c", "project_doc_max_bytes=0", "exec"]
        if session["native_id"]:
            args += ["resume", session["native_id"]]
        args += ["--ignore-user-config", "--skip-git-repo-check", "--json"]
        # Load only model/auth-location preferences. Loading all user config
        # would also inherit MCP servers, including this bridge recursively.
        config_path = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "config.toml"
        config = tomllib.loads(config_path.read_text()) if config_path.exists() else {}
        if config.get("model_provider", "openai") != "openai":
            raise ValueError("This MVP supports Codex's OpenAI provider; custom providers need an adapter")
        for key in ("cli_auth_credentials_store", "model_reasoning_effort"):
            if key in config:
                args += ["-c", f"{key}={json.dumps(config[key])}"]
        if session["model"]:
            args += ["--model", session["model"]]
        elif config.get("model"):
            args += ["--model", config["model"]]
        return args + ["-"]
    args = [binary, "--safe-mode", "-p", "--tools", "", "--strict-mcp-config",
            "--mcp-config", '{"mcpServers":{}}', "--output-format", "stream-json",
            "--verbose", "--include-partial-messages", "--permission-mode", "dontAsk", "--max-budget-usd", claude_budget()]
    if session["native_id"]:
        args += ["--resume", session["native_id"]]
    if session["model"]:
        args += ["--model", session["model"]]
    return args


def dispatch(store, session, prompt, request_id, timeout=DEFAULT_TIMEOUT):
    job, fresh = store.reserve(session, prompt, request_id, timeout)
    if fresh:
        try:
            env = os.environ.copy()
            env["SESSION_BRIDGE_HOME"] = str(store.root)
            env["PYTHONPATH"] = str(ROOT)
            with open(store.root / f"{job['id']}.worker.log", "ab") as log:
                worker = subprocess.Popen([sys.executable, "-m", "session_bridge.runner", job["id"]],
                    cwd=store.root, env=env, stdin=subprocess.DEVNULL, stdout=log,
                    stderr=log, start_new_session=True)
                # Reap children while the MCP host lives; a disconnected host
                # does not wait for or terminate its detached workers.
                threading.Thread(target=worker.wait, daemon=True).start()
        except Exception as exc:
            store.update(job["id"], status="failed", error=str(exc))
    return store.public_job(job["id"])


def status(store, job_id):
    job = store.job(job_id)
    # Recover a dead worker conservatively. Never retry its prompt automatically:
    # the provider may have accepted it before the local process disappeared.
    if job["status"] in ACTIVE and time.time() - job["updated"] > 15:
        with open(store.root / f"{job['session_id']}.lock", "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                current = store.job(job_id)
                if current["status"] in ACTIVE and time.time() - current["updated"] > 15:
                    store.update(job_id, status="uncertain", error="Worker disappeared; inspect native history before retrying.")
    return store.public_job(job_id)


def stop_process(process):
    # Graceful interrupt first so native history records the interrupted turn.
    for sig, grace in ((signal.SIGINT, 3), (signal.SIGTERM, 2), (signal.SIGKILL, 1)):
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            pass


class Events:
    def __init__(self, store, session, job_id):
        self.store, self.session, self.job_id = store, session, job_id
        self.response, self.error, self.completed = "", None, False
        self.native_id = session["native_id"]
        self.native_id_observed = False
        self.last_flush = 0
        self.progress = {"phase": "starting", "events_received": 0, "thinking_deltas": 0,
                         "text_deltas": 0, "answer_chars": 0, "retry_events": 0}

    def flush(self, force=False):
        if force or time.monotonic() - self.last_flush >= 1:
            self.store.save_progress(self.job_id, self.progress)
            self.store.update(self.job_id, response=self.response, error=self.error)
            self.last_flush = time.monotonic()

    def observe(self, event):
        # Intentionally discard text, thinking, signatures, tool inputs, and raw
        # events. These counters distinguish progress from the worker heartbeat.
        now = time.time()
        p = self.progress
        p.setdefault("first_event_at", now)
        p["last_event_at"] = now
        p["events_received"] += 1
        kind = event.get("type")
        if kind in ("thread.started", "system") and p["phase"] == "starting":
            p["phase"] = "waiting_for_response"
        if kind == "system" and event.get("subtype") == "api_retry":
            p["phase"] = "retrying"
            p["retry_events"] += 1
        if kind == "stream_event":
            detail = event.get("event", {})
            event_type = detail.get("type")
            if event_type == "message_start":
                p.setdefault("first_response_at", now)
                p["phase"] = "responding"
            if event_type == "content_block_start":
                block_type = detail.get("content_block", {}).get("type")
                if block_type in ("thinking", "redacted_thinking"):
                    p["phase"] = "thinking"
                elif block_type == "text":
                    p["phase"] = "writing"
            if event_type == "content_block_delta":
                delta = detail.get("delta", {})
                if delta.get("type") == "thinking_delta":
                    p["thinking_deltas"] += 1
                    p["phase"] = "thinking"
                    p["last_content_at"] = now
                elif delta.get("type") == "text_delta":
                    p["text_deltas"] += 1
                    p["answer_chars"] += len(delta.get("text", ""))
                    p["phase"] = "writing"
                    p["last_content_at"] = now
        if kind in ("assistant", "item.completed"):
            p.setdefault("first_response_at", now)
        if kind in ("result", "turn.completed", "turn.failed"):
            p["phase"] = "result_received"
            for key in ("duration_ms", "duration_api_ms"):
                if isinstance(event.get(key), (int, float)):
                    p[key] = event[key]

    def timeout_error(self, timeout):
        p = self.progress
        age = "none" if not p.get("last_event_at") else f"{time.time() - p['last_event_at']:.1f}s ago"
        return (f"Provider exceeded {timeout:g}s; last phase={p['phase']}, "
                f"events={p['events_received']}, thinking_deltas={p['thinking_deltas']}, "
                f"answer_chars={p['answer_chars']}, last event={age}. "
                "No completed turn; not retried automatically.")

    def accept(self, event):
        previous_phase = self.progress["phase"]
        self.observe(event)
        kind = event.get("type")
        native = event.get("thread_id") if kind == "thread.started" else None
        if self.session["provider"] == "claude":
            native = event.get("session_id")
        if native:
            self.native_id_observed = True
        if native and native != self.native_id:
            self.store.set_native(self.session["id"], native)
            self.native_id = native
        if kind == "item.completed" and event.get("item", {}).get("type") == "agent_message":
            self.response = event["item"]["text"]
        if kind == "turn.completed":
            self.completed = True
        if kind == "turn.failed":
            self.error = json.dumps(event.get("error", event), ensure_ascii=False)
        if kind == "result":
            self.response = event.get("result", "")
            self.completed = not event.get("is_error", False) and event.get("subtype") == "success"
            if not self.completed:
                self.error = self.response or json.dumps(event.get("errors", event), ensure_ascii=False)
        self.flush(force=previous_phase != self.progress["phase"] or kind in ("result", "turn.completed", "turn.failed"))


def run(store, job_id):
    job = store.job(job_id)
    session = store.session(job["session_id"])
    with open(store.root / f"{session['id']}.lock", "a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        if store.job(job_id)["status"] != "queued":
            return
        store.update(job_id, status="running")
        if store.job(job_id)["cancel"]:
            store.update(job_id, status="interrupted")
            return
        process = None
        events = Events(store, session, job_id)
        events.flush(force=True)
        final_status = None
        try:
            env = os.environ.copy()
            env.pop("CLAUDECODE", None)
            # Explicit opt-in lets a caller choose local subscription auth over
            # an inherited API key. Never read or copy credential files.
            if env.get("SESSION_BRIDGE_CLAUDE_AUTH") == "subscription":
                env.pop("ANTHROPIC_API_KEY", None)
                env.pop("ANTHROPIC_AUTH_TOKEN", None)
            if env.get("SESSION_BRIDGE_CODEX_AUTH") == "subscription":
                env.pop("OPENAI_API_KEY", None)
                env.pop("CODEX_API_KEY", None)
            first = not session["native_id"]
            prefix = ("You are a continuing discussion partner. Answer the message directly. "
                      "Do not use tools, modify files, or invoke another agent. "
                      "Messages here are supplied by the bridge caller, not necessarily a human.\n"
                      + session["instructions"] + "\n\n") if first else ""
            prompt = prefix + job["prompt"]
            # A regular temporary file avoids blocking on a full stdin pipe before
            # the supervised timeout begins when a provider never reads stdin.
            with tempfile.TemporaryFile() as stdin, open(store.root / f"{job_id}.stderr", "wb") as stderr:
                stdin.write(prompt.encode())
                stdin.seek(0)
                process = subprocess.Popen(command(session), cwd=session["cwd"], env=env,
                    stdin=stdin, stdout=subprocess.PIPE, stderr=stderr, start_new_session=True)
                selector = selectors.DefaultSelector()
                selector.register(process.stdout, selectors.EVENT_READ)
                deadline, heartbeat, pending = time.monotonic() + job["timeout"], 0, b""
                output_bytes = 0
                try:
                    while selector.get_map():
                        now = time.monotonic()
                        if store.job(job_id)["cancel"]:
                            final_status = "interrupted"
                            break
                        if now >= deadline:
                            final_status = "timed_out"
                            break
                        if now - heartbeat >= 2:
                            events.flush()
                            store.update(job_id)
                            heartbeat = now
                        for key, _ in selector.select(0.2):
                            chunk = os.read(key.fd, 65536)
                            if not chunk:
                                selector.unregister(key.fileobj)
                                break
                            output_bytes += len(chunk)
                            if output_bytes > 8 * 1024 * 1024:
                                raise ValueError("provider output exceeded 8 MiB")
                            pending += chunk
                            while b"\n" in pending:
                                line, pending = pending.split(b"\n", 1)
                                if line.strip():
                                    events.accept(json.loads(line))
                    if pending.strip() and final_status is None:
                        events.accept(json.loads(pending))
                finally:
                    selector.close()
                if final_status:
                    stop_process(process)
                else:
                    try:
                        code = process.wait(timeout=max(0.1, deadline - time.monotonic()))
                    except subprocess.TimeoutExpired:
                        final_status = "timed_out"
                        stop_process(process)
                    else:
                        if events.completed and not events.native_id_observed:
                            events.error = "Provider did not report a native session ID; cannot guarantee continuation."
                        final_status = "completed" if code == 0 and events.completed and not events.error else "failed"
                if final_status == "failed" and not events.error:
                    events.error = "Provider did not complete the turn. " + (store.root / f"{job_id}.stderr").read_text(errors="replace")[-2000:]
        except BaseException as exc:
            final_status, events.error = "failed", str(exc)
        finally:
            if process:
                stop_process(process)
                process.stdout.close()
            if final_status == "timed_out":
                events.error = events.timeout_error(job["timeout"]) + (" " + events.error if events.error else "")
            events.flush(force=True)
            store.update(job_id, status=final_status or "failed", response=events.response, error=events.error)


if __name__ == "__main__":
    os.umask(0o077)
    run(Store(), sys.argv[1])
