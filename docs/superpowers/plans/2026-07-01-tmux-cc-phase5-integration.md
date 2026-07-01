# tmux `-CC` — Phase 5: native integration (backend-aware session.*, GUI, hardening)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. Activate `swift-concurrency`/`swiftui-expert` for the app-target tasks.

**Goal:** Finish the "ssh + tmux like iTerm2" experience: renaming or closing a tmux-backed
session round-trips to tmux (`rename-window`/`kill-window`); a GUI "Attach tmux session…" menu
item; the ephemeral tmux mirror workspace is not persisted to `workspaces.json`; plus the cheap
deferred hardening. (Design spec `docs/superpowers/specs/2026-07-01-tmux-cc-native-design.md`,
"backend-aware `session.*`" + GUI + lifecycle.)

**Architecture:** A `Session.tmuxBinding` (host-free `{connectionID, window}`, `@ObservationIgnored`,
never persisted) marks a session as tmux-backed. `AppActions` gains backend-aware
`renameSession`/`closeSession` wrappers that, for a bound session, route to the owning
`TmuxController` (`rename-window`/`kill-window`) instead of the local `AppStore` mutation; the
three user-initiated call sites (sidebar rename-commit, sidebar menu-close, `closeActiveSession`)
plus the two `ControlServer` arms route through these wrappers. The tmux→local ECHO direction
(`TmuxController.apply` → `store.renameSession`/`closeSession`) stays on the raw store methods, so
there is no loop. The mirror workspace is flagged `Workspace.ephemeral` and filtered out of the
one snapshot builder.

**Tech Stack:** Swift 6; `agtermCore` (`swift test`) for the model fields + snapshot; app target
(`AppActions`/`TmuxController`/`ControlServer`/`WorkspaceSidebar`/menu) built with `make build`;
a local `tmux -CC` for the live gate.

## Global Constraints

- `agtermCore` host-free (no GhosttyKit/AppKit/Metal/CoreGraphics). `Session.tmuxBinding`,
  `TmuxBinding`, `Workspace.ephemeral`, and the snapshot skip are host-free. The `AppActions`/
  `TmuxController`/`ControlServer`/sidebar/menu wiring is app-target.
- **No persistence of tmux mirror state:** `tmuxBinding` is absent from `SessionSnapshot`
  (allow-list); the ephemeral workspace is filtered from `AppStore.snapshot()`. A relaunch must
  never restore a phantom `tmux: …` workspace or shell.
- **No rename/close loop:** the backend-aware wrappers are for USER-initiated ops only. The
  `TmuxController.apply(_ effect:)` echo path keeps calling `store.renameSession`/`store.closeSession`
  directly (the raw local mutation) — do NOT route it through the new wrappers.
- **Keep-in-sync:** `session.rename`/`session.close` gain no new command, but their SEMANTICS change
  (backend-aware). Update the agent-skill `## session` notes accordingly (the 5th surface).
- `swift test` + `make lint` (+ `make build` for app tasks) pass after every task. Do NOT
  kill/relaunch the deployed app; the gate uses an isolated dev instance quit by PID.

## Seams (verified)

- Sidebar rename/close call DIRECTLY into the store: `WorkspaceSidebar.swift:1068`
  `store.renameSession(node.id, to: newValue)`, `:1200` `store.closeSession(node.id)`. The
  Coordinator already holds an `AppActions` (used for delete), so it can route through it.
- `AppActions`: `closeActiveSession()` (`:102-111`, calls `store.closeSession`); `renameActiveSession()`
  (`:475`, only posts `.agtermBeginRenameSession` — the real rename lands in the sidebar commit).
  `attachTmux(host:sessionName:workspaceName:)` (`:138`), `tmuxController(for:)` cache (`:127`).
- `TmuxController` (`@MainActor`): `windowToSession: [TmuxWindowID: UUID]` (`:23`, no reverse yet);
  echo direction at `:164/167/169` (`store.renameSession`/`store.closeSession`); `gateway?.send(...)`
  (`:55`). `TmuxCommand.renameWindow(_,name:)`/`killWindow(_)` encoders already exist
  (`rename-window -t @N <name>` / `kill-window -t @N`).
