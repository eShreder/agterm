#!/usr/bin/env python3
"""
agtermctl (Linux/remote) — drive agterm from a remote ssh -> tmux session, no compiled binary.

agterm forwards its control socket to this host (ssh -R) and drops the path into
~/.agterm-control-socket. This stdlib-only client connects there and speaks the same protocol as the
macOS agtermctl:

    request:  {"cmd": <str>, "target": <str|null>, "args": {<...>}}\\n
    response: {"ok": <bool>, "result": {<...>}}   or   {"ok": false, "error": <str>}

The `raw` subcommand reaches ANY command in the catalog; the sugar subcommands are conveniences.

KEEP-IN-SYNC: the sugar mirrors agtermCore/Sources/agtermctlKit. When the Swift CLI changes a
command, update the sugar (or just use `raw`). This file is bundled with the agterm agent skill.
"""
import argparse
import json
import os
import socket
import sys

DISCOVERY_FILE = os.path.expanduser("~/.agterm-control-socket")


def resolve_socket(cli_socket):
    if cli_socket:
        return cli_socket
    env = os.environ.get("AGTERM_CONTROL_SOCKET")
    if env:
        return env
    try:
        with open(DISCOVERY_FILE) as f:
            path = f.read().strip()
            if path:
                return path
    except (OSError, ValueError):
        pass
    sys.exit("agtermctl: no control socket found. Set --socket, export AGTERM_CONTROL_SOCKET, or "
             "ensure agterm forwarded one (AGTERM_TMUX_FORWARD_CONTROL=1) and wrote "
             "~/.agterm-control-socket.")


def send(sock_path, cmd, target, args):
    req = {"cmd": cmd}
    if target is not None:
        req["target"] = target
    if args:
        req["args"] = args
    line = (json.dumps(req) + "\n").encode()
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(5)
        s.connect(sock_path)
    except OSError as e:
        sys.exit(f"agtermctl: cannot connect to {sock_path}: {e}")
    with s:
        try:
            s.sendall(line)
            buf = bytearray()
            while b"\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    break
                buf += chunk
        except socket.timeout:
            sys.exit("agtermctl: timed out waiting for a response")
        except OSError as e:
            sys.exit(f"agtermctl: connection lost: {e}")
    if not buf:
        sys.exit("agtermctl: empty response")
    try:
        resp = json.loads(bytes(buf).split(b"\n", 1)[0].decode())
    except ValueError:
        sys.exit("agtermctl: malformed response")
    if not isinstance(resp, dict):
        sys.exit("agtermctl: malformed response")
    return resp


def coerce(value):
    """`--arg k=v`: parse v as JSON when it looks like it (true/false/number/quoted), else a string."""
    try:
        return json.loads(value)
    except ValueError:
        return value


def emit(resp, as_json):
    if as_json:
        print(json.dumps(resp))
        return 0 if resp.get("ok") else 1
    if resp.get("ok"):
        result = resp.get("result") or {}
        print(result.get("id") or result.get("text") or "ok")
        return 0
    print(f"agtermctl: {resp.get('error', 'error')}", file=sys.stderr)
    return 1


def build_parser():
    p = argparse.ArgumentParser(prog="agtermctl", description="Drive agterm over its control socket.")
    p.add_argument("--socket", help="Path to the control socket (overrides env / discovery file).")
    p.add_argument("--json", action="store_true", help="Print the raw JSON response.")
    sub = p.add_subparsers(dest="sub", required=True)

    sp = sub.add_parser("tree", help="Dump the window/workspace/session tree.")

    sp = sub.add_parser("notify", help="Post a desktop notification.")
    sp.add_argument("--body", required=True)
    sp.add_argument("--title")
    sp.add_argument("--target", default="active")

    sp = sub.add_parser("type", help="Type text into a session (cmd: session.type).")
    sp.add_argument("--text", required=True)
    sp.add_argument("--target", default="active")
    sp.add_argument("--pane", choices=["left", "right", "scratch"])

    sp = sub.add_parser("status", help="Set a session's agent status (cmd: session.status).")
    sp.add_argument("state", choices=["idle", "active", "blocked", "completed"])
    sp.add_argument("--target", default="active")
    sp.add_argument("--blink", action="store_true")
    sp.add_argument("--color")

    sp = sub.add_parser("new", help="Create a session (cmd: session.new).")
    sp.add_argument("--name")
    sp.add_argument("--command")
    sp.add_argument("--workspace")

    sp = sub.add_parser("raw", help="Send any command directly.")
    sp.add_argument("--cmd", required=True)
    sp.add_argument("--target")
    sp.add_argument("--arg", action="append", default=[], metavar="KEY=VALUE",
                    help="Repeatable. Value parsed as JSON when possible, else a string.")
    return p


def to_request(ns):
    if ns.sub == "tree":
        return "tree", None, {}
    if ns.sub == "notify":
        args = {"body": ns.body}
        if ns.title:
            args["title"] = ns.title
        return "notify", ns.target, args
    if ns.sub == "type":
        args = {"text": ns.text}
        if ns.pane:
            args["pane"] = ns.pane
        return "session.type", ns.target, args
    if ns.sub == "status":
        args = {"status": ns.state}
        if ns.blink:
            args["blink"] = True
        if ns.color:
            args["color"] = ns.color
        return "session.status", ns.target, args
    if ns.sub == "new":
        args = {}
        if ns.name:
            args["name"] = ns.name
        if ns.command:
            args["command"] = ns.command
        if ns.workspace:
            args["workspace"] = ns.workspace
        return "session.new", None, args
    if ns.sub == "raw":
        args = {}
        for item in ns.arg:
            if "=" not in item:
                sys.exit(f"agtermctl: --arg must be KEY=VALUE, got {item!r}")
            key, value = item.split("=", 1)
            args[key] = coerce(value)
        return ns.cmd, ns.target, args
    sys.exit(f"agtermctl: unknown subcommand {ns.sub!r}")


def main():
    ns = build_parser().parse_args()
    sock_path = resolve_socket(ns.socket)
    cmd, target, args = to_request(ns)
    resp = send(sock_path, cmd, target, args)
    sys.exit(emit(resp, ns.json))


if __name__ == "__main__":
    main()
