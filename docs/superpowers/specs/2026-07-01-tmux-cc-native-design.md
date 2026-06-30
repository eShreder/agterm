# tmux `-CC` native integration — design

**Status:** approved design, pre-implementation
**Date:** 2026-07-01
**Topic:** ssh + tmux control-mode (`-CC`) with native panes, iTerm2-style

## Goal

Add iTerm2-style `tmux -CC` support: a remote `tmux` session over ssh is presented
**natively** inside agterm — tmux windows become agterm sessions, rendered in real
agterm terminal surfaces, with input/resize round-tripped back to tmux.
This gives true remote-process survival (detach/reattach) that the current shell-only
model cannot provide (see README "Restore limitations").

## Scope decisions (settled during brainstorming)

- **No splits inside a tmux window.** Each tmux window maps to exactly one agterm
  session backed by one surface. If the remote side splits a window, agterm shows the
  active/leading pane and logs/notifies that the split is collapsed. Generalizing to
  arbitrary nested layouts is a separate future feature.
- **Hierarchy mapping:** one `ssh + tmux -CC` connection attaches to one tmux session.
  **tmux session → agterm workspace, tmux window → agterm session.**
- **Module placement per project convention:** the control-protocol parser and the
  event→model mapping are host-free in `agtermCore` (fully `swift test`-covered); the
  gateway subprocess, PTY, and all libghostty/SwiftUI wiring live in the app target.
- **Build strategy: Approach A** — bottom-up, engine-prototype-first. The libghostty
  fork is the single biggest risk, so it is proven with running code before the rest is
  built.

## Why this needs an engine patch (spike result)

The shipped libghostty C API has no PTY-less surface and no "feed bytes to the screen"
entry, so tmux panes cannot be painted without patching the engine. A source spike of
ghostty at the pinned `GHOSTTY_REV` (`4dcb09ada0c0909717d92547623b26eafa50ca8a`) found
the seam is **clean and additive**, living entirely in the io/apprt layer:

- `src/termio/backend.zig`: `Kind = enum { exec }` is an extensible `union(Kind)`; the
  backend already encapsulates "owns the pty behavior and provides read/write".
  `Options.zig` explicitly allows alternate IO implementations.
- `src/termio/Termio.zig`: `processOutput(buf: []const u8)` (line 643) already locks the
  renderer mutex, runs bytes through `terminal_stream` (the VT parser), and schedules a
  render. The Exec read thread calls it with PTY bytes; tmux `%output` needs exactly
  this entry.
- Threading is mailbox-funneled through the IO thread: keystrokes go
  `Surface → io.queueMessage(write_*) → IO thread → backend.queueWrite([]const u8)`, and
  PTY reads go `ReadThread → processOutput`. Both inbound output and outbound input have
  clean seams on the IO thread.

agterm already **builds libghostty from source** at a pinned SHA, so a local patch is
mechanically feasible. The cost is an effective mini-fork with per-bump maintenance.

## Architecture

```
                ┌─────────────────────────── app target ───────────────────────────┐
   ssh+tmux -CC │  TmuxGateway (subprocess + PTY)                                    │
   remote host  │     stdout ──► TmuxControlParser ──► TmuxSessionModel              │
   ◄───stdin────┤        ▲                                  │ (model effects)        │
                │        │ outbound cmds                    ▼                        │
                │  (send-keys/new-window/resize)      TmuxController → AppStore       │
                │        │                                  │  create/remove          │
                │        │                                  ▼  workspace + session     │
                │  HeadlessSurfaceController ◄──── routeOutput(bytes)                 │
                │     ghostty_surface_write_output(bytes) ──► [engine patch] renders  │
                │     on_input callback ──────────────────────► outbound send-keys     │
                └───────────────────────────────────────────────────────────────────┘
   agtermCore (host-free): TmuxControlParser, TmuxSessionModel, command encoder
   engine (libghostty fork): Headless backend + write_output + input/resize callbacks
```

Module boundary holds: all protocol/mapping logic is host-free `agtermCore`; everything
touching libghostty, processes, or SwiftUI is in the app target.

## Components

### 1. Engine patch (libghostty fork, applied by `scripts/setup.sh`)

Additive, io/apprt-layer only; nothing in the renderer, VT parser, or terminal core.
Applied as a local `.patch` over the `GHOSTTY_REV` checkout in `scripts/setup.sh`.