- `Session.swift`: no tmux field; ephemeral `@ObservationIgnored` precedent = `initialCommand`
  (`:101`). `SessionSnapshot` (`Snapshot.swift:59-105`) is a 10-field allow-list built by an
  explicit `SessionSnapshot(...)` call in `AppStore.snapshot()` (`AppStore.swift:667-672`) — a new
  `Session` field is omitted unless listed there.
- `AppStore.snapshot()` builds `workspaces.map { WorkspaceSnapshot(...) }` at `:665`; `Workspace`
  (`Workspace.swift:6-21`) is `{id, name, sessions}` (no flag). `save()` (`:728`) → `persistence.save(snapshot())`.
- `ControlServer` session arms: `.sessionRename` (`:417`, `store.renameSession`), `.sessionClose`
  (`:412`, `store.closeSession`).
- Menu: `CommandGroup(replacing: .newItem)` Session section (`agtermApp.swift:236-254`), `Button("New Session") { actions.newSession() }` precedent. NSAlert-with-accessory precedent: `AppActions.renameActiveWindow()` (`:441-456`).

## File Structure

| File | Change |
|---|---|
| `agtermCore/.../TmuxIDs.swift` (or new `TmuxBinding.swift`) | `public struct TmuxBinding { connectionID: UUID; window: TmuxWindowID }` |
| `agtermCore/.../Session.swift` | `@ObservationIgnored public var tmuxBinding: TmuxBinding?` |
| `agtermCore/.../Workspace.swift` | `public var ephemeral: Bool = false` |
| `agtermCore/.../AppStore.swift` | `addWorkspace(name:ephemeral:)`; `snapshot()` filters `!ephemeral` |
| `agterm/Tmux/TmuxController.swift` | set `tmuxBinding` on createSession, mark workspace ephemeral, `renameWindow(session:to:)`/`killWindow(session:)`, `os.Logger` |
| `agterm/AppActions.swift` | backend-aware `renameSession`/`closeSession` wrappers; `attachTmuxPrompt()`; `attachTmux`→Bool |
| `agterm/Views/WorkspaceSidebar.swift` | route rename-commit + menu-close through `actions` |
| `agterm/Control/ControlServer.swift` | `.sessionRename`/`.sessionClose` route through `actions`; `.tmuxAttach` no-window→error |
| `agterm/agtermApp.swift` | "Attach tmux session…" menu item |
| `agterm/Resources/agent-skill/{SKILL,reference}.md` | note backend-aware `session.rename`/`close` |
| Tests: `SessionTests`/`WorkspaceTests`/`PersistenceTests` | tmuxBinding not persisted; ephemeral workspace skipped |

---

### Task 1: host-free model — `TmuxBinding`, `Session.tmuxBinding`, `Workspace.ephemeral`, snapshot skip

Add the marker types + the persistence skip, all host-free and TDD. Deliverable: a `tmuxBinding`
never lands in `SessionSnapshot`, and an `ephemeral` workspace is absent from the snapshot.

**Files:**
- Create: `agtermCore/Sources/agtermCore/TmuxBinding.swift`
- Modify: `agtermCore/Sources/agtermCore/Session.swift`, `Workspace.swift`, `AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/PersistenceTests.swift` (or `WorkspaceTests`/`AppStoreTests` — whichever holds snapshot tests)

**Interfaces:**
- `public struct TmuxBinding: Equatable, Sendable { public let connectionID: UUID; public let window: TmuxWindowID; public init(connectionID: UUID, window: TmuxWindowID) }`
- `Session.tmuxBinding: TmuxBinding?` (`@ObservationIgnored`, NOT in `SessionSnapshot`).
- `Workspace.ephemeral: Bool` (default false).
- `AppStore.addWorkspace(name: String, ephemeral: Bool = false) -> Workspace`; `snapshot()` filters `workspaces.filter { !$0.ephemeral }`.

- [ ] **Step 1: Write the failing tests**

