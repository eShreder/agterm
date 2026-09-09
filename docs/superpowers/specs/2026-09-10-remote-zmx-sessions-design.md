# Remote zmx sessions: attach to any host that runs zmx

**Status:** design for review, pre-implementation
**Date:** 2026-09-10
**Replaces:** the tmux designs (`feature/tmux-relay` and the grouped-client draft that preceded this file)

## The idea being kept

A process on a host that stays up survives a closed laptop. agterm should show such processes as
native sessions: one sidebar row per remote session, marked remote, opened from a list an agent or a
picker can read, and closable without killing anything on the host. Rename, split, search, notifications,
and the control API then work as they do for any other pane.

tmux was the first vehicle, and its cost was the window model: a control channel, a parser for window
events, grouped clients or a relay to give each window its own pane. zmx has no windows on purpose. Its
author's position is that window management belongs to the OS, which in agterm is the sidebar. The mapping
is therefore one zmx session to one agterm session, and no channel, parser, or mirror state exists.

## What master already has

`zmx tree HOST` and `zmx attach HOST SESSION` (#524) attach a session running under another **agterm**:
the far side runs `agtermctl zmx tree --json`, the local side opens an ordinary command session whose
command is `ssh -tt … zmx attach <daemon> <create-only guard>`, and `Session.remoteHost` marks it
remote, keeps it out of every snapshot, and gives it the cloud glyph and the title-bar host. The far side
must run agterm in Live sessions mode with `agtermctl` on sshd's PATH.

This design adds the other far side: a plain host, Linux or Mac, with only zmx installed.

## Design

### Commands

A new control group, `remote`, because these sessions are addressed by zmx name on a host that has no
agterm, no window and no workspace, while `zmx tree`/`zmx attach` stay the agterm-to-agterm teleport by
session id. Two listings that answer different questions are clearer than one verb with two shapes.

- `remote.list {host}` → `result.remoteSessions: [ControlRemoteHostSession]`. Runs the far side's own
  `zmx list` over ssh and parses its `key=value` tab rows. A row carries `name`, `clients`, `cwd` (the path
  of the `file://` URI, when present), `created` (unix seconds), and `labels` (every other key). Daemons
  whose name is an agterm daemon name (`ZmxSupport.isDaemonName`) are omitted: those belong to an agterm
  on that host and are reached through `zmx tree`, where their split and ownership are known. An empty
  list is a successful answer.
- `remote.attach {host, target: name, window?, create?, command?}` → `result.id` of the new local session.
  Without `create`, the argv carries the same create-only guard `zmx attach HOST` uses, so a session that
  vanished since the list was read fails visibly instead of becoming a fresh shell wearing its name. With
  `create`, the guard is dropped and `command`, if given, is what the new daemon runs instead of a login
  shell; an existing daemon ignores it, which the docs state. `command` without `create` is refused.
- `remote.kill {host, target: name, force}` → runs `zmx kill <name>` on the host. `force` is required, as
  for `zmx kill`; it does not map to zmx's own `--force`, which unlinks an unreadable socket and is never
  sent. Any local pane attached to that daemon ends the way a dropped ssh does.

CLI: `agtermctl remote list HOST`, `agtermctl remote attach HOST NAME [--create] [--command CMD]
[--window W]`, `agtermctl remote kill HOST NAME --force`. `attach` echoes the created id like every
create command. No GUI in v1: the picker is a keymap custom command, as it is for `zmx attach`, and the
bundled skill gets the recipe.

### The pane

An ordinary command session in the destination window's current workspace, `remoteHost = host`,
`customName = name`, `wait: true`, cwd this Mac's home. Command:

```
ssh -tt -o BatchMode=yes -o ConnectTimeout=5 <host> '/usr/bin/env ZMX_SESSION= ZMX_SESSION_PREFIX= ZMX_NO_DETACH_KEY=1 /bin/sh -c "PATH=\"$PATH:$HOME/.local/bin:$HOME/bin:/usr/local/bin:/opt/homebrew/bin\" && exec zmx attach <name> [guard | command]"'
```

followed by the same "disconnected, exit <status>" line `RemoteSession.attachPaneCommand` prints, held
under Ghostty's press-any-key prompt. Differences from the agterm-to-agterm attach: no `ZMX_DIR` is set,
so the daemon lives where the user's own ssh shell would find it; zmx is resolved through PATH plus the
usual user bin directories, because sshd's non-interactive shell reads no profile and zmx.sh installs
into `~/.local/bin`; and the far side needs nothing but zmx.

Because zmx is a transparent pty proxy with ghostty-vt replay, everything the tmux designs lost comes
back for free: OSC notifications, cwd and prompt marks reach agterm, and the scrollback replays into
agterm's own on attach. When no other client is attached, this client is the daemon's leader and the
remote is sized to this pane from the first byte; the follower limitations documented for `zmx attach`
apply only while another client holds the daemon.

### Model and lifecycle

Nothing new. `Session.remoteHost` already gives: not persisted, not wrapped in a local daemon,
`locallyManagedPaneIdentities` empty, cloud glyph, title-bar host, Recent Closed excluded, pending-close
undo kept. Closing the row ends ssh; the daemon survives. Rename is local. Split, scratch, overlay,
`session.type`, search and notifications act on the pane as usual.

### Transport and failure

The runner is the existing async `RemoteCommandRunner` seam, and `remote.list`/`remote.kill` join
`zmx.tree`/`zmx.attach` as the commands `handleConnection` moves off the accept thread. `remote.attach`
does not ssh before insertion: it validates and builds the command, and a transport failure is an
ordinary pane exit on the held path, like `zmx.attach`. Optionally it re-lists first when `create` is
absent; the guard already covers the vanished case, so v1 skips the extra round trip.

- Host: `RemoteSession`'s rule, `invalid host` as a constant, never echoed unless it passed.
- Name: non-empty, no whitespace or control characters, no `/` (it becomes a socket file name); echoed in
  errors only after passing.
- Exit 127 from the list or kill chain → `zmx is not installed on <host>` rather than the raw stderr.
- Other nonzero exits → the trimmed stderr, as `zmx.tree` reports ssh failures.
- Requirements stated on every surface: key-based, prompt-free ssh; zmx 0.7 or later on the host; the
  `zmx list` row format is what the parser reads, and a future zmx that changes it breaks `remote list`
  loudly, not `remote attach`.

### Persistence decision, open

`Session.remoteHost` makes the row vanish on relaunch, and master documents that for `zmx attach`. For
a plain zmx host the re-run is deterministic and the guard makes it safe, so a persisted
`ssh … zmx attach name` under Re-run commands or Live sessions would bring the row back attached after
a restart, which is most of what the remote-claude-session recipe exists for. v1 keeps master's rule
for consistency; lifting it is a separate change to `isPersistable` and the restore capture, listed
here so it is a decision and not an omission.

## Testing

- `agtermCore`: `zmx list` row parser (fields, labels, missing cwd, agterm-name filter, garbage rows
  skipped); argv builders for list, attach with and without `create`/`command`, and kill, pinned by string;
  name and host validation; `ControlProtocol` round-trips for the three commands and the result payload;
  dispatcher tests through `MockControlActions` (missing host, missing name, `command` without `create`,
  `kill` without `force`); `agtermctl remote` argument parsing against a fake socket.
- `agtermTests`: `ControlServer` with a fake runner: list parses and filters; attach inserts a session with
  `remoteHost`, `wait`, the expected command, into the resolved window; an invalid or closed `--window`
  creates nothing; kill reports the far side's answer.
- UI test: none, see decision 6.
- Manual gate, once, against a Linux host with zmx: list shows a session started by hand, attach replays
  its screen at this pane's size, closing the tab leaves `zmx list` on the host unchanged, `--create
  --command claude` starts the agent, `remote kill --force` ends it, and notifications from inside the
  session reach the sidebar.

## Documentation

`.claude/rules/control-api.md` Remote sessions section, the bundled skill (`SKILL.md`, `reference.md`,
`examples.md`), `site/commands.html`, `site/docs.html`, the README remote bullet. No command count is
stated anywhere. The cookbook is not touched; a picker recipe can follow.

## Spike results (bundled zmx 0.7.0, isolated `ZMX_DIR`, 2026-09-10)

- `zmx list` prints one row per session: `name=… pid=… clients=… created=… cwd=file://<host>/<path>` and
  labels appended as `k=v`, tab-separated. `zmx set NAME k=v` adds labels.
- A socket directory path over about 100 bytes fails with `socket directory path is too long`, so the
  far side's default directory is left alone.
- `zmx attach NAME <payload>` on an existing session ignores the payload, which is the create-only guard
  master relies on.
- `zmx kill a b --force` kills several by name; the flag is zmx's socket-unlink override, not a confirmation.

## Decisions taken, open for override

1. A new `remote` group rather than overloading `zmx tree`/`zmx attach`, whose contract is agterm-shaped.
2. `remote list` hides agterm-owned daemons on a host that also runs agterm.
3. `--create` is explicit; a bare attach never creates.
4. Sessions are not restored after a relaunch in v1 (see the persistence decision).
5. No GUI; picker and workflow live in the skill and, later, a cookbook recipe.
6. No XCUITest methods for the remote group: like zmx.tree/zmx.attach, the end-to-end coverage is the
   hosted ControlServer suite driven through ControlDispatcher (ControlServerRemoteTests).