- **`headless` backend** — `src/termio/backend.zig`: extend `Kind` to
  `enum { exec, headless }`, add the `headless` arm to `Backend`/`ThreadData`/`Config`.
  New `src/termio/Headless.zig` implements the backend contract with no PTY:
  - `threadEnter` — no-op (no subprocess/read thread; the IO Thread still runs and drains
    the mailbox).
  - `queueWrite(data: []const u8, …)` — outbound input seam: instead of writing a PTY,
    invoke a C callback `on_input(userdata, ptr, len)` (bytes agterm sends to tmux as
    `send-keys`).
  - `resize(grid_size, screen_size)` — invoke `on_resize(userdata, cols, rows)`.
  - `deinit`/`focusGained`/`childExitedAbnormally`/`getProcessInfo` — no-op / `null`.
- **External output into the screen** — `src/termio/message.zig` + `Termio.zig`: add an
  `external_output` mailbox message (carries bytes like the existing `write_*`). On the
  IO thread `Termio` handles it by calling the existing `processOutput(buf)`. tmux
  `%output` thus flows through the same IO thread and same parser as a normal PTY read.
- **C API** — `src/apprt/embedded.zig`:
  - `Surface.Options` gains `headless: bool = false`, `on_input`/`on_resize` callback
    pointers, and their `userdata`.
  - `initConfig`/`newSurface` (~line 530): when `headless`, build a `Headless` backend
    (with the callbacks) instead of `Exec`; `command`/`wait_after_command` are ignored.
  - New export `ghostty_surface_write_output(surface, ptr, len)` → posts `external_output`
    to the surface mailbox (thread-safe, like `queueMessage`).
  - Resize stays pixel-based (`ghostty_surface_set_size`); the engine derives cols×rows
    and passes them to `Headless.resize` → callback. No separate cells-resize C entry is
    needed (confirmed in the spike).
- **Header** — `ghostty.h` is regenerated by the zig build from the exports; no manual
  header edits.

**Maintenance:** re-apply additive hunks on each `GHOSTTY_REV` bump; conflicts only if
upstream reworks the `Backend` union or `Surface.Options`. This is the long-term cost of
the mini-fork.

**Phase-A prototype (viability gate):** build the patch, create a headless surface, feed
it hardcoded VT bytes (e.g. `"\x1b[31mhello\x1b[0m\r\n"`) via
`ghostty_surface_write_output`, see them rendered in an agterm window, press a key and
catch it in `on_input`. Green prototype = fork is viable; proceed.

### 2. `TmuxControlParser` (`agtermCore`, host-free)

A line-oriented state machine, no I/O. tmux `-CC` emits command blocks wrapped in
`%begin <ts> <num> <flags>` … `%end`/`%error`, plus async `%`-prefixed notifications.

Inbound `TmuxEvent` cases:
- `%output %<paneId> <data>` — pane output bytes; `data` uses tmux octal escaping (`\NNN`)
  for control bytes → **decode to raw bytes**.
- `%window-add @<id>` / `%window-close @<id>` / `%window-renamed @<id> <name>`
- `%layout-change @<id> <layout>` — under "no splits" used only for name/size; nested
  layouts collapsed (see mapping).
- `%session-changed $<id> <name>` / `%sessions-changed`
- `%begin/%end/%error` — correlate responses to our commands by `num`.
- `%exit [reason]` — tmux leaves control mode.
- `%client-detached` / `%continue` / `%pause` — lifecycle.
- unknown `%…` — softly ignored with a log (forward-compat with newer tmux).

Outbound command encoder (separate function, produces stdin bytes):
- `new-window` / `kill-window -t @<id>` / `rename-window`
- `send-keys -t %<paneId> -l -- <literal>` (or hex mode for arbitrary bytes) — our input.
- `refresh-client -C <cols>x<rows>` and/or `resize-window` — our resize.
- `detach-client` — soft detach (tmux survives server-side → reattach later).

The parser knows only the tmux protocol, nothing about the agterm model. It buffers
partial lines until `\n` (PTY chunks split lines).

### 3. `TmuxSessionModel` (`agtermCore`, host-free)

A thin layer between parser events and the agterm model. Holds the
`@windowId ↔ agterm sessionId` and `%paneId ↔ surfaceId` mappings. Input: `TmuxEvent`.
Output: `TmuxModelEffect` intents — `createSession(windowId, name)`, `removeSession`,
`renameSession`, `routeOutput(surfaceId, bytes)`, `tearDownWorkspace`. It renders nothing
and touches no surfaces; the app target executes the effects. This keeps it host-free and
testable (run events, assert the effect list).