Find the file with snapshot/persistence tests (`grep -l "snapshot()" agtermCore/Tests/agtermCoreTests/*.swift`). Add, matching its `@MainActor`/setup style:
```swift
    @Test @MainActor func ephemeralWorkspaceIsNotSnapshotted() {
        let store = AppStore(/* match existing test init */)
        let normal = store.addWorkspace(name: "keep")
        let mirror = store.addWorkspace(name: "tmux: host", ephemeral: true)
        let snap = store.snapshot()
        #expect(snap.workspaces.contains { $0.id == normal.id })
        #expect(!snap.workspaces.contains { $0.id == mirror.id })
    }

    @Test @MainActor func tmuxBindingIsNotPersisted() {
        let store = AppStore(/* match */)
        let ws = store.addWorkspace(name: "w")
        guard let session = store.addSession(toWorkspace: ws.id, cwd: "/tmp") else { Issue.record("no session"); return }
        session.tmuxBinding = TmuxBinding(connectionID: UUID(), window: TmuxWindowID("@0"))
        let snap = store.snapshot()
        // The session is snapshotted, but SessionSnapshot has no tmuxBinding field at all.
        #expect(snap.workspaces.first(where: { $0.id == ws.id })?.sessions.contains { $0.id == session.id } == true)
    }
```
(Adapt the `AppStore(...)` init + `SessionSnapshot` field access to the real test-helper shape in that file.)

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter <thatSuite> 2>&1 | tail -12`
Expected: compile failure (`TmuxBinding`/`tmuxBinding`/`ephemeral:` undefined) then, after the types exist but before the snapshot filter, `ephemeralWorkspaceIsNotSnapshotted` FAILS.

- [ ] **Step 3: Implement**

`TmuxBinding.swift`: the struct above. `Session.swift`: add
`@ObservationIgnored public var tmuxBinding: TmuxBinding?` with an `initialCommand`-style doc
comment ("`@ObservationIgnored` + absent from `snapshot()`: ephemeral tmux mirror state, never
persisted"). `Workspace.swift`: add `public var ephemeral: Bool = false` (with a doc comment). In
`AppStore.addWorkspace`, add `ephemeral: Bool = false` and set it on the created `Workspace`. In
`AppStore.snapshot()`, change `workspaces.map` → `workspaces.filter { !$0.ephemeral }.map`. Do NOT
add `tmuxBinding` to the `SessionSnapshot(...)` call.

- [ ] **Step 4: Run — expect PASS + full suite**

Run: `cd agtermCore && swift test 2>&1 | tail -4`. Expected: all pass (adding a defaulted
`Workspace.ephemeral` and an `addWorkspace` param must not break existing tests — confirm the
`Workspace` memberwise init callers still compile; if `Workspace(id:name:sessions:)` is called
positionally anywhere, add `ephemeral` with a default at the end).

- [ ] **Step 5: Lint + commit**

```bash
cd /Users/eshreder/projects/agterm
make lint 2>&1 | tail -3
git add agtermCore/Sources/agtermCore/TmuxBinding.swift agtermCore/Sources/agtermCore/Session.swift agtermCore/Sources/agtermCore/Workspace.swift agtermCore/Sources/agtermCore/AppStore.swift agtermCore/Tests/agtermCoreTests/
git commit -m "agtermCore: Session.tmuxBinding + ephemeral workspace (not persisted)"
```

---

### Task 2: `TmuxController` — set binding, mark ephemeral, reverse rename/kill, os.Logger

Wire the model: when the controller seeds a session, set its `tmuxBinding`; mark the mirror
workspace ephemeral; add the local→tmux `renameWindow(session:to:)`/`killWindow(session:)`;
switch diagnostics to `os.Logger`. App target; build.

**Files:**
- Modify: `agterm/Tmux/TmuxController.swift`

**Interfaces:**
- Consumes `Session.tmuxBinding`, `Workspace.ephemeral`, `AppStore.addWorkspace(ephemeral:)`,
  `TmuxCommand.renameWindow`/`killWindow`.
- Produces: `func renameWindow(session sessionID: UUID, to name: String) -> Bool` (true if the
  session is one of ours → `gateway?.send(.renameWindow(window, name: name))`); `func killWindow(session sessionID: UUID) -> Bool`
  (true → `gateway?.send(.killWindow(window))`). Both reverse-lookup `windowToSession`.

- [ ] **Step 1: Mark ephemeral + set binding**

In `attach`/`attachLocal`, change `store.addWorkspace(name: …)` → `store.addWorkspace(name: …, ephemeral: true)`.
In `apply(.createSession)`, after `session.surface = …`, set
`session.tmuxBinding = TmuxBinding(connectionID: workspaceID!, window: window)` (the connection id =
the mirror workspace id, matching `connectionWorkspaceID`).

- [ ] **Step 2: Reverse rename/kill**

```swift
    private func window(forSession sessionID: UUID) -> TmuxWindowID? {
        windowToSession.first(where: { $0.value == sessionID })?.key
    }
    @discardableResult func renameWindow(session sessionID: UUID, to name: String) -> Bool {
        guard let w = window(forSession: sessionID) else { return false }
        gateway?.send(.renameWindow(w, name: name)); return true
    }
    @discardableResult func killWindow(session sessionID: UUID) -> Bool {
        guard let w = window(forSession: sessionID) else { return false }
        gateway?.send(.killWindow(w)); return true
    }
