#!/usr/bin/env python3
"""Switch the left pane's Claude account, carrying a summary into the new session."""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, NamedTuple

AGTERMCTL = os.environ.get("AGTERMCTL", "agtermctl")
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "claude")
CODEX_BIN = os.environ.get("CODEX_BIN", "codex")
MODEL = os.environ.get("CLAUDE_SWAP_MODEL", "gpt-5.6-luna")
INPUT_COLUMN = 2
BUSY_MTIME_SECONDS = 10
CALL_TIMEOUT = 240
WORKTREE_LIMIT = 4000
MAX_DIGEST_BYTES = 120_000
DETAIL_TRIM = 1500
SUMMARY_PROMPT = (
    "Condense the Claude Code session transcript below into a handoff packet for a DIFFERENT agent "
    "that will pick the work up in the same directory with no other context. Emit markdown with "
    "these bold section titles and nothing else: Goal, Current state, Decisions and constraints, "
    "Files, Next steps, Open questions. Drop a section that has no content rather than padding it. "
    "Be concrete - name the files, branches, commands and numbers the next agent needs, taking "
    "them from the working-tree block where the transcript does not carry them - and never "
    "state anything the transcript does not support; mark what is uncertain as unverified. Do not "
    "use markdown headers, emoji, or an em dash. Keep it under 400 words.\n\nTRANSCRIPT\n"
)


class Fail(RuntimeError):
    """An error that can be shown without a traceback."""


class Account(NamedTuple):
    label: str
    config_dir: Path


class Process(NamedTuple):
    pid: int
    ppid: int
    pgid: int
    tpgid: int
    started: str
    comm: str


class Record(NamedTuple):
    transcript: Path
    pid: int
    started: str
    session_id: str


class Entry(NamedTuple):
    kind: str
    text: str
    at: str
    cwd: str


def plain(text: str) -> str:
    if not text or any(ord(c) < 32 or ord(c) == 127 for c in text):
        raise Fail("a label, path or command is empty or contains control characters")
    return text


def load_accounts(path: Path) -> list[Account]:
    try:
        rows = json.loads(path.read_text())
        if not isinstance(rows, list) or len(rows) < 2:
            raise ValueError("configure at least two accounts")
        accounts = []
        for row in rows:
            label, directory = row["label"], row["config_dir"]
            if not isinstance(label, str) or not isinstance(directory, str):
                raise TypeError("label and config_dir must be strings")
            root = Path(plain(directory)).expanduser()
            if not root.is_absolute() or not root.is_dir():
                raise ValueError("config_dir must name an existing absolute directory (or start with ~)")
            account = Account(plain(label), root.resolve())
            for existing in accounts:
                if label == existing.label or account.config_dir == existing.config_dir \
                        or account.config_dir in existing.config_dir.parents \
                        or existing.config_dir in account.config_dir.parents:
                    raise ValueError("account labels must be unique and directories must not overlap")
            accounts.append(account)
        return accounts
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise Fail(f"cannot read accounts from {path}: {exc}") from exc


def process_info(pid: int) -> Process | None:
    try:
        res = subprocess.run(["ps", "-p", str(pid), "-o", "pid=,ppid=,pgid=,tpgid=,lstart=,comm="],
                             capture_output=True, text=True, timeout=5, check=False,
                             env={**os.environ, "LC_ALL": "C"})
        fields = res.stdout.split(None, 9)
        if res.returncode or len(fields) != 10:
            return None
        return Process(*(int(x) for x in fields[:4]), " ".join(fields[4:9]), fields[9].strip())
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        raise Fail(f"cannot inspect the Claude process: {exc}") from exc


def claude_program(program: str) -> bool:
    if Path(program).name == "claude":
        return True
    binary = shutil.which(CLAUDE_BIN)
    return bool(binary and Path(program).is_absolute()
                and Path(program).resolve() == Path(binary).resolve())


def claude_foreground(argv: Any) -> bool:
    return isinstance(argv, list) and bool(argv) and isinstance(argv[0], str) and claude_program(argv[0])


