# tmux remote sessions, take two: grouped clients plus a control channel

**Status:** design for review, pre-implementation
**Date:** 2026-09-10
**Supersedes:** the engine of `feature/tmux-relay` (`-CC` output relay through `agtermctl tmux-pipe`); keeps its user-facing contract

## The idea being kept

A tmux session on a host that stays up is the cheapest way to make an agent, a build, or a shell
survive a closed laptop. agterm should present such a session natively: every tmux window is an agterm
session in the sidebar, closing or renaming one round-trips to tmux, a new window created on either side
appears on the other, and an agent can attach, list, and address those sessions through the control API.
Detaching leaves everything running on the host; reattaching brings it back.

That is the whole feature. Everything else in `feature/tmux-relay` (4.7k lines across 74 files) is the
cost of painting tmux pane bytes into a libghostty surface without an engine fork: a per-window unix
socket, a relay child process, a framed wire protocol, a streaming filter that mutes terminal queries the
Mac would otherwise answer a round-trip late, `capture-pane` snapshots with held output replayed over
them, held input before a pane id arrives, per-connection resize. None of it exists in this design.

## What changed on master since July

`zmx attach HOST SESSION` (#524) established that a remote pane is an ordinary command session whose
command is `ssh`: `Session.remoteHost` is immutable and set at construction, such a session is never
persisted (`isPersistable`), the sidebar and title bar mark it with a cloud glyph, and
`RemoteSession` owns the ssh argument shapes, host validation, and remote quoting. Every remote feature on
master assumes key-based, prompt-free ssh (`BatchMode=yes`), and the cookbook's remote-claude-session
recipe documents the `ControlMaster` setup that makes many ssh channels to one host cheap.

This design is that primitive applied to tmux windows.

## Design

### Two kinds of process per connection

**One control channel.** `ssh -T -o BatchMode=yes <host> tmux -C new-session -A -s <name>` spawned by the
app with pipes (a long-lived cousin of `RemoteCommandRunner`, not `PTYProcess`: no pty, no session
leader, no tty prompts). Its first command is `refresh-client -f no-output`, after which tmux sends
window notifications but no pane output. It carries agterm→tmux commands (`list-windows`, `rename-window`,
`kill-window`, `new-window`, `kill-session`) and tmux→agterm events (`%window-add`, `%window-renamed`,
`%unlinked-window-close`, `%window-close`, `%exit`). A control client does not take part in window sizing
(verified: a `-C` client reports `80x` and the window stayed at the pty client's 132x40).

**One pty client per tmux window.** Each mirrored agterm session is a stock command session with
`remoteHost = host`, `wait: true`, and the command

```
ssh -tt -o BatchMode=yes <host> 'tmux new-session -t <name> \; set status off \; set destroy-unattached keep-group \; select-window -t @N'
```

`new-session -t` creates a session in `<name>`'s group: same windows, its own current window and its own
options, so `status off` and `select-window` do not touch the user's real session or any other mirror.
`destroy-unattached keep-group` reaps the grouped session when the pane closes. tmux draws the window
itself, so the surface talks to a real tmux client: terminal queries are answered by tmux, keys and mouse
go straight in, a split window renders every pane, resize is per window, and an attach paints the screen
with no snapshot logic. The pane's command ends the way `RemoteSession.attachPaneCommand` does: one line
naming the host, the window, and the exit status, held by the wait prompt.

Local tmux is the same design with no ssh in front: the control channel runs `tmux -C …` and the pane
runs `tmux new-session -t …` directly. It is the test path and it is useful on its own, so it is a
first-class target rather than a dev-only env var.

### Mapping

- tmux session → one agterm workspace named `tmux: <host>/<name>`, created ephemeral: it is not written
  to `workspaces.json` and it disappears with the connection. Its sessions are already non-persistable
  through `remoteHost`; the ephemeral flag exists so no empty `tmux:` workspace reappears at launch.
- tmux window → one agterm session carrying an ephemeral `tmuxBinding {connection, windowID}` and the
  window name as `customName`.
- Handshake: after `%session-changed` send `list-windows -F '#{window_id}\t#{window_name}'`; the reply
  creates the mirror sessions, lowest window number selected. The one-line `%begin`/`%end` reply protocol
  is the same `TmuxControlParser` grammar the relay branch parsed; the parser and the window-list parser
  are rewritten to the subset this design needs.
- `%window-add @N` → add a mirror session with `select: false` (a remote script creating windows must not
  steal focus). tmux emits the event once per session in the group, so it is deduplicated by window id.
- `%window-renamed @N name` → `store.renameSession` directly, never through the backend-aware router
  (the echo of agterm's own rename must not loop).
- `%unlinked-window-close @N` / `%window-close @N` → close the mirror session. This is mandatory, not
  cosmetic: a grouped client whose window dies is moved by tmux to a neighbouring window, so a pane left
  open would show the wrong window.
- `%exit`, control-channel death, or ssh exit → tear the workspace down. Reattach is manual, as before.

### agterm → tmux

- `session.rename` and `session.close` on a bound session route to `rename-window -t @N '<name>'` and
  `kill-window -t @N`, and the local side follows the echo. Sidebar rename, ⌘W, the context menu, and both
  control arms share those routers, the same seam the relay branch wired.
- `session.new` inside a mirror workspace (⌘T, the sidebar plus button) sends `new-window`; the `%window-add`
  echo creates the mirror and, because this client asked, selects it (a short generation-guarded latch).
  Control `session.new` keeps creating a local session, as on the relay branch: `%window-add` is
  asynchronous and the command has no id to return.
- `tmux.detach` sends `detach-client` and tears down; `tmux.kill` sends `kill-session` and lets `%exit`
  drive teardown with a 2s fallback. Both semantics are inherited unchanged.
- Split, scratch, overlay, and `session.type` need nothing: they act on an ordinary pane whose foreground
  is a tmux client.

### Control API, CLI, addressing

Inherited verbatim from `feature/tmux-relay` so the skill, `site/commands.html`, and the protocol tests
carry over: `tmux.attach {host?, name?, workspaceName?}`, `tmux.list` → `[ControlTmuxNode]`,
`tmux.detach {id?}`, `tmux.kill {id?}`; `agtermctl tmux attach|list|detach|kill`; `--target tmux:@N` and
`tmux:%P`; `ControlSessionNode.tmuxWindow`/`tmuxPane`. One change: `host` becomes optional and its
absence means the local tmux server. Hosts are validated by `RemoteSession`'s rule (non-empty, no
whitespace or control characters, no leading `-`); session and window names are quoted with
`CommandRestore.shellQuotedLine` for the remote shell and passed as argv locally.

`tmux:%P` resolves through `%layout-change`, the one event besides the window set this design still
reads: the leading pane id of each window, so `$TMUX_PANE` addresses its window. Programs inside a
remote tmux pane cannot reach the Mac's socket anyway; the recipe's port forward is the answer there.

### Requirements and limits, stated up front

- ssh that works with no terminal and no prompt. A password or host-key question fails the attach with
  the error text ssh printed. `ControlMaster` in `~/.ssh/config` is recommended and documented, not
  required: without it each window is its own ssh handshake.
- tmux 3.3 or later on the host, for `refresh-client -f no-output` and `destroy-unattached keep-group`.
- What is lost against the relay design, because the pane stream is drawn by tmux rather than fed raw
  into the surface: OSC 9/777 desktop notifications, OSC 7 cwd, and OSC 133 prompt marks from programs
  inside tmux do not reach agterm; bells do. Scrollback and ⌘F cover what tmux has drawn, and history
  scrolling is tmux copy-mode (`mouse on` on the host makes the wheel do it). The docs say so instead of
  claiming "notifying like any other".
- Extra sessions named `<name>-1`, `<name>-2`, … show in `tmux ls` on the host while windows are
  mirrored; `keep-group` removes them on detach.
- Reattach after an ssh drop stays manual, as in the relay branch.

## Alternative kept on the table: a recipe, no app code

Two chords and one script give most of the daily use without touching the app:

- **Open:** `ssh host tmux list-windows -t main -F '#{window_id}\t#{window_name}'` into the native picker,
  then `agtermctl session new --command "<the grouped attach above>" --name "<window>"` per chosen window,
  or all windows in one go into a new workspace.
- **Close:** `agtermctl session close` on the tab; the grouped session dies with `keep-group`.

What the recipe cannot do is live mirroring (`%window-add` after the fact, rename in both directions,
`tmux:` addressing, `tmux list`) because nothing long-lived reads the control channel. It is the right
answer if the native feature is judged not worth ~1.5k lines; it is also a fine first milestone that
proves the ssh and tmux shapes before the app learns them.

## Testing

- `agtermCore`: control-stream parser (notifications, `%begin`/`%end` reply blocks, the doubled
  `%window-add`), window-list reply parsing, command encoders and quoting, the pane command builder,
  `ControlProtocol` round-trips for `tmux.*`, `tmux:` target parsing, and `agtermctl tmux` argument
  parsing against a fake socket.
- App target (hosted): the controller driven by a fake channel: handshake builds the mirror; add, rename,
  close, and `%exit` mutate the store; rename and close from the store side send the right commands and
  do not loop on their echo.
- UI test: `tmux.attach` with an invalid host returns the discriminated error; `tmux.list` is empty.
- Manual gate, once: `agtermctl tmux attach --socket … --host <box> --name main` against a real host and
  against local tmux: windows appear, `prefix c` on the host adds a tab, ⌘W kills the window, rename
  round-trips, a split window renders both panes, detach leaves `tmux ls` intact.

## Spike results (tmux 3.7a, private server, 2026-09-10)

- Grouped sessions have independent `status` and current window.
- `-C` over a pipe with no tty works; after `refresh-client -f no-output` no `%output` arrives, window
  notifications still do, `%window-add` arrives once per session in the group.
- `new-session -t main \; set status off \; set destroy-unattached keep-group \; select-window -t @1` in
  one invocation lands on `@1` at the client's size (132x40) with status hidden.
- A control client is not counted for window size.
- `kill-window` on a grouped client's current window moves that client to a neighbour.

## Decisions taken, open for override

1. Native feature, not recipe only; the recipe shape is documented in the user guide as the no-install path.
2. Ephemeral mirror workspace per tmux session, as in the relay branch, rather than importing windows into
   the current workspace like `zmx attach`.
3. `host` optional, local tmux first-class.
4. No reconnect-on-drop in v1.
5. Wire contract of `tmux.*` inherited unchanged so the branch's docs and protocol tests are reused.