**No-splits handling:** each tmux window = one pane = one surface. If the remote side
splits a window, the model treats the first/active pane as the leading surface and
ignores the rest, with a visible log/notification. A deliberate YAGNI boundary, not a bug.

Both types are `Sendable`, pure, with no `Date.now()`/I/O in the logic (time comes from
events).

### 4. `TmuxGateway` (app target)

agterm-owned subprocess `ssh <host> -- tmux -CC new -A -s <name>` (reattach via `-A` =
attach-or-create), launched in an **agterm-owned PTY** (a thin Swift wrapper over
`forkpty`/`posix_openpt`; libghostty does not expose its PTY). A background
`DispatchSource`/thread reads stdout → feeds `TmuxControlParser`; stdin writes carry
outbound commands from the model.

**Authentication — bootstrap phase reusing the headless machinery.** ssh may prompt for a
password/2FA/host-key, but agterm reads stdout, not the user. Before the control handshake,
PTY bytes (ssh prompts) are rendered into a **visible headless "connecting to host"
surface**; the user sees the prompt and types, keystrokes go via `on_input` → gateway
stdin. The reader watches for the control-mode entry marker (`\x1bP1000p`, the tmux `-CC`
DCS); on detection the PTY stream **switches** from the bootstrap surface to
`TmuxControlParser`, the bootstrap surface closes, and normal session life begins. This
makes interactive login work out of the box — ssh keys are not a hard requirement.

### 5. `TmuxController` (`@MainActor`, app target) — effect executor

Bridges the host-free `TmuxSessionModel` to the real `AppStore`. Consumes
`TmuxModelEffect`:
- `createSession(windowId,name)` → create the workspace (on attach) / a session in it +
  a `HeadlessSurfaceController`.
- `routeOutput(surfaceId,bytes)` → `ghostty_surface_write_output` on that surface.
- `removeSession`/`renameSession`/`tearDownWorkspace` → corresponding `AppStore` ops.

Reverse: headless surface input/resize → model commands → `TmuxGateway.stdin`
(`send-keys -l` / `refresh-client -C`).

### 6. `HeadlessSurfaceController` (app target)

A headless variant of `GhosttySurfaceView`: creates a surface with `headless=true`, no
child process. Registers the `on_input`/`on_resize` C callbacks via the same access
pattern as `GhosttyApp.shared` (a registry keyed by surface userdata; the C closure
captures nothing). `on_input(bytes)` → copy to Swift → hop to main → `TmuxController` →
gateway `send-keys`. `on_resize(cols,rows)` → hop → `refresh-client -C`. Render/focus/
theme/scroll behave like a normal surface (the engine does not distinguish it).

**Concurrency** follows the project's C-boundary contract: copy bytes out of C before
hopping, every `@MainActor` touch via `DispatchQueue.main.async`, no `assumeIsolated`,
exactly like `GhosttyCallbacks`. The PTY reader runs on a background source; effect
execution and every libghostty call are `@MainActor`. Use the `swift-concurrency` and
`swiftui-expert` skills during implementation.

## Lifecycle and error handling

- **ssh drop / `%exit`:** the gateway process exits → `TmuxController` marks the workspace
  "disconnected" and offers manual reattach (tmux is alive server-side). Surfaces are
  frozen or removed — default TBD-resolved to: **remove on disconnect, reattach recreates
  them** (simplest; tmux is the source of truth).
- **`%error` on one of our commands:** log + notification, no crash.
- **User detach:** `detach-client` → tmux survives server-side → the local workspace is
  removed; remote sessions persist (the core tmux-mode value).
- **Unpatched engine:** if `ghostty_surface_write_output` is absent (a build without the
  patch), the feature detects itself as unavailable and disables gracefully (symbol/patch
  check at startup), no crash.

## Control API / CLI coverage (HARD keep-in-sync)

Per convention, each new command needs all four: a `Command` case in
`agtermCore/ControlProtocol`, a `ControlServer` arm, an `agtermctl` subcommand, and
round-trip + e2e tests. The agent-skill is the fifth surface.

**New connection-level `tmux.*` commands:**
- `tmux attach <host> [--session <name>] [--workspace <name>]` — start a gateway and
  attach (`-A`). Returns the connection id and created workspace.
