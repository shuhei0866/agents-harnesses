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
                        "agent_status", "agent_interrupt", "agent_history",
                        "dialogue_start", "dialogue_status", "dialogue_control"})
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

    async def test_dialogue_pause_resume_across_mcp_reconnect(self):
        from test_dialogue import FIXTURE
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bindir = root / 'bin'; bindir.mkdir()
            for name in ('codex', 'claude'):
                cli = bindir / name
                cli.write_text(FIXTURE); cli.chmod(0o755)
            env = {**os.environ, 'SESSION_BRIDGE_HOME': str(root/'state'),
                'CODEX_HOME': str(root/'config'), 'PATH': str(bindir)+os.pathsep+os.environ['PATH'],
                'DIALOGUE_TEST_CALLS': str(root/'calls.jsonl'), 'DIALOGUE_TEST_DELAY': '1',
                'DIALOGUE_TEST_MODE': ''}
            params = StdioServerParameters(command=sys.executable, args=['-m','session_bridge'], env=env)
            args = dict(topic='Synthetic design discussion',max_rounds=2,time_budget_seconds=40,request_id='dialogue-one')
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as client:
                    await client.initialize()
                    result = await client.call_tool('dialogue_start', args)
                    self.assertFalse(result.isError)
                    first = json.loads(result.content[0].text)
            # A new MCP host can control the independently running coordinator.
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as client:
                    await client.initialize()
                    repeat = await client.call_tool('dialogue_start', args)
                    self.assertEqual(json.loads(repeat.content[0].text)['id'],first['id'])
                    await client.call_tool('dialogue_control',dict(dialogue_id=first['id'],action='pause'))
                    for _ in range(60):
                        result = await client.call_tool('dialogue_status',dict(dialogue_id=first['id']))
                        paused = json.loads(result.content[0].text)
                        if paused['status']=='paused': break
                        await asyncio.sleep(.1)
                    self.assertEqual(paused['status'],'paused',paused)
                    self.assertLess(paused['completed_turns'],4)
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as client:
                    await client.initialize()
                    await client.call_tool('dialogue_control',dict(dialogue_id=first['id'],action='resume'))
                    cursor = 0; turns = []
                    for _ in range(60):
                        result = await client.call_tool('dialogue_status',dict(dialogue_id=first['id'],after_turn=cursor,limit=1,wait_seconds=10))
                        done = json.loads(result.content[0].text)
                        turns.extend(done['turns']); cursor = done['next_cursor']
                        if done['status']=='completed' and not done['has_more']:break
                    self.assertEqual(done['status'],'completed',done)
                    self.assertEqual([t['turn'] for t in turns],[1,2,3,4])
                    self.assertEqual([p['id'] for p in done['participants']],[p['id'] for p in first['participants']])
                    self.assertEqual(turns[-1]['usage']['cache_read_input_tokens'],100)
                    self.assertTrue(all(p['native_id'] for p in done['participants']))


if __name__ == "__main__":
    unittest.main()
