"""exploration-budget の契約テスト。CLI を実際に起動して、台帳・hook・runner を確かめる。"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

CLI = Path(__file__).resolve().parents[1] / "bin" / "exploration-budget"
POLICY = "まだ特徴づけていない近傍を増やす。実装は方針の外。"

FAKE_CLAUDE = textwrap.dedent(
    '''
    #!/usr/bin/env python3
    """runner のテスト用の偽 claude。呼び出しを記録し、環境変数の指示で台帳を操作する。"""
    import json, os, subprocess, sys, time
    log = os.environ["FAKE_LOG"]
    with open(log, "a", encoding="utf-8") as f:
        f.write(json.dumps({
            "argv": sys.argv[1:],
            "cap": os.environ.get("CLAUDE_CODE_STOP_HOOK_BLOCK_CAP"),
            "runner": os.environ.get("EXPLORATION_BUDGET_RUNNER"),
            "evaluate": os.environ.get("EXPLORATION_BUDGET_EVALUATE"),
            "disable": os.environ.get("EXPLORATION_BUDGET_DISABLE"),
            "cwd": os.getcwd(),
        }) + "\\n")
    if "--tools" in sys.argv:
        # 評価者として呼ばれた: ツール無し。環境変数の返答をそのまま result に入れて返す
        print(json.dumps({"session_id": "fake-eval", "num_turns": 1, "is_error": False,
                          "total_cost_usd": 0.002,
                          "result": os.environ.get("FAKE_EVAL_REPLY", '{"rejections": []}')}))
        sys.exit(0)
    n = sum(1 for _ in open(log, encoding="utf-8"))
    action = os.environ.get("FAKE_ACTION", "touch")
    cli = os.environ["FAKE_CLI"]
    if action == "touch":
        quiet = {"stdout": subprocess.DEVNULL, "check": True}
        subprocess.run([sys.executable, cli, "touch", "item-%d" % n], **quiet)
        subprocess.run([sys.executable, cli, "checkpoint", "--note", "round %d" % n], **quiet)
    elif action == "end":
        subprocess.run([sys.executable, cli, "end", "--reason", "fake blocker"], stdout=subprocess.DEVNULL, check=True)
    elif action == "fail":
        sys.exit(1)
    time.sleep(float(os.environ.get("FAKE_SLEEP", "0.6")))
    print(json.dumps({"session_id": "fake-1", "num_turns": 2, "is_error": False,
                      "total_cost_usd": 0.01, "result": "ok"}))
    '''
).strip() + "\n"


class Base(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.home = root / "data"
        self.project = root / "project"
        (self.project / "sub").mkdir(parents=True)
        self.other = root / "other"
        self.other.mkdir()
        self.now = 1_000_000

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def env(self, *, fixed_now: bool = True, **extra: str) -> dict:
        env = {k: v for k, v in os.environ.items()
               if not k.startswith("EXPLORATION_BUDGET") and k != "CLAUDE_CODE_STOP_HOOK_BLOCK_CAP"}
        env["EXPLORATION_BUDGET_HOME"] = str(self.home)
        if fixed_now:
            env["EXPLORATION_BUDGET_NOW"] = str(self.now)
        env.update(extra)
        return env

    def cli(self, *args: str, stdin: str | None = None, env: dict | None = None,
            cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess:
        proc = subprocess.run([sys.executable, str(CLI), *args], input=stdin, capture_output=True,
                              text=True, env=env or self.env(), cwd=str(cwd or self.project))
        if check:
            self.assertEqual(proc.returncode, 0, f"{args}\nstdout: {proc.stdout}\nstderr: {proc.stderr}")
        return proc

    def start(self, budget: str = "60m", *extra: str) -> subprocess.CompletedProcess:
        return self.cli("start", "--budget", budget, "--policy", POLICY, *extra)

    def hook(self, event: str, *, cwd: Path | None = None, env: dict | None = None,
             **payload_extra) -> subprocess.CompletedProcess:
        payload = {"cwd": str(cwd or self.project), "session_id": "csid-1",
                   "stop_hook_active": False, "hook_event_name": "Stop"}
        payload.update(payload_extra)
        return self.cli("hook", event, stdin=json.dumps(payload), env=env)

    def status_json(self) -> dict:
        return json.loads(self.cli("status", "--json").stdout)

    def report_json(self) -> dict:
        return json.loads(self.cli("report", "--json").stdout)


class BudgetParsing(Base):
    def test_budget_forms(self) -> None:
        for text, seconds in (("60m", 3600), ("1h30m", 5400), ("45s", 45), ("90", 5400)):
            self.start(text)
            self.assertEqual(self.status_json()["progress"]["budget"], seconds, text)
            self.cli("end", "--reason", "next")

    def test_invalid_budget(self) -> None:
        proc = self.cli("start", "--budget", "abc", "--policy", POLICY, check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("予算を解釈できない", proc.stderr)

    def test_policy_required(self) -> None:
        proc = self.cli("start", "--budget", "60m", check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("方針が空", proc.stderr)


class Sessions(Base):
    def test_second_start_is_refused(self) -> None:
        self.start()
        proc = self.cli("start", "--budget", "30m", "--policy", POLICY, check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("active", proc.stderr)

    def test_novelty_spans_sessions_and_verdicts(self) -> None:
        self.start()
        self.assertEqual(self.cli("touch", "a", "b").stdout, "novel\ta\nnovel\tb\n")
        self.assertEqual(self.cli("touch", "a").stdout, "seen\ta\n")
        self.cli("end", "--reason", "done")
        self.start()
        self.assertEqual(self.cli("touch", "a", "c").stdout, "seen\ta\nnovel\tc\n")
        self.cli("verdict", "known", "d")
        self.assertEqual(self.cli("touch", "d").stdout, "seen\td\n")
        self.assertEqual(self.report_json()["unjudged_novel"], ["c"])

    def test_similar_paths_get_separate_ledgers(self) -> None:
        dash = self.project / "a-b"
        underscore = self.project / "a_b"
        dash.mkdir()
        underscore.mkdir()
        self.cli("start", "--budget", "60m", "--policy", POLICY, cwd=dash)
        self.cli("start", "--budget", "60m", "--policy", POLICY, cwd=underscore, )
        self.assertEqual(len(list((self.home / "active").glob("*.json"))), 2)
        self.cli("touch", "shared", cwd=dash)
        self.assertEqual(self.cli("touch", "shared", cwd=underscore).stdout, "novel\tshared\n",
                         "別の台帳なので既出にならない")
        out = json.loads(self.hook("stop", cwd=underscore).stdout)
        self.assertEqual(out["decision"], "block")
        report = json.loads(self.cli("report", "--json", cwd=underscore).stdout)
        self.assertEqual(Path(report["session"]["project_dir"]).resolve(), underscore.resolve())

    def test_report_verdict_instruction_matches_parser(self) -> None:
        self.start()
        self.cli("touch", "n1")
        report = self.cli("report").stdout
        self.assertIn("verdict known|unknown|rejected|deferred <id>", report)
        self.assertNotIn("verdict <id> known", report)
        self.cli("verdict", "known", "n1")
        self.assertEqual(self.report_json()["unjudged_novel"], [])

    def test_verdict_if_new_skips_seen_entities(self) -> None:
        self.cli("verdict", "known", "a")
        out = json.loads(self.cli("verdict", "rejected", "--if-new", "--json", "a", "b", "c").stdout)
        self.assertEqual(out["recorded"], ["b", "c"])
        self.assertEqual(out["skipped"], ["a"])
        self.start()
        self.cli("touch", "d")
        text = self.cli("verdict", "deferred", "--if-new", "d", "e").stdout
        self.assertIn("記録 1 / 既出で省略 1", text)
        self.assertEqual(self.cli("touch", "a", "b", "e").stdout, "seen\ta\nseen\tb\nseen\te\n")
        dup = json.loads(self.cli("verdict", "known", "--if-new", "--json", "f", "f").stdout)
        self.assertEqual((dup["recorded"], dup["skipped"]), (["f"], ["f"]), "同じ呼び出し内の重複も 1 回だけ記録する")

    def test_checkpoint_closes_interval(self) -> None:
        self.start()
        self.cli("touch", "x")
        self.cli("artifact", "out/report.md", "--kind", "report")
        self.cli("checkpoint", "--note", "first")
        delta = json.loads(self.cli("delta", "--json").stdout)
        self.assertEqual((delta["touches"], delta["novel"], delta["artifacts"]), (0, 0, 0))
        self.cli("touch", "y")
        delta = json.loads(self.cli("delta", "--json").stdout)
        self.assertEqual((delta["touches"], delta["novel"]), (1, 1))
        intervals = self.report_json()["intervals"]
        self.assertEqual(len(intervals), 1)
        self.assertEqual((intervals[0]["touches"], intervals[0]["novel"], intervals[0]["artifacts"]), (1, 1, 1))

    def test_checkpoint_json_returns_id_and_closed_interval(self) -> None:
        self.start()
        self.cli("touch", "x")
        proc = self.cli("checkpoint", "--json", "--note", "x")
        data = json.loads(proc.stdout)  # 人向けの行が混ざっていれば読めない
        self.assertIsInstance(data["checkpoint_id"], int)
        self.assertEqual((data["closed"]["touches"], data["closed"]["novel"], data["closed"]["artifacts"]), (1, 1, 0))
        self.assertIsNone(data["evaluation"], "評価者を呼んでいなければ null")
        self.assertEqual(self.report_json()["intervals"][0]["note"], "x", "台帳への記録は人向けの形と同じ")

    def test_report_lists_each_artifact_once(self) -> None:
        self.start()
        self.cli("artifact", "out/a.md", "--kind", "draft")
        self.cli("artifact", "out/a.md", "--kind", "final")
        self.cli("artifact", "out/b.md")
        report = self.cli("report").stdout
        self.assertEqual(report.count("成果物 out/a.md"), 1)
        self.assertIn("成果物 out/a.md (final)", report)
        self.assertIn("成果物 out/b.md", report)

    def test_end_by_agent_is_visible_in_report(self) -> None:
        self.start("100s")
        env = self.env(EXPLORATION_BUDGET_RUNNER="1")
        env["EXPLORATION_BUDGET_NOW"] = str(self.now + 37)
        self.cli("end", "--reason", "ブラウザが開けない", env=env)
        report = self.cli("report").stdout
        self.assertIn("エージェントが 37% の時点で終了した: ブラウザが開けない", report)


class StopHook(Base):
    def test_blocks_with_facts_policy_and_instructions(self) -> None:
        self.start()
        out = json.loads(self.hook("stop").stdout)
        self.assertEqual(out["decision"], "block")
        reason = out["reason"]
        self.assertIn("残り 1時間", reason)
        self.assertIn(POLICY, reason)
        self.assertIn("touch", reason)
        self.assertIn("台帳は空", reason)
        for word in ("急", "早く", "hurry"):
            self.assertNotIn(word, reason)
        session = self.status_json()["session"]
        self.assertEqual(session["blocks"], 1)
        self.assertEqual(session["claude_session_id"], "csid-1")

    def test_keeps_blocking_when_stop_hook_active(self) -> None:
        self.start()
        self.hook("stop")
        out = json.loads(self.hook("stop", stop_hook_active=True).stdout)
        self.assertEqual(out["decision"], "block")
        self.assertEqual(self.status_json()["session"]["blocks"], 2)

    def test_silent_without_session(self) -> None:
        self.assertEqual(self.hook("stop").stdout, "")

    def test_matches_subdirectory_and_ignores_other_dirs(self) -> None:
        self.start()
        self.assertIn('"block"', self.hook("stop", cwd=self.project / "sub").stdout)
        self.assertEqual(self.hook("stop", cwd=self.other).stdout, "")

    def test_allows_after_budget_and_records_reason(self) -> None:
        self.start("45s")
        env = self.env()
        env["EXPLORATION_BUDGET_NOW"] = str(self.now + 46)
        self.assertEqual(self.hook("stop", env=env).stdout, "")
        report = self.cli("report").stdout
        self.assertIn("ended (budget)", report)
        self.assertNotIn("エージェントが", report)

    def test_yield_collapse_counts_only_explored_checkpoints(self) -> None:
        self.start("60m", "--yield-window", "2")
        for _ in range(3):
            self.cli("checkpoint")
        self.assertIn('"block"', self.hook("stop").stdout, "空の台帳では収率ゼロと見なさない")
        self.cli("touch", "a")
        self.cli("checkpoint")
        self.assertIn('"block"', self.hook("stop").stdout, "直近の探索した区切りに新規がある")
        for _ in range(3):
            self.cli("checkpoint")  # 反証・整理・報告: 触れていない区切りは数えない
        self.assertIn('"block"', self.hook("stop").stdout, "触れていない区切りでは収率を測れない")
        self.cli("touch", "a")
        self.cli("checkpoint")  # 探索したが既出だけ
        self.cli("touch", "a", "b")
        self.cli("checkpoint")  # b は新規なので窓が途切れる
        self.assertIn('"block"', self.hook("stop").stdout)
        self.cli("touch", "b")
        self.cli("checkpoint")
        self.cli("checkpoint")  # 触れていない区切り（数えない）
        self.cli("touch", "a")
        self.cli("checkpoint")
        self.assertEqual(self.hook("stop").stdout, "", "探索した直近 2 区切りが新規 0 で外側が止める")
        self.assertIn("ended (yield)", self.cli("report").stdout)

    def test_report_lists_candidates_not_population(self) -> None:
        self.start()
        self.cli("touch", "pop-1", "pop-2", "pop-3", "--kind", "considered")
        self.cli("touch", "cand-1", "cand-2", "--kind", "candidate")
        report = self.cli("report").stdout
        self.assertIn("未判定の候補 2 件: cand-1, cand-2", report)
        self.assertNotIn("pop-1", report)
        self.assertIn("候補以外の新規 3 件は一覧に出さない", report)
        self.assertIn("触れた対象の種類: considered 3 / candidate 2", report)
        data = self.report_json()
        self.assertEqual(data["unjudged_candidates"], ["cand-1", "cand-2"])
        self.assertEqual(len(data["unjudged_novel"]), 5)
        self.assertEqual(data["touch_kinds"], {"considered": 3, "candidate": 2})

    def test_reclassified_candidate_stays_in_candidate_list(self) -> None:
        self.start()
        self.cli("touch", "x", "y", "--kind", "considered")
        self.cli("touch", "x", "--kind", "candidate")  # 再分類。2 行目は seen なので novel=0
        report = self.cli("report").stdout
        self.assertIn("未判定の候補 1 件: x", report)
        self.assertNotIn("未判定の候補 1 件: y", report)
        data = self.report_json()
        self.assertEqual(data["unjudged_candidates"], ["x"])
        self.assertEqual(sorted(data["unjudged_novel"]), ["x", "y"])

    def test_fully_judged_candidates_do_not_fall_back_to_population(self) -> None:
        self.start()
        self.cli("touch", "pop-1", "pop-2", "--kind", "considered")
        self.cli("touch", "cand-1", "--kind", "candidate")
        self.cli("verdict", "known", "cand-1")
        report = self.cli("report").stdout
        self.assertIn("未判定の候補なし", report)
        self.assertNotIn("pop-1", report)
        self.assertIn("候補以外の新規 2 件は一覧に出さない", report)
        self.assertEqual(self.report_json()["unjudged_candidates"], [])

    def test_report_falls_back_to_all_novel_without_candidate_kind(self) -> None:
        self.start()
        self.cli("touch", "x", "y")
        report = self.cli("report").stdout
        self.assertIn("未判定の新規対象 2 件: x, y", report)

    def test_block_cap(self) -> None:
        self.start("60m", "--max-blocks", "2")
        self.hook("stop")
        self.hook("stop")
        self.assertEqual(self.hook("stop").stdout, "")
        self.assertIn("ended (cap)", self.cli("report").stdout)

    def test_disable_switch(self) -> None:
        self.start()
        self.assertEqual(self.hook("stop", env=self.env(EXPLORATION_BUDGET_DISABLE="1")).stdout, "")
        self.assertEqual(self.status_json()["session"]["blocks"], 0)

    def test_garbage_stdin_is_fail_open(self) -> None:
        self.start()
        proc = self.cli("hook", "stop", stdin="not json")
        self.assertEqual(proc.returncode, 0)


class PostToolHook(Base):
    def test_thresholds_announce_once(self) -> None:
        self.start("100s")
        env = self.env()
        env["EXPLORATION_BUDGET_NOW"] = str(self.now + 20)
        self.assertEqual(self.hook("post-tool", env=env).stdout, "")
        env["EXPLORATION_BUDGET_NOW"] = str(self.now + 50)
        out = json.loads(self.hook("post-tool", env=env).stdout)
        self.assertIn("経過 50%", out["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "PostToolUse")
        self.assertEqual(self.hook("post-tool", env=env).stdout, "", "同じしきい値は一度だけ")
        env["EXPLORATION_BUDGET_NOW"] = str(self.now + 85)
        out = json.loads(self.hook("post-tool", env=env).stdout)
        self.assertIn("経過 80%", out["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(self.hook("post-tool", env=env).stdout, "")


class FakeClaudeCase(Base):
    """偽 claude を使うテストの共通部品。テストは持たない。"""

    def setUp(self) -> None:
        super().setUp()
        self.fake = Path(self.tmp.name) / "fake-claude.py"
        self.fake.write_text(FAKE_CLAUDE, encoding="utf-8")
        self.log = Path(self.tmp.name) / "fake.log"

    def run_env(self, action: str = "touch", sleep: str = "0.6") -> dict:
        return self.env(fixed_now=False, FAKE_LOG=str(self.log), FAKE_CLI=str(CLI),
                        FAKE_ACTION=action, FAKE_SLEEP=sleep)

    def calls(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]


class Runner(FakeClaudeCase):
    def test_loops_with_resume_until_budget(self) -> None:
        proc = self.cli("run", "--budget", "2s", "--policy", POLICY, "--claude-cmd",
                        f"{sys.executable} {self.fake}", "--block-cap", "33", env=self.run_env())
        calls = self.calls()
        self.assertGreaterEqual(len(calls), 2, proc.stdout)
        self.assertNotIn("--resume", calls[0]["argv"])
        self.assertIn("--resume", calls[1]["argv"])
        self.assertEqual(calls[1]["argv"][calls[1]["argv"].index("--resume") + 1], "fake-1")
        self.assertEqual(calls[0]["cap"], "33")
        self.assertEqual(calls[0]["runner"], "1")
        self.assertEqual(Path(calls[0]["cwd"]).resolve(), self.project.resolve())
        prompt = calls[0]["argv"][calls[0]["argv"].index("-p") + 1]
        self.assertIn(POLICY, prompt)
        self.assertIn("ended (budget)", proc.stdout)
        report = json.loads(self.cli("report", "--json", env=self.run_env()).stdout)
        self.assertEqual(report["session"]["rounds"], len(calls))
        self.assertEqual(report["totals"]["novel"], len(calls))
        run_dir = self.home / "projects"
        self.assertTrue(any(p.name == "round-1.prompt.md" for p in run_dir.rglob("round-1.prompt.md")))

    def test_stops_when_agent_ends_session(self) -> None:
        proc = self.cli("run", "--budget", "30s", "--policy", POLICY, "--claude-cmd",
                        f"{sys.executable} {self.fake}", env=self.run_env(action="end", sleep="0"))
        self.assertEqual(len(self.calls()), 1)
        self.assertIn("エージェントが", proc.stdout)
        self.assertIn("fake blocker", proc.stdout)

    def test_consecutive_failures_end_the_session(self) -> None:
        proc = self.cli("run", "--budget", "30s", "--policy", POLICY, "--max-failures", "2",
                        "--claude-cmd", f"{sys.executable} {self.fake}",
                        env=self.run_env(action="fail", sleep="0"))
        self.assertEqual(len(self.calls()), 2)
        self.assertIn("ended (error)", proc.stdout)

    def test_dry_run_does_not_call_claude(self) -> None:
        env = self.run_env()
        env["EXPLORATION_BUDGET_NOW"] = str(self.now)  # dry-run は時計を進めないので固定してよい
        proc = self.cli("run", "--budget", "10m", "--policy", POLICY, "--dry-run",
                        "--claude-cmd", f"{sys.executable} {self.fake}", env=env)
        self.assertEqual(self.calls(), [])
        self.assertIn("round 1 のプロンプト", proc.stdout)
        self.assertIn(POLICY, proc.stdout)
        self.assertIn("残り 10分", proc.stdout)
        self.assertIn("台帳は空", proc.stdout)
        status = self.cli("status", env=env, check=False)
        self.assertEqual(status.returncode, 1, "dry-run は session を作らない（次の run が active で止まらない）")
        self.assertEqual(list((self.home / "active").glob("*.json")) if (self.home / "active").exists() else [], [])

    def test_dry_run_with_active_session_shows_real_prompt(self) -> None:
        self.start("30m")
        self.cli("touch", "n1")
        env = self.run_env()
        env["EXPLORATION_BUDGET_NOW"] = str(self.now)
        proc = self.cli("run", "--dry-run", "--claude-cmd", f"{sys.executable} {self.fake}", env=env)
        self.assertIn("引き継ぐ前提", proc.stdout)
        self.assertIn("対象 1 (新規 1)", proc.stdout)
        self.assertEqual(self.calls(), [])

    def test_workdir_is_separate_from_ledger_identity(self) -> None:
        sub = self.project / "sub"
        proc = self.cli("run", "--budget", "1s", "--policy", POLICY, "--project-dir", str(self.project),
                        "--claude-cmd", f"{sys.executable} {self.fake}",
                        env=self.run_env(sleep="0.2"), cwd=sub)
        calls = self.calls()
        self.assertGreaterEqual(len(calls), 1, proc.stdout)
        self.assertEqual(Path(calls[0]["cwd"]).resolve(), sub.resolve(), "claude は起動した cwd で動く")
        report = json.loads(self.cli("report", "--json", env=self.run_env()).stdout)
        self.assertEqual(Path(report["session"]["project_dir"]).resolve(), self.project.resolve(), "台帳は --project-dir")

    def test_workdir_outside_project_dir_is_refused(self) -> None:
        proc = self.cli("run", "--budget", "1s", "--policy", POLICY, "--workdir", str(self.other),
                        "--claude-cmd", f"{sys.executable} {self.fake}", env=self.run_env(), check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("配下ではない", proc.stderr)
        self.assertEqual(self.calls(), [])

    def test_refuses_to_run_over_active_session_without_flag(self) -> None:
        self.start()
        proc = self.cli("run", "--claude-cmd", f"{sys.executable} {self.fake}",
                        env=self.run_env(), check=False)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("--resume-active", proc.stderr)


class Evaluator(FakeClaudeCase):
    def eval_env(self, reply: str | None, **extra: str) -> dict:
        env = self.env(FAKE_LOG=str(self.log), FAKE_CLI=str(CLI), **extra)
        if reply is not None:
            env["FAKE_EVAL_REPLY"] = reply
        return env

    def fake_cmd(self) -> str:
        return f"{sys.executable} {self.fake}"

    def evaluator_calls(self) -> list[dict]:
        return [call for call in self.calls() if "--tools" in call["argv"]]

    def test_evaluate_stores_and_prints_rejections(self) -> None:
        self.start()
        self.cli("touch", "a")
        self.cli("checkpoint", "--note", "実装に手を付けた")
        env = self.eval_env('{"rejections": ["実装に手を付けた → 方針「実装は方針の外」に反する"]}')
        proc = self.cli("evaluate", "--claude-cmd", self.fake_cmd(), env=env)
        self.assertIn("評価（却下のみ）", proc.stdout)
        self.assertIn("実装は方針の外", proc.stdout)
        calls = self.evaluator_calls()
        self.assertEqual(len(calls), 1)
        argv = calls[0]["argv"]
        self.assertIn("--output-format", argv)
        self.assertEqual(argv[argv.index("--tools") + 1], "")
        self.assertIn("--strict-mcp-config", argv)
        self.assertEqual(json.loads(argv[argv.index("--settings") + 1]), {"disableAllHooks": True},
                         "利用者の他の hook も評価者の会話へ割り込ませない")
        self.assertEqual(calls[0]["disable"], "1", "評価者の子では hook を止める")
        prompt = argv[argv.index("-p") + 1]
        self.assertIn(POLICY, prompt)
        self.assertIn("実装に手を付けた", prompt, "直近の checkpoint の note を渡す")
        self.assertIn("評価者で、計画者ではない", prompt)
        data = self.report_json()
        self.assertEqual(len(data["evaluations"]), 1)
        self.assertEqual(data["evaluations"][0]["trigger"], "manual")
        self.assertEqual(data["evaluations"][0]["rejections"], ["実装に手を付けた → 方針「実装は方針の外」に反する"])
        self.assertIsNone(data["evaluations"][0]["checkpoint_id"])

    def test_evaluate_reads_artifacts_and_uses_model_option(self) -> None:
        self.start()
        (self.project / "out").mkdir()
        (self.project / "out" / "REPORT.md").write_text("# 報告\n候補は 2 件。", encoding="utf-8")
        self.cli("artifact", "out/REPORT.md", "--kind", "report")
        self.cli("artifact", "out/missing.md")
        env = self.eval_env('{"rejections": []}')
        proc = self.cli("evaluate", "--json", "--claude-cmd", self.fake_cmd(), "--evaluator-model", "judge-x", env=env)
        row = json.loads(proc.stdout)
        self.assertEqual(row["rejections"], [])
        self.assertEqual(row["model"], "judge-x")
        argv = self.evaluator_calls()[0]["argv"]
        self.assertEqual(argv[argv.index("--model") + 1], "judge-x")
        prompt = argv[argv.index("-p") + 1]
        self.assertIn("候補は 2 件。", prompt, "成果物の本文を渡す")
        self.assertIn("読めない、または存在しない", prompt)

    def test_relative_artifact_resolves_against_recording_cwd(self) -> None:
        self.start()
        sub = self.project / "sub"
        (self.project / "out").mkdir()
        (self.project / "out" / "REPORT.md").write_text("本体側の古い報告", encoding="utf-8")
        (sub / "out").mkdir()
        (sub / "out" / "REPORT.md").write_text("作業ディレクトリ側の報告", encoding="utf-8")
        # --workdir 相当の場所から相対で記録（runner の子と同じく --project-dir は台帳の場所を指す）
        self.cli("artifact", "out/REPORT.md", "--project-dir", str(self.project), cwd=sub)
        proc = self.cli("evaluate", "--claude-cmd", self.fake_cmd(), env=self.eval_env('{"rejections": []}'))
        prompt = self.evaluator_calls()[0]["argv"]
        prompt = prompt[prompt.index("-p") + 1]
        self.assertIn("作業ディレクトリ側の報告", prompt)
        self.assertNotIn("本体側の古い報告", prompt)
        artifacts = self.report_json()["artifacts"]
        self.assertEqual(Path(artifacts[0]["cwd"]).resolve(), sub.resolve())

    def test_large_artifact_is_read_as_capped_prefix(self) -> None:
        self.start()
        (self.project / "out").mkdir()
        big = self.project / "out" / "log.txt"
        big.write_text("x" * 30000 + "\nTAIL-MARKER-END", encoding="utf-8")
        self.cli("artifact", "out/log.txt")
        self.cli("evaluate", "--claude-cmd", self.fake_cmd(), env=self.eval_env('{"rejections": []}'))
        argv = self.evaluator_calls()[0]["argv"]
        prompt = argv[argv.index("-p") + 1]
        self.assertNotIn("TAIL-MARKER-END", prompt, "上限を超えた末尾は渡さない")
        self.assertIn("…（以下省略）", prompt)
        self.assertLess(prompt.count("x"), 6100)

    def test_fenced_json_reply_is_parsed(self) -> None:
        self.start()
        reply = "評価します。\n```json\n{\"rejections\": [\"根拠が 1 件\"]}\n```\n以上です。"
        proc = self.cli("evaluate", "--claude-cmd", self.fake_cmd(), env=self.eval_env(reply))
        self.assertIn("根拠が 1 件", proc.stdout)
        self.assertEqual(self.report_json()["evaluations"][0]["rejections"], ["根拠が 1 件"])

    def test_garbage_reply_means_no_rejections_with_warning(self) -> None:
        self.start()
        proc = self.cli("evaluate", "--claude-cmd", self.fake_cmd(), env=self.eval_env("well, it depends"))
        self.assertIn("却下なし", proc.stdout)
        self.assertIn("解釈できない", proc.stderr)
        row = self.report_json()["evaluations"][0]
        self.assertEqual(row["rejections"], [])
        self.assertEqual(row["raw"], "well, it depends")

    def test_checkpoint_evaluate_links_checkpoint_and_prints_after_line(self) -> None:
        self.start()
        self.cli("touch", "a")
        env = self.eval_env('{"rejections": ["既出の近傍を撫で直した"]}')
        proc = self.cli("checkpoint", "--note", "一巡目", "--evaluate", "--claude-cmd", self.fake_cmd(), env=env)
        lines = [line for line in proc.stdout.splitlines() if line.strip()]
        self.assertTrue(lines[0].startswith("[exploration-budget] checkpoint:"), lines)
        self.assertIn("既出の近傍を撫で直した", proc.stdout)
        data = self.report_json()
        self.assertEqual(data["evaluations"][0]["trigger"], "checkpoint")
        self.assertEqual(data["evaluations"][0]["checkpoint_id"], 1)
        self.cli("touch", "b")
        env["EXPLORATION_BUDGET_EVALUATE"] = "1"
        env["EXPLORATION_BUDGET_CLAUDE_CMD"] = self.fake_cmd()
        self.cli("checkpoint", "--note", "二巡目", env=env)
        data = self.report_json()
        self.assertEqual([e["checkpoint_id"] for e in data["evaluations"]], [1, 2], "環境変数でも同じ")
        self.assertEqual(len(self.evaluator_calls()), 2)

    def test_checkpoint_json_carries_evaluation(self) -> None:
        self.start()
        self.cli("touch", "a")
        env = self.eval_env('{"rejections": ["x"]}')
        proc = self.cli("checkpoint", "--json", "--evaluate", "--claude-cmd", self.fake_cmd(), env=env)
        data = json.loads(proc.stdout)  # 人向けの行も評価の行も混ざらない
        self.assertEqual(data["evaluation"]["rejections"], ["x"])
        self.assertEqual(data["evaluation"]["checkpoint_id"], data["checkpoint_id"])
        self.assertEqual(data["evaluation"]["trigger"], "checkpoint")
        self.assertEqual(len(self.evaluator_calls()), 1)

    def test_compose_carries_latest_rejections_only(self) -> None:
        self.start()
        self.cli("touch", "a")
        self.cli("checkpoint")
        self.cli("evaluate", "--claude-cmd", self.fake_cmd(),
                 env=self.eval_env('{"rejections": ["候補の根拠が 1 件しかない"]}'))
        reason = json.loads(self.hook("stop").stdout)["reason"]
        self.assertIn("前回の評価（却下のみ）", reason)
        self.assertIn("- 候補の根拠が 1 件しかない", reason)
        self.assertLess(reason.index("前回の評価"), reason.index("方針:"), "事実の後、方針の前")
        self.cli("evaluate", "--claude-cmd", self.fake_cmd(), env=self.eval_env('{"rejections": []}'))
        reason = json.loads(self.hook("stop").stdout)["reason"]
        self.assertNotIn("前回の評価", reason)

    def test_steer_line_follows_last_explored_interval(self) -> None:
        self.start()
        self.cli("touch", "a")
        self.cli("checkpoint")
        self.assertNotIn("新規 0。", json.loads(self.hook("stop").stdout)["reason"])
        self.cli("touch", "a")
        self.cli("checkpoint")  # 探索したが既出だけ
        self.cli("checkpoint")  # 整理の区切り（触れていない）は無視する
        reason = json.loads(self.hook("stop").stdout)["reason"]
        self.assertIn("直近の探索した区切りは新規 0。方針に書かれた根の引き直しに従う。", reason)
        self.cli("touch", "b")
        self.cli("checkpoint")
        self.assertNotIn("新規 0。", json.loads(self.hook("stop").stdout)["reason"])

    def test_report_lists_evaluations(self) -> None:
        self.start()
        self.cli("evaluate", "--claude-cmd", self.fake_cmd(), env=self.eval_env('{"rejections": []}'))
        self.cli("evaluate", "--claude-cmd", self.fake_cmd(), env=self.eval_env('{"rejections": ["a", "b"]}'))
        report = self.cli("report").stdout
        self.assertIn("(manual): 却下なし", report)
        self.assertIn("(manual): a / b", report)

    def test_runner_evaluate_on_checkpoint_passes_env_to_child(self) -> None:
        env = self.run_env()
        env["FAKE_EVAL_REPLY"] = '{"rejections": ["round の途中で整理に逃げた"]}'
        proc = self.cli("run", "--budget", "2s", "--policy", POLICY, "--evaluate-on-checkpoint",
                        "--evaluator-model", "judge-y", "--claude-cmd", self.fake_cmd(), env=env)
        calls = self.calls()
        work = [c for c in calls if "--tools" not in c["argv"]]
        self.assertGreaterEqual(len(work), 2, proc.stdout)
        self.assertEqual(work[0]["evaluate"], "1")
        evaluations = self.evaluator_calls()
        self.assertGreaterEqual(len(evaluations), 1, "子の checkpoint が評価者を呼ぶ")
        argv = evaluations[0]["argv"]
        self.assertEqual(argv[argv.index("--model") + 1], "judge-y")
        data = json.loads(self.cli("report", "--json", env=self.run_env()).stdout)
        self.assertTrue(all(e["trigger"] == "checkpoint" for e in data["evaluations"]))
        self.assertEqual(data["evaluations"][0]["rejections"], ["round の途中で整理に逃げた"])
        second_prompt = work[1]["argv"][work[1]["argv"].index("-p") + 1]
        self.assertIn("前回の評価（却下のみ）", second_prompt, "次の round の文面に却下理由が載る")
        self.assertIn("round の途中で整理に逃げた", second_prompt)

    def test_runner_evaluate_on_round(self) -> None:
        env = self.run_env()
        env["FAKE_EVAL_REPLY"] = '{"rejections": []}'
        proc = self.cli("run", "--budget", "2s", "--policy", POLICY, "--evaluate-on-round",
                        "--claude-cmd", self.fake_cmd(), env=env)
        self.assertIn("評価 却下 0 件", proc.stdout)
        data = json.loads(self.cli("report", "--json", env=self.run_env()).stdout)
        self.assertGreaterEqual(len(data["evaluations"]), 1)
        self.assertTrue(all(e["trigger"] == "round" for e in data["evaluations"]))


if __name__ == "__main__":
    unittest.main()