- `tmux detach <connection-id>` — soft detach: `detach-client`, tmux survives, the local
  workspace is removed.
- `tmux list` — active tmux connections: host, tmux session, window↔session mapping,
  status (connected/disconnected).
- *(optional, for completeness)* `tmux kill <connection-id>` — `kill-session` remotely
  (hard termination vs detach).

**Existing `session.*` become backend-aware (no new commands):** operations on a
tmux-backed session must round-trip to tmux, not run locally —
`session.rename` → `rename-window`, `session.close` → `kill-window`, new session inside a
tmux workspace → `new-window`. `session.select`/navigation stay local (UI focus).
`TmuxController` intercepts lifecycle effects for tmux-backed sessions and routes them
through the gateway. Requirement: **`session.*` must be backend-aware.**

**GUI surface:** an "Attach tmux session…" menu action (host + options) and a "tmux"
indicator on the workspace/session, driven through the same `AppActions` seam as the
control command (toolbar/menu/control are three callers of one seam and must not drift).

**agent-skill** (`agterm/Resources/agent-skill/`, single source of truth): update
SKILL.md + reference.md (new `tmux.*`, backend-aware `session.*`) + examples.md
(attach/detach scenario) + troubleshooting.md (ssh drop, reattach, no-splits limit) +
the command count (44 → 46, or 47 if `tmux kill` is included). Edit only the app-repo
bundle; never the installed copies.

## Testing

- **`agtermCore` (`swift test`, host-free — primary coverage):**
  - `TmuxControlParser`: golden `-CC` transcripts → expected `TmuxEvent` stream; `%output`
    octal-escape decoding; partial lines across PTY-chunk boundaries; unknown `%…` softly
    ignored; outbound command encoder round-trip.
  - `TmuxSessionModel`: event sequences → expected `TmuxModelEffect` list (against a mock
    sink); window add/close/renamed ordering; `%output` routing by surface id;
    `%exit` → teardown; "split window → leading pane + log".
- **App target (XCUITest, isolated `AGTERM_STATE_DIR`/socket):**
  - `agtermctl tmux attach` against a **local** `tmux -CC` (localhost, no ssh —
    deterministic) → workspace + sessions created, `%output` rendered; `tmux detach` →
    workspace gone, local tmux alive; `session close` on a tmux session → `kill-window`
    remotely.
- **Engine (one-off phase-A harness):** headless surface + `ghostty_surface_write_output`
  renders; keypress caught in `on_input`. Not in CI — manual viability check.
- **CI:** unchanged — `swift test` (all `agtermCore` logic) + lint + Release app build
  (with the engine patch applied via `setup.sh`). CI does not run XCUITests.

Every build step keeps the tree green: `swift test` + `make lint` + Release build after
each; steps 1–2 are additive and do not break existing behavior, 3–5 integrate.

## Build order — Phase A (bottom-up, engine prototype first)

1. **Engine patch + prototype** (component 1): apply the `.patch` in `setup.sh`, headless
   backend + `write_output` + callbacks, prove with running code (engine harness).
   **Fork-viability gate — do not proceed until green.**
2. **`agtermCore` parser + mapping** (components 2–3): fully `swift test`-covered against a
   mock sink. No engine needed.
3. **Gateway + bootstrap + `HeadlessSurfaceController` + `TmuxController`** (components
   4–6): first real end-to-end build against local tmux.
4. **Control API / CLI + backend-aware `session.*` + e2e** (control coverage).
5. **agent-skill + GUI action + command count** (control coverage).

## Explicit v1 limitations (YAGNI boundaries)

- No splits inside a tmux window (leading pane + log).
- One tmux session per connection (how `-CC` works); multi-session / whole-server is
  future.
- Reattach after a drop is manual (button/command), no auto-reconnect loop.
- Images / Kitty graphics from remote tmux render as the engine handles them; no special
  handling.

## Risks

- **Engine fork maintenance** — the dominant long-term cost; re-apply additive hunks per
  `GHOSTTY_REV` bump. Mitigated by keeping the patch small and additive, and gated by the
  phase-1 prototype.
- **tmux protocol drift across versions** — mitigated by softly ignoring unknown `%…` and
  golden-transcript tests pinned to known tmux output.
- **Bootstrap/handshake detection** — relies on the `\x1bP1000p` control-mode marker;
  validated against real `tmux -CC` output during phase 3.