```

- [ ] **Step 3: os.Logger**

Replace the `NSLog("tmux: \(message)")` diagnostic with a `private static let log = Logger(subsystem: "com.umputun.agterm", category: "tmux")` (`import os`) and `Self.log.info("\(message, privacy: .public)")`. (Match the app's existing `os.Logger` usage if any — `grep -rn "os.Logger\|Logger(subsystem" agterm/` for the exact subsystem string; reuse it.)

- [ ] **Step 4: Build + lint + commit**

Run: `make build 2>&1 | tail -6 && make lint 2>&1 | tail -3` (SUCCEEDED, clean).
```bash
cd /Users/eshreder/projects/agterm
git add agterm/Tmux/TmuxController.swift
git commit -m "app: TmuxController sets tmuxBinding + ephemeral workspace + reverse rename/kill + os.Logger"
```

---

### Task 3: backend-aware `AppActions.renameSession`/`closeSession` + route the user sites

The core. Add wrappers that route tmux-backed sessions to the controller, and make the three
user-initiated sites + the two control arms call them. App target; build + live gate.

**Files:**
- Modify: `agterm/AppActions.swift`, `agterm/Views/WorkspaceSidebar.swift`, `agterm/Control/ControlServer.swift`

**Interfaces:**
- `AppActions.renameSession(_ id: UUID, to name: String)` — if the session has a `tmuxBinding`, find
  the matching `TmuxController` and `renameWindow(session:to:)`; else `store.renameSession(id, to:)`.
- `AppActions.closeSession(_ id: UUID)` — same shape with `killWindow(session:)` / `store.closeSession(id)`.

- [ ] **Step 1: AppActions wrappers**

```swift
    func renameSession(_ id: UUID, to name: String) {
        guard let store else { return }
        if let session = store.session(withID: id), let binding = session.tmuxBinding,
           let controller = tmuxControllers[bindingKey(binding)] ?? tmuxControllerOwning(id) {
            _ = controller.renameWindow(session: id, to: name); return
        }
        store.renameSession(id, to: name)
    }
    func closeSession(_ id: UUID) {
        guard let store else { return }
        if let session = store.session(withID: id), session.tmuxBinding != nil,
           let controller = tmuxControllerOwning(id) {
            _ = controller.killWindow(session: id); return
        }
        store.closeSession(id)
    }
    private func tmuxControllerOwning(_ sessionID: UUID) -> TmuxController? {
        tmuxControllers.values.first { $0.owns(session: sessionID) }
    }
