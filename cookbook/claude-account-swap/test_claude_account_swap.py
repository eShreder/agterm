#!/usr/bin/env python3
"""Regression checks using temporary records and a fake control transport."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location("swap", Path(__file__).with_name("claude-account-swap.py"))
assert spec and spec.loader
swap = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = swap
spec.loader.exec_module(swap)


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.accounts = [swap.Account("Personal", self.root / "personal"),
                         swap.Account("Work", self.root / "work")]
        for account in self.accounts:
            account.config_dir.mkdir()
        self.transcript = self.accounts[0].config_dir / "projects" / "repo" / "conversation.jsonl"
        self.transcript.parent.mkdir(parents=True)
        self.write_turn("hello")
        self.proc = swap.Process(123, 100, 123, 123, "Mon Sep 7 10:00:00 2026", "claude")
        self.env = mock.patch.dict(os.environ, {"PANE_MAP_DIR": str(self.root / "maps"),
                                               "AGT_SESSION_ID": "S", "AGT_WINDOW_ID": "W"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.record = swap.Record(self.transcript, 123, self.proc.started, "conversation")
        swap.write_record("S", "left", self.record)

    def write_turn(self, text: str) -> None:
        self.transcript.write_text(json.dumps({"type": "user", "sessionId": "conversation",
            "cwd": str(self.root), "message": {"content": text}}) + "\n")
        old = time.time() - 60
        os.utime(self.transcript, (old, old))

    def live(self):
        with mock.patch.object(swap, "process_info", return_value=self.proc):
            return swap.live_record("S", self.accounts)


class TestRecords(Fixture):
    def test_live_record_identifies_source_root(self) -> None:
        self.assertEqual((self.record, self.accounts[0]), self.live())

    def test_missing_map_does_not_search_existing_transcript(self) -> None:
        swap.map_path("S", "left").unlink()
        with self.assertRaises(swap.Fail):
            self.live()

    def test_statusline_only_map_is_not_freshness_evidence(self) -> None:
        swap.map_path("S", "left").write_text(str(self.transcript) + "\n")
        with self.assertRaises(swap.Fail):
            self.live()

    def test_dead_reused_and_background_processes_are_rejected(self) -> None:
        for proc in (None, self.proc._replace(started="another start"),
                     self.proc._replace(tpgid=456), self.proc._replace(comm="vim")):
            with self.subTest(proc=proc), mock.patch.object(swap, "process_info", return_value=proc), \
                    self.assertRaises(swap.Fail):
                swap.live_record("S", self.accounts)

    def test_unknown_root_and_session_mismatch_are_rejected(self) -> None:
        with self.assertRaises(swap.Fail), mock.patch.object(swap, "process_info", return_value=self.proc):
            swap.live_record("S", self.accounts[1:])
        swap.write_record("S", "left", self.record._replace(session_id="other"))
        with self.assertRaises(swap.Fail):
            self.live()

    def test_hook_records_direct_manual_launch(self) -> None:
        shell = swap.Process(124, 123, 124, 0, "now", "/bin/sh")
        with mock.patch.object(swap.os, "getppid", return_value=124), \
                mock.patch.object(swap, "process_info", side_effect=[shell, self.proc]), \
                mock.patch.dict(os.environ, {"AGTERM_SESSION_ID": "manual", "AGTERM_PANE": "right"}):
            swap.record_hook({"transcript_path": str(self.transcript), "session_id": "conversation"})
        lines = swap.map_path("manual", "right").read_text().splitlines()
        self.assertEqual(str(self.transcript), lines[0])
        self.assertEqual(123, json.loads(lines[1])["pid"])

    def test_background_hook_does_not_overwrite_map(self) -> None:
        before = swap.map_path("S", "left").read_bytes()
        with mock.patch.object(swap, "process_info", return_value=self.proc._replace(tpgid=456)), \
                mock.patch.dict(os.environ, {"AGTERM_SESSION_ID": "S", "AGTERM_PANE": "left"}):
            swap.record_hook({"transcript_path": str(self.transcript), "session_id": "conversation"})
        self.assertEqual(before, swap.map_path("S", "left").read_bytes())

    def test_account_config_rejects_duplicate_and_overlapping_roots(self) -> None:
        config = self.root / "accounts.json"
        for paths in (["personal", "personal"], ["personal", "personal/nested"]):
            config.write_text(json.dumps([{"label": str(i), "config_dir": str(self.root / path)}
                                          for i, path in enumerate(paths)]))
            with self.assertRaises(swap.Fail):
                swap.load_accounts(config)


class FakeAgt:
    def __init__(self, account) -> None:
        self.account = account
        self.typed = []
        self.foreground = ["claude"]
        self.column = 2

    def node(self, sid):
        return {"cwd": "/tmp", "foreground": self.foreground,
                "foregroundShell": "zsh" if not self.foreground else None}

    def cursor_column(self, sid):
        return self.column

    def pick(self, accounts, current):
        return self.account

    def hud(self, *args, **kwargs):
        pass

    def hud_close(self):
        pass

    def type_line(self, sid, text):
        self.typed.append(text)
        self.foreground = [] if text == "/exit" else ["claude"]


class TestSwap(Fixture):
    def setUp(self) -> None:
        super().setUp()
        self.agt = FakeAgt(self.accounts[1])
        for patch in (mock.patch.object(swap, "Agt", return_value=self.agt),
                      mock.patch.object(swap, "process_info", return_value=self.proc),
                      mock.patch.object(swap, "save_packet", return_value=self.root / "packet.md")):
            patch.start()
            self.addCleanup(patch.stop)

    def run_swap(self, summarizer=lambda digest, cwd: "summary"):
        with mock.patch.object(swap, "summarize", side_effect=summarizer):
            return swap.swap(self.accounts, False)

    def test_cancel_does_not_summarize_or_type(self) -> None:
        self.agt.account = None
        with mock.patch.object(swap, "summarize") as summarize:
            self.assertEqual(0, swap.swap(self.accounts, False))
        summarize.assert_not_called()
        self.assertEqual([], self.agt.typed)

    def test_changed_transcript_after_summary_does_not_quit(self) -> None:
        def summarize(digest, cwd):
            self.write_turn("a later turn that already finished")
            return "summary"
        with self.assertRaisesRegex(swap.Fail, "moved on"):
            self.run_swap(summarize)
        self.assertEqual([], self.agt.typed)

    def test_changed_map_after_summary_does_not_quit(self) -> None:
        def summarize(digest, cwd):
            swap.write_record("S", "left", self.record._replace(session_id="new"))
            return "summary"
        with self.assertRaises(swap.Fail):
            self.run_swap(summarize)
        self.assertEqual([], self.agt.typed)

    def test_draft_or_wrong_program_does_not_quit(self) -> None:
        for foreground, column in ((["claude"], 5), (["cat", "claude"], 2), (["vim"], 2)):
            self.agt.foreground, self.agt.column = foreground, column
            with self.assertRaises(swap.Fail):
                self.run_swap()
            self.assertEqual([], self.agt.typed)

    def test_success_quits_then_launches_selected_config(self) -> None:
        with mock.patch.object(swap, "wait_for_shell", return_value=True), \
                mock.patch.object(swap, "wait_for_agent", return_value=True):
            self.assertEqual(0, self.run_swap())
        self.assertEqual("/exit", self.agt.typed[0])
        self.assertIn("CLAUDE_CONFIG_DIR=", self.agt.typed[1])
        self.assertIn(str(self.accounts[1].config_dir), self.agt.typed[1])

    def test_failed_exit_never_launches(self) -> None:
        with mock.patch.object(swap, "wait_for_shell", return_value=False), self.assertRaises(swap.Fail):
            self.run_swap()
        self.assertEqual(["/exit"], self.agt.typed)


class TestQuoting(Fixture):
    def test_shell_receives_literal_packet_and_config_path(self) -> None:
        payload = self.root / "packet ' with spaces.md"
        payload.write_text('$(touch forbidden) `touch forbidden` "quotes"\nnext line')
        binary = self.root / "fake claude"
        binary.write_text('#!/bin/sh\nprintf "%s\\n%s" "$CLAUDE_CONFIG_DIR" "$1"\n')
        binary.chmod(0o700)
        account = swap.Account("Work", self.root / "config ' $(no)")
        with mock.patch.object(swap, "CLAUDE_BIN", str(binary)):
            line = swap.launch_line(account, str(self.root), payload)
        result = subprocess.run(["/bin/sh", "-c", line], capture_output=True, text=True, check=True)
        self.assertEqual(str(account.config_dir) + "\n" + payload.read_text(), result.stdout)
        self.assertFalse((self.root / "forbidden").exists())

    def test_control_characters_cannot_reach_terminal(self) -> None:
        with self.assertRaises(swap.Fail):
            swap.launch_line(self.accounts[1], "/tmp/repo\nexit", self.root / "p")


class TestStartup(Fixture):
    def test_confirmation_needs_new_process_and_selected_account(self) -> None:
        new = self.record._replace(pid=456, started="new start")
        agt = FakeAgt(self.accounts[1])
        for record, account, expected in ((self.record, self.accounts[1], False),
                                          (new, self.accounts[0], False),
                                          (new, self.accounts[1], True)):
            with self.subTest(record=record, account=account), \
                    mock.patch.object(swap, "live_record", return_value=(record, account)), \
                    mock.patch.object(swap.time, "monotonic", side_effect=[0, 2]), \
                    mock.patch.object(swap.time, "sleep"):
                self.assertEqual(expected, swap.wait_for_agent(
                    agt, "S", self.accounts, self.accounts[1], self.record, 1))

    def test_missing_startup_hook_is_not_success(self) -> None:
        with mock.patch.object(swap, "live_record", side_effect=swap.Fail("missing map")), \
                mock.patch.object(swap.time, "monotonic", side_effect=[0, 2]), \
                mock.patch.object(swap.time, "sleep"):
            self.assertFalse(swap.wait_for_agent(
                FakeAgt(self.accounts[1]), "S", self.accounts, self.accounts[1], self.record, 1))


class TestDigest(Fixture):
    def test_tools_are_dropped_and_worktree_cwd_survives(self) -> None:
        rows = [
            {"type": "user", "message": {"content": "do this"}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": "secret tool output"}]}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "answer"},
                                                          {"type": "tool_use", "input": "tool input"}]}},
            {"type": "system", "cwd": "/tmp/café/worktree"},
        ]
        self.transcript.write_text("\n".join(json.dumps(row) for row in rows))
        entries = swap.read_entries(self.transcript)
        digest = swap.build_digest(entries, 1500, swap.datetime.now(swap.timezone.utc))
        self.assertIn("do this", digest)
        self.assertIn("answer", digest)
        self.assertNotIn("tool", digest)
        self.assertEqual("/tmp/café/worktree", swap.transcript_cwd(entries, "/tmp"))

    def test_final_message_uses_last_completed_agent_message(self) -> None:
        stream = "\n".join(json.dumps({"type": "item.completed",
            "item": {"type": "agent_message", "text": text}}) for text in ["first", "last"])
        self.assertEqual("last", swap.final_message(stream))

    def test_packet_is_context_only_and_private(self) -> None:
        text = swap.carry_over("summary", "Personal", "Work", self.transcript)
        self.assertIn("CONTEXT ONLY", text)
        self.assertIn("wait for the user", text)
        path = swap.save_packet(text)
        self.addCleanup(path.unlink)
        self.assertEqual(0o600, path.stat().st_mode & 0o777)


class TestTransport(unittest.TestCase):
    def test_picker_excludes_source_and_has_no_user_timeout(self) -> None:
        accounts = [swap.Account("One", Path("/one")), swap.Account("Two", Path("/two"))]
        result = subprocess.CompletedProcess([], 0, '{"result":"picked","id":"1"}', "")
        with mock.patch.dict(os.environ, {"AGT_WINDOW_ID": "W"}), \
                mock.patch.object(swap.Agt, "run", return_value=result) as run:
            self.assertEqual(accounts[1], swap.Agt("S").pick(accounts, accounts[0]))
        self.assertEqual([{"id": "1", "label": "Two", "subtitle": "/two"}],
                         json.loads(run.call_args.kwargs["stdin"]))
        self.assertIsNone(run.call_args.kwargs["timeout"])

    def test_ps_parser_reads_identity_without_arguments_or_environment(self) -> None:
        result = subprocess.CompletedProcess([], 0,
            "123 100 123 123 Mon Sep  7 10:00:00 2026 /opt/bin/claude\n", "")
        with mock.patch.object(swap.subprocess, "run", return_value=result) as run:
            process = swap.process_info(123)
        self.assertEqual("Mon Sep 7 10:00:00 2026", process.started)
        self.assertEqual("/opt/bin/claude", process.comm)
        self.assertNotIn("args", run.call_args.args[0][-1])

    def test_a_shell_must_be_observed_before_launch(self) -> None:
        self.assertFalse(swap.at_shell_prompt({}))
        self.assertFalse(swap.at_shell_prompt({"foreground": ["vim"]}))
        self.assertTrue(swap.at_shell_prompt({"foregroundShell": "zsh"}))


if __name__ == "__main__":
    unittest.main()
