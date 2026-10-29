import asyncio
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parent.parent


class MCPTests(unittest.IsolatedAsyncioTestCase):
    async def test_reconnect_keeps_same_partner_and_reports_tool_errors(self):
        with tempfile.TemporaryDirectory() as state:
            params = StdioServerParameters(command=sys.executable, args=["-m", "session_bridge"],
                env={**os.environ, "SESSION_BRIDGE_HOME": state})
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as client:
                    await client.initialize()
                    tools = (await client.list_tools()).tools
                    self.assertEqual({t.name for t in tools}, {"agent_create", "agent_list", "agent_send",
                        "agent_status", "agent_interrupt", "agent_history"})
                    send_tool = next(t for t in tools if t.name == "agent_send")
                    self.assertEqual(send_tool.inputSchema["properties"]["timeout_seconds"]["default"], 600)
                    created = await client.call_tool("agent_create", {"name": "test", "provider": "claude"})
                    self.assertFalse(created.isError)
                    sid = json.loads(created.content[0].text)["id"]
                    invalid = await client.call_tool("agent_send", {"session": "absent", "prompt": "hello", "request_id": "one"})
                    self.assertTrue(invalid.isError)
            # A fresh MCP subprocess reads the exact same SQLite registry.
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as client:
                    await client.initialize()
                    result = await client.call_tool("agent_list", {})
                    self.assertEqual(json.loads(result.content[0].text)["sessions"][0]["id"], sid)

    async def test_detached_worker_resume_across_mcp_reconnect(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bindir = root / "bin"
            bindir.mkdir()
            cli = bindir / "codex"
            cli.write_text("""#!/usr/bin/env python3
import json, sys, time
prompt = sys.stdin.read()
assert "--ignore-user-config" in sys.argv and "read-only" in sys.argv and "never" in sys.argv
native = "00000000-0000-4000-8000-000000000001"
resumed = "resume" in sys.argv
if resumed:
    assert sys.argv[sys.argv.index("resume")+1] == native
time.sleep(0.5)
print(json.dumps({"type":"thread.started","thread_id":native}), flush=True)
print(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":"resumed" if resumed else "first"}}), flush=True)
print(json.dumps({"type":"turn.completed"}), flush=True)
""")
            cli.chmod(0o755)
            env = {**os.environ, "SESSION_BRIDGE_HOME": str(root / "state"),
                   "CODEX_HOME": str(root / "config"),
                   "PATH": str(bindir) + os.pathsep + os.environ["PATH"]}
            params = StdioServerParameters(command=sys.executable, args=["-m", "session_bridge"], env=env)
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as client:
                    await client.initialize()
                    await client.call_tool("agent_create", {"name": "discussion", "provider": "codex"})
                    sent = await client.call_tool("agent_send", {"session": "discussion", "prompt": "hello", "request_id": "one"})
                    job = json.loads(sent.content[0].text)
                    self.assertFalse(sent.isError)
            # The original MCP process has exited; the detached worker remains.
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as client:
                    await client.initialize()
                    finished = await client.call_tool("agent_status", {"job_id": job["id"], "wait_seconds": 10})
                    first = json.loads(finished.content[0].text)
                    self.assertEqual(first["status"], "completed", first)
                    self.assertEqual(first["response"], "first")
                    repeat = await client.call_tool("agent_send", {"session": "discussion", "prompt": "hello", "request_id": "one"})
                    self.assertEqual(json.loads(repeat.content[0].text)["id"], job["id"])
                    sent = await client.call_tool("agent_send", {"session": "discussion", "prompt": "followup", "request_id": "two"})
                    job2 = json.loads(sent.content[0].text)
                    finished = await client.call_tool("agent_status", {"job_id": job2["id"], "wait_seconds": 10})
                    second = json.loads(finished.content[0].text)
                    self.assertEqual(second["status"], "completed", second)
                    self.assertEqual(second["response"], "resumed")
                    self.assertEqual(second["native_session_id"], first["native_session_id"])
                    history = await client.call_tool("agent_history", {"session": "discussion"})
                    self.assertEqual(len(json.loads(history.content[0].text)["messages"]), 2)


if __name__ == "__main__":
    unittest.main()