```
Add `TmuxController.owns(session:) -> Bool` (`window(forSession:) != nil`) to Task 2 (or here).
Simplify: since `tmuxControllerOwning` already resolves the controller, the `renameSession` guard
only needs `session.tmuxBinding != nil` + `tmuxControllerOwning(id)` (drop the `bindingKey` path).
Keep it minimal.

- [ ] **Step 2: Route `closeActiveSession` + the sidebar**

- `AppActions.closeActiveSession()`: replace its `store.closeSession(session.id)` with
  `closeSession(session.id)` (the new wrapper).
- `WorkspaceSidebar.swift:1068` (rename commit): `store.renameSession(node.id, to: newValue)` →
  route through the Coordinator's `actions` — `actions.renameSession(node.id, to: newValue)`. Confirm
  the Coordinator has an `actions: AppActions` (it does for delete); if the reference is optional,
  guard it and fall back to `store.renameSession` so a nil-actions path still renames locally.
- `WorkspaceSidebar.swift:1200` (menu close): `store.closeSession(node.id)` → `actions.closeSession(node.id)`
  (same guard/fallback).

- [ ] **Step 3: Route the ControlServer arms**

- `.sessionRename` arm: `store.renameSession(id, to: name)` → `actions.renameSession(id, to: name)`.
- `.sessionClose` arm: `store.closeSession(id)` → `actions.closeSession(id)`.
(Keep the `resolveSession` target resolution + the `ControlResult(id:)` response; only the mutation
call changes.)

- [ ] **Step 4: Build + lint**

Run: `make build 2>&1 | tail -6 && make lint 2>&1 | tail -3` (SUCCEEDED, clean).

- [ ] **Step 5: Live gate (controller-run) — backend-aware rename round-trips to tmux**

The controller runs: local tmux (2 windows) → dev instance → `agtermctl session rename` a tmux
session → confirm the tmux window is renamed remotely:
```bash
TMUXBIN=/opt/homebrew/bin/tmux
"$TMUXBIN" -L agtgate kill-server 2>/dev/null
"$TMUXBIN" -L agtgate new-session -d -s agtgate -x 80 -y 24
"$TMUXBIN" -L agtgate new-window -t agtgate -n second
TMP=$(mktemp -d); CTL=build/DerivedData/Build/Products/Debug/agterm.app/Contents/MacOS/agtermctl
open -n --env AGTERM_TMUX_LOCAL=1 --env AGTERM_TMUX_BIN="$TMUXBIN" --env AGTERM_TMUX_SOCKET=agtgate \
        --env AGTERM_STATE_DIR="$TMP" --env AGTERM_CONTROL_SOCKET="$TMP/agterm.sock" build/DerivedData/Build/Products/Debug/agterm.app
sleep 8
# rename the first tmux session (window @0) via the control channel
sid=$("$CTL" tree --json --socket "$TMP/agterm.sock" | jq -r '.result.tree.workspaces[] | select(.name|startswith("tmux")) | .sessions[0].id')
"$CTL" session rename "renamed-remotely" --target "$sid" --socket "$TMP/agterm.sock"
sleep 1
"$TMUXBIN" -L agtgate list-windows -t agtgate   # expect window 0 name = "renamed-remotely"
```
Expected: the remote tmux window is renamed (proving `session.rename` → `rename-window`). Quit by
PID; kill the tmux server.

- [ ] **Step 6: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agterm/AppActions.swift agterm/Views/WorkspaceSidebar.swift agterm/Control/ControlServer.swift
git commit -m "app: backend-aware session.rename/close route to tmux rename-window/kill-window"
```

---

### Task 4: GUI "Attach tmux session…" menu + prompt

Add the menu item + the NSAlert host/session prompt. App target; build.

**Files:**
- Modify: `agterm/AppActions.swift`, `agterm/agtermApp.swift`

- [ ] **Step 1: `attachTmuxPrompt()`**

In `AppActions.swift`, mirror `renameActiveWindow()`'s NSAlert-with-accessory pattern but with two
stacked `NSTextField`s (host, optional session) in a container `NSView`:
```swift
    func attachTmuxPrompt() {
        let alert = NSAlert()
        alert.messageText = "Attach tmux Session"
        alert.informativeText = "ssh host, and the tmux session name (default: main)."
        alert.addButton(withTitle: "Attach"); alert.addButton(withTitle: "Cancel")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        let hostField = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        hostField.placeholderString = "user@host"
        let sessionField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        sessionField.placeholderString = "session (default: main)"
        container.addSubview(hostField); container.addSubview(sessionField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = hostField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        let session = sessionField.stringValue.trimmingCharacters(in: .whitespaces)
        attachTmux(host: host, sessionName: session.isEmpty ? "main" : session)
    }
```

- [ ] **Step 2: Menu item**

In `agtermApp.swift`'s `CommandGroup(replacing: .newItem)` Session section (after the Session items,
before the following `Divider()`):
```swift
                Button("Attach tmux Session…") { actions.attachTmuxPrompt() }
```

- [ ] **Step 3: Build + lint + commit**

Run: `make build 2>&1 | tail -6 && make lint 2>&1 | tail -3`.
```bash
cd /Users/eshreder/projects/agterm
git add agterm/AppActions.swift agterm/agtermApp.swift
git commit -m "app: File ▸ Attach tmux Session… menu item + host/session prompt"
```