def map_path(sid: str, pane: str) -> Path:
    if not sid or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-" for c in sid) \
            or pane not in {"left", "right"}:
        raise Fail("invalid session or pane identity")
    return Path(os.environ.get("PANE_MAP_DIR", "/tmp/claude/panes")) / f"{sid}.{pane}"


def write_record(sid: str, pane: str, record: Record) -> None:
    path = map_path(sid, pane)
    path.parent.mkdir(parents=True, exist_ok=True)
    metadata = {"pid": record.pid, "started": record.started, "session_id": record.session_id}
    # The first line stays compatible with transcript readers; replacement publishes both lines together.
    fd, name = tempfile.mkstemp(prefix=".swap-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(str(record.transcript) + "\n" + json.dumps(metadata) + "\n")
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def record_hook(data: Any) -> None:
    sid, pane = os.environ.get("AGTERM_SESSION_ID", ""), os.environ.get("AGTERM_PANE", "left")
    if not sid or pane not in {"left", "right"} or not isinstance(data, dict):
        return
    transcript, session_id = data.get("transcript_path"), data.get("session_id")
    if not isinstance(transcript, str) or not isinstance(session_id, str):
        return
    path = Path(plain(transcript))
    if not path.is_absolute() or path.stem != session_id or path.suffix != ".jsonl":
        return
    pid = os.getppid()
    for _ in range(12):
        proc = process_info(pid)
        if proc is None:
            return
        if claude_program(proc.comm):
            # A nested `claude -p` must not replace the interactive parent's mapping.
            if proc.pid == proc.pgid == proc.tpgid:
                write_record(sid, pane, Record(path.resolve(), proc.pid, proc.started, session_id))
            return
        if proc.ppid <= 1 or proc.ppid == pid:
            return
        pid = proc.ppid


def live_record(sid: str, accounts: list[Account]) -> tuple[Record, Account]:
    try:
        lines = map_path(sid, "left").read_text().splitlines()
        metadata = json.loads(lines[1])
        record = Record(Path(lines[0]).resolve(), int(metadata["pid"]),
                        metadata["started"], metadata["session_id"])
        if record.pid <= 1 or not record.started or record.transcript.stem != record.session_id \
                or record.transcript.suffix != ".jsonl" or not record.transcript.is_file():
            raise ValueError("invalid transcript or process identity")
    except (OSError, IndexError, ValueError, KeyError, TypeError) as exc:
        raise Fail(f"no usable pane map; install the hook in this account and restart Claude: {exc}") from exc
    proc = process_info(record.pid)
    if proc is None or proc.started != record.started or not claude_program(proc.comm) \
            or proc.pid != proc.pgid or proc.pgid != proc.tpgid:
        raise Fail("the pane map belongs to an exited, replaced or background Claude process")
    matches = [a for a in accounts if a.config_dir / "projects" in record.transcript.parents]
    if len(matches) != 1:
        raise Fail("the mapped transcript does not belong to exactly one configured account")
    return record, matches[0]


class Agt:
    def __init__(self, sid: str) -> None:
        self.sid = sid
        self.socket = os.environ.get("AGT_SOCKET") or os.environ.get("AGTERM_SOCKET", "")
        self.window = os.environ.get("AGT_WINDOW_ID") or os.environ.get("AGTERM_WINDOW_ID", "")
        if not self.window:
            raise Fail("the window ID is missing; invoke this from an agterm custom command")

    def run(self, *args: str, stdin: str = "", timeout: float | None = 30) -> subprocess.CompletedProcess[str]:
        command = [AGTERMCTL, *args]
        if self.socket:
            command += ["--socket", self.socket]
        try:
            return subprocess.run(command, input=stdin, capture_output=True, text=True,
                                  check=False, timeout=timeout)
        except (OSError, subprocess.SubprocessError) as exc:
            raise Fail(f"agtermctl {args[0]} failed: {exc}") from exc

    def node(self, sid: str) -> dict[str, Any]:
        res = self.run("tree", "--json", "--window", self.window)
        try:
            node = find_session(json.loads(res.stdout)["result"]["tree"], sid)
        except (ValueError, KeyError, TypeError) as exc:
            raise Fail("cannot read the agterm tree") from exc
        if res.returncode or node is None:
            raise Fail("the session is no longer in this window")
        return node

    def cursor_column(self, sid: str) -> int | None:
        res = self.run("surface", "cursor", "--target", f"surface:{sid}:left", "--json")
        try:
            return int(json.loads(res.stdout)["result"]["cursor"]["column"]) if not res.returncode else None
        except (ValueError, KeyError, TypeError):
            return None

    def hud(self, message: str, detail: str = "", spinner: bool = True) -> None:
        args = ["session", "hud", message, "--target", self.sid, "--detail", detail]
        if spinner:
            args.append("--spinner")
        if self.run(*args, "--pane", "left").returncode:
            self.run(*args)

    def hud_close(self) -> None:
        self.run("session", "hud", "close", "--target", self.sid)

    def pick(self, accounts: list[Account], current: Account) -> Account | None:
        choices = {str(i): account for i, account in enumerate(accounts) if account != current}
        items = [{"id": key, "label": a.label, "subtitle": str(a.config_dir)} for key, a in choices.items()]
        res = self.run("pick", "--prompt", f"Quit {current.label} in the left pane and switch to",
                       "--window", self.window, stdin=json.dumps(items), timeout=None)
        if res.returncode == 2:
            return None
        if res.returncode:
            raise Fail(f"cannot open the account picker: {res.stderr.strip()}")
        try:
            answer = json.loads(res.stdout)
            if answer["result"] != "picked":
                return None
            return choices[answer["id"]]
        except (ValueError, KeyError, TypeError) as exc:
            raise Fail("the account picker returned an unknown choice") from exc

    def type_line(self, sid: str, text: str) -> None:
        res = self.run("session", "type", plain(text), "--target", sid, "--pane", "left")
        if res.returncode:
            raise Fail("cannot type into the left pane")
        time.sleep(0.15)
        res = self.run("session", "type", "--stdin", "--target", sid, "--pane", "left", stdin="\n")
        if res.returncode:
            raise Fail("the line was typed but could not be submitted; inspect the pane before retrying")


def check_pane(agt: Agt, sid: str, transcript: Path) -> dict[str, Any]:
    node = agt.node(sid)
    if not claude_foreground(node.get("foreground")):
        raise Fail("the left pane is not running Claude directly")
    reason = busy_reason(node, transcript, time.time())
    if reason:
        raise Fail(f"not switching: {reason}")
    if agt.cursor_column(sid) != INPUT_COLUMN:
        raise Fail("not switching: the composer holds text or its cursor cannot be read")
    return node


def launch_line(target: Account, cwd: str, path: Path) -> str:
    parts = [plain(x) for x in (cwd, str(target.config_dir), CLAUDE_BIN, str(path))]
    directory, config, binary, packet = map(shlex.quote, parts)
    return f'cd {directory} && env CLAUDE_CONFIG_DIR={config} {binary} "$(cat {packet})"'


def save_packet(text: str) -> Path:
    fd, name = tempfile.mkstemp(prefix="claude-account-swap-", suffix=".md")
    with os.fdopen(fd, "w") as output:
        output.write(text)
    return Path(name)


def wait_for_shell(agt: Agt, sid: str, deadline: float) -> bool:
    while time.monotonic() < deadline:
        if at_shell_prompt(agt.node(sid)):
            return True
        time.sleep(0.5)
    return False


def wait_for_agent(agt: Agt, sid: str, accounts: list[Account], target: Account,
                   previous: Record, deadline: float) -> bool:
    while time.monotonic() < deadline:
        try:
            record, account = live_record(sid, accounts)
            if account == target and (record.pid, record.started) != (previous.pid, previous.started) \
                    and claude_foreground(agt.node(sid).get("foreground")):
                return True
        except Fail:
            pass
        time.sleep(0.5)
    return False


def swap(accounts: list[Account], dry_run: bool) -> int:
    sid = os.environ.get("AGT_SESSION_ID") or os.environ.get("AGTERM_SESSION_ID", "")
    if not sid:
        raise Fail("not inside an agterm session")
    agt = Agt(sid)
    original, current = live_record(sid, accounts)
    node = check_pane(agt, sid, original.transcript)
    if dry_run:
        print(f"left pane: {current.label}; transcript: {original.transcript}")
        print("available destinations: " + ", ".join(a.label for a in accounts if a != current))
        return 0
    target = agt.pick(accounts, current)
    if target is None:
        return 0
    packet = None
    try:
        agt.hud(f"switching to {target.label}", detail=f"summarizing with {MODEL}")
        if live_record(sid, accounts)[0] != original:
            raise Fail("the conversation moved on while the picker was open")
        check_pane(agt, sid, original.transcript)
        baseline = stamp(original.transcript)
        entries = read_entries(original.transcript)
        if stamp(original.transcript) != baseline:
            raise Fail("the transcript changed while it was being read")
        digest = build_digest(entries, DETAIL_TRIM, datetime.now(timezone.utc))
        if not digest.strip():
            raise Fail("the transcript holds no conversation to summarize")
        cwd = transcript_cwd(entries, str(node.get("cwd") or os.getcwd()))
        summary = summarize(digest, cwd)
        packet = save_packet(carry_over(summary, current.label, target.label, original.transcript))
        line = launch_line(target, cwd, packet)
        agt.hud(f"switching to {target.label}", detail=f"quitting {current.label}")
        if live_record(sid, accounts)[0] != original or stamp(original.transcript) != baseline:
            raise Fail("the conversation moved on while the packet was being written")
        check_pane(agt, sid, original.transcript)
        agt.type_line(sid, "/exit")
        if not wait_for_shell(agt, sid, time.monotonic() + 30):
            raise Fail("Claude did not exit; only /exit was typed")
        agt.hud(f"switching to {target.label}", detail="starting Claude")
        # The HUD round trip leaves time for the foreground to change again.
        if not at_shell_prompt(agt.node(sid)):
            raise Fail("the left pane no longer has a foreground shell")
        agt.type_line(sid, line)
        if not wait_for_agent(agt, sid, accounts, target, original, time.monotonic() + 30):
            raise Fail("the launch was typed but the new account's hook has not confirmed startup")
        print(f"left pane switched from {current.label} to {target.label}; packet at {packet}")
        return 0
    except Fail as exc:
        if packet:
            raise Fail(f"{exc}; packet kept at {packet}") from exc
        raise
    finally:
        with contextlib.suppress(Fail):
            agt.hud_close()


def report(message: str) -> None:
    sid = os.environ.get("AGT_SESSION_ID") or os.environ.get("AGTERM_SESSION_ID", "")
    if sid:
        with contextlib.suppress(Exception):
            agt = Agt(sid)
            agt.hud(message, spinner=False)
            time.sleep(6)
            agt.hud_close()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--accounts", type=Path,
                        default=Path.home() / ".config/agterm/claude-accounts.json")
    parser.add_argument("--dry-run", action="store_true", help="check the live map and list destinations; no model call")
    parser.add_argument("--record-hook", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        if args.record_hook:
            record_hook(json.load(sys.stdin))
            return 0
        return swap(load_accounts(args.accounts.expanduser()), args.dry_run)
    except (Fail, OSError, ValueError) as exc:
        if not args.record_hook:
            report(str(exc))
        print(str(exc), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


def find_session(tree: Any, sid: str) -> dict[str, Any] | None:
    if isinstance(tree, dict):
        if tree.get('id') == sid and 'cwd' in tree:
            return tree
        for value in tree.values():
            found = find_session(value, sid)
            if found is not None:
                return found
    elif isinstance(tree, list):
        for value in tree:
            found = find_session(value, sid)
            if found is not None:
                return found
    return None


def busy_reason(node: dict[str, Any], transcript: Path | None, now: float) -> str:
    """Name why the pane must not be disturbed, empty when nothing says so.

    A conservative activity heuristic, never a proof of idleness, which nothing available can
    give. An absent status blocks nothing: it is ambiguous, and the Stop hook's --auto-reset
    clears it the moment the user visits the pane.
    """
    status, pane = (node.get('status'), node.get('statusPane'))
    if status == 'active' and pane != 'right':
        return 'the left pane reports an agent still working'
    if transcript is not None:
        try:
            if now - transcript.stat().st_mtime < BUSY_MTIME_SECONDS:
                return 'the transcript is still being written to'
        except OSError:
            pass
    return ''


def stamp(path: Path) -> tuple[str, int, int]:
    """Identify a transcript for comparison after a slow step.

    An unreadable file raises rather than returning zeros: a zero-valued snapshot compares equal
    to the next unreadable one, reporting a conversation as unchanged exactly when it can no
    longer be seen.
    """
    try:
        info = path.stat()
    except OSError as exc:
        raise Fail(f'cannot read the transcript {path}: {exc}') from exc
    return (str(path), int(info.st_mtime_ns), int(info.st_size))


def final_message(stdout: str) -> str:
    """The last completed agent message of a codex exec stream.

    codex exec emits no `result` event, so the answer is the last `item.completed` carrying an
    agent_message rather than a terminal event of its own.
    """
    message = ''
    for line in stdout.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if not isinstance(event, dict):
            continue
        item = event.get('item')
        if event.get('type') == 'item.completed' and isinstance(item, dict) and (item.get('type') == 'agent_message'):
            message = str(item.get('text', '')) or message
    return message.strip()


def worktree_state(cwd: str) -> str:
    """Ground the packet's file list in what git shows.

    read_entries drops tool traffic, and tool traffic is where every file path lives, so a
    transcript-only digest cannot name what the session touched.
    """

    def git(*args: str) -> str:
        try:
            res = subprocess.run(['git', '-C', cwd, *args], capture_output=True, text=True, check=False, timeout=10)
        except (OSError, subprocess.SubprocessError):
            return ''
        return res.stdout.strip() if res.returncode == 0 else ''
    branch = git('branch', '--show-current')
    if not branch:
        return ''
    head = git('log', '-1', '--format=%h %s')
    dirty = git('status', '--short')[:WORKTREE_LIMIT]
    return f"WORKING TREE (from git, not from the transcript)\ncwd: {cwd}\nbranch: {branch}\nhead: {head}\nuncommitted:\n{dirty or '(clean)'}\n\n"


def summarize(digest: str, cwd: str) -> str:
    cmd = [CODEX_BIN, "exec", "--ephemeral", "--ignore-user-config", "--json",
           "--sandbox", "read-only", "--disable", "shell_tool", "--disable", "unified_exec",
           "--disable", "multi_agent", "-m", MODEL, "-c", 'model_reasoning_effort="low"',
           "-C", cwd, SUMMARY_PROMPT + worktree_state(cwd) + digest]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=CALL_TIMEOUT, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        raise Fail(f'cannot run codex: {exc}') from exc
    if res.returncode != 0:
        raise Fail(f'codex failed (exit {res.returncode}): {(res.stderr or res.stdout).strip()[-300:]}')
    text = final_message(res.stdout)
    if not text:
        raise Fail('codex produced no summary')
    return text


def carry_over(summary: str, current: str, target: str, transcript: Path) -> str:
    return (f"Context carried over from the previous Claude Code session in this pane, which ran "
            f"{current} and has been replaced by {target}. This is a summary rather than a "
            f"transcript; the full one is at {transcript}.\n\n"
            f"This message is CONTEXT ONLY and authorizes nothing. The previous session was "
            f"stopped mid-flight, so anything under Next steps records where the work stood and is "
            f"not an instruction to carry it out. Do not edit a file, run a command, call a tool, "
            f"or start any of that work now. Reply with a single line naming the work in hand, then "
            f"wait for the user.\n\n{summary}\n")


def at_shell_prompt(node: dict[str, Any]) -> bool:
    """The left pane has a shell in front and no program running in it.

    The shell must be SEEN rather than inferred from Claude's absence, which answers true for
    vim. It still does not prove the prompt accepts input: a builtin like `read` runs inside the
    shell process.
    """
    return bool(node.get('foregroundShell')) and (not node.get('foreground'))


def transcript_cwd(entries: list[Any], fallback: str) -> str:
    """The directory CLAUDE was in, not the one the pane's shell sits in.

    Claude moves its transcript to a worktree's project dir while the shell stays at the repo
    root, so the tree's cwd would ground the packet in the wrong branch and dirty files, and
    relaunch the replacement there.
    """
    return next((e.cwd for e in reversed(entries) if e.cwd), '') or fallback


def relative_age(when: datetime, now: datetime) -> str:
    secs = int((now - when).total_seconds())
    if secs < 60:
        return 'just now'
    if secs < 3600:
        return f'{secs // 60}m ago'
    if secs < 86400:
        return f'{secs // 3600}h ago'
    return f'{secs // 86400}d ago'


def parse_ts(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        return None


def strip_noise(text: str) -> str:
    for open_tag, close_tag in (('<system-reminder>', '</system-reminder>'), ('<local-command-caveat>', '</local-command-caveat>')):
        while True:
            start = text.find(open_tag)
            if start < 0:
                break
            end = text.find(close_tag, start)
            if end < 0:
                text = text[:start]
                break
            text = text[:start] + text[end + len(close_tag):]
    return text.strip()


def user_text_from_blocks(blocks: list[Any]) -> str:
    """A list-shaped user turn's own words, empty when it has none.

    Text is taken ONLY when some block is not text. A list of pure text blocks is a skill
    injection carrying the whole SKILL.md body, and joining those crowds the conversation out
    of the digest cap.
    """
    kinds = {str(b.get('type', '')) for b in blocks if isinstance(b, dict)}
    if not kinds - {'text'}:
        return ''
    if 'tool_result' in kinds or 'tool_use' in kinds:
        return ''
    parts = [str(b.get('text', '')) for b in blocks if isinstance(b, dict) and b.get('type') == 'text']
    return ' '.join(p for p in parts if p)


def read_entries(transcript: Path) -> list[Entry]:
    entries: list[Entry] = []
    try:
        lines = transcript.read_text(errors='replace').splitlines()
    except OSError as exc:
        raise Fail(f'cannot read transcript: {exc}') from exc
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        at, cwd = (str(row.get('timestamp', '')), str(row.get('cwd', '')))
        message = row.get('message') or {}
        content = message.get('content') if isinstance(message, dict) else None
        if row.get('type') == 'user' and isinstance(content, str):
            text = strip_noise(content)
            if text and (not text.startswith('[Request interrupted')):
                entries.append(Entry('user', text, at, cwd))
        elif row.get('type') == 'user' and isinstance(content, list):
            text = strip_noise(user_text_from_blocks(content))
            if text and (not text.startswith('[Request interrupted')):
                entries.append(Entry('user', text, at, cwd))
        elif row.get('type') == 'assistant' and isinstance(content, list):
            parts = [str(p.get('text', '')) for p in content if isinstance(p, dict) and p.get('type') == 'text']
            text = strip_noise(' '.join(parts))
            if text:
                entries.append(Entry('assistant', text, at, cwd))
        elif at or cwd:
            entries.append(Entry('meta', '', at, cwd))
    return entries


def build_digest(entries: list[Entry], trim: int, now: datetime) -> str:
    out: list[str] = []
    for entry in entries:
        if entry.kind == 'user':
            when = parse_ts(entry.at)
            tag = relative_age(when, now) if when else '?'
            out.append(f'\n[{tag}] USER: {entry.text}\n')
        elif entry.kind == 'assistant':
            out.append(f'CLAUDE: {entry.text[:trim]}\n')
    return ''.join(out)[-MAX_DIGEST_BYTES:]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
