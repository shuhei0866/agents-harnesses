from __future__ import annotations

import asyncio
import os
from typing import Literal

from mcp.server.fastmcp import FastMCP
from .runner import dispatch, status
from .store import ACTIVE, DEFAULT_TIMEOUT, Store
from . import dialogue

mcp = FastMCP("local-sessions", instructions=(
    "Consult a persistent Codex or Claude Code partner when another perspective helps compare "
    "designs, challenge an important assumption, or unblock a stalled investigation. Follow the "
    "caller's standing authorization; proactive consultation does not need a fresh explicit "
    "invocation. Reuse a partner for the same project and topic; skip trivial work. "
    "Share unfinished ideas and follow up on results when useful; verify advice. "
    "Use agent_create once, "
    "then agent_send repeatedly with the same session name. Each send needs a new request_id; "
    "reuse it only to retry the exact same send. Poll agent_status until completed. "
    "For an explicitly requested bounded discussion, use dialogue_start with a topic and limits. "
    "Keep polling dialogue_status with its next_cursor and share meaningful new ideas, disagreements, "
    "and changed assumptions while doing independent work between polls. "
    "Do not build recursive or open-ended relay loops. "
    "These are bridge-owned CLI sessions, not the caller's currently open chat."), log_level="WARNING")


@mcp.tool()
def agent_create(name: str, provider: Literal["codex", "claude"], model: str | None = None,
                 cwd: str | None = None, instructions: str = "") -> dict:
    """Create a named discussion partner. No model call yet. Default cwd is a new empty directory.

    model is optional: omit to use the CLI default, or use an explicitly requested model
    available to the authenticated account. No tools are enabled for Claude; Codex uses read-only mode.
    """
    return Store().create(name, provider, model, cwd, instructions)


@mcp.tool()
def agent_list() -> dict:
    """List the bridge's named sessions and native session IDs, across MCP restarts."""
    return {"sessions": Store().sessions()}


@mcp.tool()
def agent_send(session: str, prompt: str, request_id: str, timeout_seconds: int = DEFAULT_TIMEOUT) -> dict:
    """Send one message; return a job ID immediately. Resumes the native conversation.

    Use the name or bridge session ID. One active send per session. Same request_id
    and prompt returns the previous job without a second model call. Workers keep
    running when the MCP client disconnects, up to timeout_seconds (5-600, default 600).
    Keep polling agent_status; deep reasoning may take several minutes.
    """
    return dispatch(Store(), session, prompt, request_id, timeout_seconds)


@mcp.tool()
async def agent_status(job_id: str, wait_seconds: int = 0) -> dict:
    """Read a job's result, optionally waiting up to 30 seconds. Only completed is success.

    uncertain means the worker disappeared; inspect native history before retrying.
    failed, interrupted and timed_out never cause automatic resubmission.
    progress reports provider event timings and counters, never thinking text.
    updated is a worker heartbeat, not evidence of provider progress.
    """
    store = Store()
    deadline = asyncio.get_running_loop().time() + max(0, min(30, wait_seconds))
    while True:
        result = status(store, job_id)
        if result["status"] not in ACTIVE or asyncio.get_running_loop().time() >= deadline:
            return result
        await asyncio.sleep(0.25)


@mcp.tool()
def agent_interrupt(job_id: str) -> dict:
    """Request cancellation of a running job. Use agent_status to confirm it stopped."""
    store = Store()
    result = status(store, job_id)
    if result["status"] in ACTIVE:
        store.update(job_id, cancel=1)
        result["cancellation_requested"] = True
    return result


@mcp.tool()
def agent_history(session: str, limit: int = 10) -> dict:
    """Read the bridge's most recent sent messages and results (maximum 100)."""
    return {"messages": Store().history(session, limit)}



@mcp.tool()
def dialogue_start(topic: str, max_rounds: int, time_budget_seconds: int, request_id: str,
                   codex_model: str | None = None, claude_model: str | None = None,
                   turn_timeout_seconds: int = DEFAULT_TIMEOUT) -> dict:
    """Start an explicitly authorized bounded Codex/Claude dialogue; return without waiting.

    Creates two dedicated native conversations and resumes them on every turn.
    One round is one Codex reply then one Claude reply. Limits: 1-50 rounds,
    10-14400 active seconds (pauses excluded), 5-600 seconds per reply.
    Calls use the CLIs' existing auth/quota; there is no combined dollar cap.
    Supply only a topic safe to share with BOTH providers. Existing chats are not imported.
    Retry the same start with the same request_id and identical parameters.
    Model defaults come from each CLI; set only a model authorized by the user.
    """
    return dialogue.start(Store(), topic, max_rounds, time_budget_seconds, request_id,
                          codex_model, claude_model, turn_timeout_seconds)


@mcp.tool()
async def dialogue_status(dialogue_id: str, after_turn: int = 0, limit: int = 20,
                          wait_seconds: int = 0) -> dict:
    """Read progress and paginated finished replies, including reported usage/cache counts.

    Use next_cursor as after_turn on the next call. In-flight replies do not
    advance the cursor. completed means the round limit was reached, not that
    an idea is correct. Codex tokens and Claude cost snapshots are session-cumulative; do not sum them.
    A missing token count is unknown, not zero. Wait at most 30 seconds.
    """
    store = Store()
    deadline = asyncio.get_running_loop().time() + max(0, min(30, wait_seconds))
    while True:
        result = dialogue.inspect(store, dialogue_id, after_turn, limit)
        if result['turns'] or result['status'] not in ACTIVE or asyncio.get_running_loop().time() >= deadline:
            return result
        await asyncio.sleep(.25)


@mcp.tool()
def dialogue_control(dialogue_id: str, action: Literal['pause', 'resume', 'stop']) -> dict:
    """Pause after the current reply, resume with remaining limits, or stop immediately.

    Pause lets the current reply finish and keeps both sessions. Resume uses
    their native histories; it does not restore expired provider caches.
    Stop interrupts the current reply and is terminal. Expired budgets and
    failed/interrupted/uncertain child turns cannot be replayed or auto-retried.
    A lost coordinator can resume only when its linked child is still running
    or completed. Inspect status to confirm any requested stop/pause took effect.
    """
    return dialogue.control(Store(), dialogue_id, action)


def main():
    os.umask(0o077)
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