---

### Task 5: `tmux.attach` no-window → error (attach returns Bool)

Cheap hardening from the Phase-4 review: `agtermctl tmux attach` on an app with no open window
silently returns ok. Make `attachTmux` report success. App target; build.

**Files:**
- Modify: `agterm/AppActions.swift`, `agterm/Control/ControlServer.swift`

- [ ] **Step 1: `attachTmux` → Bool**

Change `AppActions.attachTmux(host:sessionName:workspaceName:)` to return `Bool` (`false` when
`store == nil`, else attach + `true`). The GUI caller (`attachTmuxPrompt`) can ignore the result
(`@discardableResult`), and `attachLocal` is unaffected.

- [ ] **Step 2: `.tmuxAttach` arm surfaces the error**

```swift
        case .tmuxAttach:
            guard let host = request.args?.host else {
                return ControlResponse(ok: false, error: "tmux.attach requires a host")
            }
            let ok = actions.attachTmux(host: host, sessionName: request.args?.name ?? "main",
                                        workspaceName: request.args?.workspace)
            return ok ? ControlResponse(ok: true) : ControlResponse(ok: false, error: "no open window")
```

- [ ] **Step 3: Build + lint + commit**

Run: `make build 2>&1 | tail -6 && make lint 2>&1 | tail -3`.
```bash
cd /Users/eshreder/projects/agterm
git add agterm/AppActions.swift agterm/Control/ControlServer.swift
git commit -m "app: tmux.attach surfaces 'no open window' instead of a silent ok"
```

---

### Task 6: agent-skill — backend-aware `session.*` note

Document the changed semantics (the 5th keep-in-sync surface). Edit ONLY the app-repo bundle.

**Files:**
- Modify: `agterm/Resources/agent-skill/SKILL.md`, `reference.md`

- [ ] **Step 1: Annotate session rename/close**

In `reference.md`'s `## session` section, on the `session rename`/`session close` bullets, add a
sentence: "For a tmux-backed session (attached via `tmux attach`), rename routes to the remote
`rename-window` and close to `kill-window` — the change lands on the tmux server." Add the same
one-line note to the `**session**` block in `SKILL.md` if it lists rename/close, else to the `**tmux**`
block ("renaming/closing a tmux-backed session round-trips to tmux"). Do NOT change the command
count (no new command).

- [ ] **Step 2: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agterm/Resources/agent-skill/SKILL.md agterm/Resources/agent-skill/reference.md
git commit -m "skill: note backend-aware session.rename/close for tmux sessions"
```

---

## Self-Review

**Spec coverage:** backend-aware `session.rename`/`session.close` (Tasks 1–3), the ephemeral-workspace
non-persistence (Task 1), GUI "Attach…" (Task 4), the cheap hardening (`os.Logger` Task 2,
`tmux.attach` no-window error Task 5), agent-skill note (Task 6). ✓
- **Deferred (documented, low value):** `--window` for the tmux subcommands (meaningful only for
  attach; the flag is inert but harmless — drop or wire when multi-window attach is wanted), the
  ragged `windowSummaries` indentation (cosmetic, lint-clean), and surface spawn-error UX (a failed
  `ssh` leaves an empty workspace — a Phase-6 polish). Multi-connection-per-store is still future.

**Placeholder scan:** Task 1 is host-free TDD with real assertions. Tasks 2–5 are app-target with
complete new-code + exact edit points, verified by `make build` + the Task-3 live gate (the
decisive "rename round-trips to tmux" check). Task 6 is a docs note.

**Type consistency:** `TmuxBinding`, `Session.tmuxBinding`, `Workspace.ephemeral`,
`AppStore.addWorkspace(ephemeral:)`, `TmuxController.renameWindow(session:to:)`/`killWindow(session:)`/`owns(session:)`,
`AppActions.renameSession(_:to:)`/`closeSession(_:)`/`attachTmuxPrompt()`/`attachTmux(...)->Bool` are
named consistently across the model, controller, actions, sidebar, server, and tests. The echo path
(`TmuxController.apply` → `store.renameSession`/`store.closeSession`) is deliberately NOT routed
through the new wrappers (loop prevention), and the wrappers guard on `tmuxBinding` so a normal
session still mutates locally.
