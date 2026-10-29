from __future__ import annotations

import asyncio
import os
from typing import Literal

from mcp.server.fastmcp import FastMCP
from .runner import dispatch, status
from .store import ACTIVE, DEFAULT_TIMEOUT, Store

mcp = FastMCP("local-sessions", instructions=(
    "Consult a persistent Codex or Claude Code partner when another perspective helps compare "
    "designs, challenge an important assumption, or unblock a stalled investigation. Follow the "
    "caller's standing authorization; proactive consultation does not need a fresh explicit "
    "invocation. Reuse a partner for the same project and topic; skip trivial work. "
    "Start with one exchange, share only necessary context, and verify the advice. "
    "Use agent_create once, "
    "then agent_send repeatedly with the same session name. Each send needs a new request_id; "
    "reuse it only to retry the exact same send. Poll agent_status until completed. "
    "Do not recursively relay messages or run open-ended autonomous discussions. "
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


def main():
    os.umask(0o077)
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
