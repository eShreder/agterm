# tmux `-CC` — Phase 4: control-API / CLI coverage (implementation plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. Activate `swift-concurrency`/`swiftui-expert` for the app-target tasks.

**Goal:** Make the tmux `-CC` feature drivable over the control channel per the project's HARD
keep-in-sync convention: add `tmux attach/detach/list/kill` across all required surfaces
(`Command` case + `ControlServer` arm + `agtermctl` subcommand + round-trip/CLI/e2e tests +
agent-skill), close one host-free Phase-3 robustness gap, and keep the bundled agent-skill
accurate. (Design spec `docs/superpowers/specs/2026-07-01-tmux-cc-native-design.md`, component 5.)

**Architecture:** A tmux connection is modeled by its **workspace** — each `attach` creates
one `tmux: <host>` workspace and one `TmuxController` (already one-per-store). The workspace's
UUID is the connection handle used by `tmux.detach/kill/list`. New protocol cases + args reuse
the existing flat `ControlArgs`/`ControlResult` Codable structs; new `agtermctl` subcommands
mirror the existing `RequestCommand` pattern; new `ControlServer` arms reuse the `resolve*`
helpers and route to `AppActions`. `tmux.list` reports the active tmux workspace(s) + windows;
`tmux.kill` is a hard `kill-session` (new outbound `TmuxCommand`), vs the soft `tmux.detach`.

**Tech Stack:** Swift 6; `agtermCore` (`swift test`) for protocol/CLI/parser; app target
(`ControlServer`/`AppActions`/`TmuxController`) built with `make build`; a local `tmux 3.7a` for
the e2e/gate. CI runs only `agtermCore`'s `swift test`.

## Global Constraints

- **HARD keep-in-sync:** every new command needs ALL of: (1) a `Command` case in
  `agtermCore`'s `ControlProtocol`, (2) a `ControlServer` arm, (3) an `agtermctl` subcommand,
  (4) round-trip + CLI + e2e tests, (5) an agent-skill entry (+ the command-count bump). None
  is optional.
- `agtermCore` host-free (no GhosttyKit/AppKit/Metal/CoreGraphics; Foundation/Darwin ok).
  `ControlProtocol`/`agtermctlKit`/parser stay in `agtermCore`; `ControlServer`/`AppActions`/
  `TmuxController` in the app target.
- **v1 connection model: one tmux connection per store**, handle = the tmux workspace UUID.
  Multi-connection-per-store is out of scope.
- Wire format is newline-delimited JSON (`Codable`). New `ControlArgs`/`ControlResult` fields
  are OPTIONAL (default nil) so the change is additive/non-breaking.
- e2e control tests in `agtermUITests/ControlAPIUITests.swift` speak the socket DIRECTLY with
  raw JSON via the existing `sendCommand(_:)` helper — NOT by shelling out to the `agtermctl`
  binary. Mirror that convention; do not add a `Process()`-based CLI e2e.
- `swift test` + `make lint` (+ `make build` for app tasks) pass after every task. Command
  count today is **46** (`ControlProtocol` has 46 `case`s; `SKILL.md` says "46 commands"); after
  the 4 tmux commands it is **50**. (The spec's "44 → 47" is stale — use 46 → 50.)
- Do NOT kill/relaunch the deployed app; the e2e/gate uses an isolated dev instance.

## Seams (verified from the codebase)

- `agtermCore/Sources/agtermCore/ControlProtocol.swift`: `public enum Command: String, Codable, Sendable`
  (46 cases, wire = raw string). Args in one flat `public struct ControlArgs: Codable, Sendable, Equatable`
  (all-optional fields; memberwise `init` with nil defaults). `ControlRequest { cmd: Command; target: String?; args: ControlArgs? }`.
  `ControlResult { id, tree, text, windows: [ControlWindowNode]?, exitCode, count, theme, themes, ... }`.
  `ControlResponse { ok: Bool; result: ControlResult?; error: String? }`.
- `agterm/Control/ControlServer.swift` (`@MainActor`): `dispatch(_:) async -> ControlResponse`
  `switch request.cmd`. Reaches `actions: AppActions`, `store` = `library.activeStore`. Arms use
  `resolveSession`/`resolvePlacementStore`/`resolveWorkspace` helpers → closure → `ControlResponse`.
- `agtermCore/Sources/agtermctlKit/Commands.swift`: `RequestCommand` protocol (`makeRequest() -> ControlRequest`,
  `defaultRun()` sends via `SocketClient`). Top-level `Agtermctl.subcommands = [Tree, Workspace, Session, …]`.
  A `Session`-style parent groups verbs.
- `agterm/AppActions.swift` (`@MainActor`): `attachTmux(host:sessionName:)` / `attachLocal(sessionName:)`
  already exist; `private var tmuxControllers: [ObjectIdentifier: TmuxController]` + `tmuxController(for:)`.
- `agterm/Tmux/TmuxController.swift` (`@MainActor`): `attach`/`attachLocal`/`detach` exist;
  `private var workspaceID: UUID?`, `private var windowToSession: [TmuxWindowID: UUID]`. No public
  identity/list/kill yet (added in Task 4).
- `agtermCore/Sources/agtermCore/TmuxCommand.swift`: outbound command enum + encoder (Phase 2/3).
- `agtermCore/Sources/agtermCore/TmuxSessionModel.swift`: `handle(.windowAdd)` returns `.createSession`
  UNCONDITIONALLY (Task 1 fixes idempotency).
- `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift` `roundTrip(_:)`; `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`
  `makeRequest`; `agtermUITests/ControlAPIUITests.swift` `sendCommand(_:)` (raw socket).
- `agterm/Resources/agent-skill/`: `SKILL.md` (`## Command summary (46 commands)`, per-noun bullets),
  `reference.md` (`## session` detailed bullets), `examples.md`, `troubleshooting.md`.

## File Structure

| File | Change |
|---|---|
| `agtermCore/.../TmuxSessionModel.swift` | guard `.windowAdd` on `!windows.contains` (idempotency) |
| `agtermCore/.../ControlProtocol.swift` | +4 `Command` cases; +`ControlArgs.host`; +`ControlResult.tmuxConnections: [ControlTmuxNode]?` + the `ControlTmuxNode` type |
| `agtermCore/.../TmuxCommand.swift` | +`killSession` case + encoder arm |
| `agtermCore/Sources/agtermctlKit/Commands.swift` | +`Tmux` parent with `Attach/Detach/List/Kill` |
| `agterm/Tmux/TmuxController.swift` | +public `workspaceID`/`host`/`windowSummaries`; +`kill()` (hard) |
| `agterm/AppActions.swift` | +`detachTmux/listTmux/killTmux` routing to controllers |
| `agterm/Control/ControlServer.swift` | +4 `tmux.*` dispatch arms |
| `agterm/Resources/agent-skill/{SKILL,reference}.md` | +tmux section, count 46→50 |
| Tests: `ControlProtocolTests`, `CommandsTests`, `TmuxSessionModelTests`, `ControlAPIUITests` | round-trip + CLI + idempotency + e2e |

---

### Task 1: `windowAdd` idempotency (Phase-3 robustness gap)

`TmuxSessionModel.handle(.windowAdd(w))` returns `.createSession` even when `w` is already
tracked, so a live `%window-add` overlapping the initial `list-windows` reply would create a
duplicate session. Guard it. Host-free, TDD.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/TmuxSessionModel.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/TmuxSessionModelTests.swift`

**Interfaces:**
- Changes: `handle(.windowAdd(w))` emits `.createSession` only when `!windows.contains(w)`; a
  repeat `windowAdd` for a tracked window emits `[]`.

- [ ] **Step 1: Write the failing test**

Append to `TmuxSessionModelTests.swift`:
```swift
    @Test func duplicateWindowAddIsIdempotent() {
        var m = TmuxSessionModel()
        #expect(m.handle(.windowAdd(TmuxWindowID("@0"))) == [.createSession(window: TmuxWindowID("@0"), name: "")])
        // A second windowAdd for the same window must NOT create a second session.
        #expect(m.handle(.windowAdd(TmuxWindowID("@0"))) == [])
    }
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter TmuxSessionModelTests 2>&1 | tail -8`
Expected: `duplicateWindowAddIsIdempotent` FAILS (second call returns `.createSession`).

- [ ] **Step 3: Implement the guard**

In `TmuxSessionModel.handle`, the `.windowAdd` case:
```swift
        case .windowAdd(let w):
            guard !windows.contains(w) else { return [] }
            windows.insert(w)
            return [.createSession(window: w, name: "")]
```

- [ ] **Step 4: Run — expect PASS + full suite**

Run: `cd agtermCore && swift test 2>&1 | tail -4`. Expected: all pass.

- [ ] **Step 5: Lint + commit**

```bash
cd /Users/eshreder/projects/agterm
make lint 2>&1 | tail -3
git add agtermCore/Sources/agtermCore/TmuxSessionModel.swift agtermCore/Tests/agtermCoreTests/TmuxSessionModelTests.swift
git commit -m "agtermCore: tmux model — windowAdd is idempotent per window"
```

---

### Task 2: protocol — 4 `tmux.*` commands + args/result types + round-trip

Add the `Command` cases, the `host` arg field, and the `tmux.list` result type; assert
encode/decode round-trip. Host-free, TDD.

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`

**Interfaces:**
- Adds `Command` cases: `tmuxAttach = "tmux.attach"`, `tmuxDetach = "tmux.detach"`,
  `tmuxList = "tmux.list"`, `tmuxKill = "tmux.kill"`.
- Adds `ControlArgs.host: String?` (attach target host; reuses existing `name` for the tmux
  session name and `workspace` for an optional workspace name).
- Adds `public struct ControlTmuxNode: Codable, Sendable, Equatable { public var id: String; public var host: String; public var windows: [String]; public init(id:host:windows:) }`
  and `ControlResult.tmuxConnections: [ControlTmuxNode]?`.
- `tmux.detach`/`tmux.kill` carry the connection id in `ControlRequest.target` (like session
  commands carry the session id there).

- [ ] **Step 1: Write the failing round-trip test**

Append to `ControlProtocolTests.swift` (mirror the existing `sessionCommandsRoundTrip` shape):
```swift
    @Test func tmuxCommandsRoundTrip() throws {
        let requests: [ControlRequest] = [
            ControlRequest(cmd: .tmuxAttach, args: ControlArgs(name: "work", host: "myhost")),
            ControlRequest(cmd: .tmuxAttach, args: ControlArgs(name: "work", workspace: "remote", host: "myhost")),
            ControlRequest(cmd: .tmuxDetach, target: "AABBCC"),
            ControlRequest(cmd: .tmuxKill, target: "AABBCC"),
            ControlRequest(cmd: .tmuxList),
        ]
        for request in requests { #expect(try roundTrip(request) == request) }
    }

    @Test func tmuxListResultRoundTrips() throws {
        let result = ControlResult(tmuxConnections: [ControlTmuxNode(id: "AABBCC", host: "myhost", windows: ["zsh", "logs"])])
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(ControlResult.self, from: data) == result)
    }
```
(If `ControlArgs`'s memberwise `init` doesn't accept `host:` yet, this won't compile — that's
the RED. If `ControlArgs` has many fields, add `host` to the init with a nil default at the
right position and pass it by label.)

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter ControlProtocolTests 2>&1 | tail -12`
Expected: compile failure (`.tmuxAttach` / `host:` / `ControlTmuxNode` / `tmuxConnections` undefined).

- [ ] **Step 3: Implement**

- Add the 4 cases to `Command` (keep them grouped, e.g. after the session cases).
- Add `public var host: String?` to `ControlArgs` (with a doc comment "Host for `tmux.attach`.")
  and a defaulted `host: String? = nil` parameter to its memberwise `init` (place it consistently
  with the field order; assign `self.host = host`).
- Add the `ControlTmuxNode` struct and `public var tmuxConnections: [ControlTmuxNode]?` to
  `ControlResult` (+ its `init` default if `ControlResult` has an explicit memberwise init;
  if it relies on the synthesized init, just add the stored property).

- [ ] **Step 4: Run — expect PASS + full suite**

Run: `cd agtermCore && swift test 2>&1 | tail -4`. Expected: all pass (existing round-trip
tests still green — additive fields don't break them).

- [ ] **Step 5: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermCore/ControlProtocol.swift agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift
git commit -m "agtermCore: control protocol — tmux.attach/detach/list/kill + args/result"
```

---

### Task 3: `agtermctl` — `Tmux` subcommand tree + CLI request tests

Add the CLI surface. Host-free, TDD (against the `makeRequest` layer).

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

**Interfaces:**
- Adds `struct Tmux: ParsableCommand` (parent, `subcommands: [Attach, Detach, List, Kill]`),
  registered in `Agtermctl.subcommands`.
- `agtermctl tmux attach <host> [--session NAME] [--workspace NAME]` → `.tmuxAttach`,
  `args = ControlArgs(name: session, workspace: workspace, host: host)`.
- `agtermctl tmux detach <id>` → `.tmuxDetach`, `target: id`.
- `agtermctl tmux list` → `.tmuxList`.
- `agtermctl tmux kill <id>` → `.tmuxKill`, `target: id`.

- [ ] **Step 1: Write the failing CLI tests**

Append to `CommandsTests.swift` (mirror the existing `sessionRename`/`sessionClose` shape — use
the file's `makeRequest`/parse helper):
```swift
    @Test func tmuxAttachBuildsRequest() throws {
        let req = try makeRequest(["tmux", "attach", "myhost", "--session", "work", "--workspace", "remote"])
        #expect(req.cmd == .tmuxAttach)
        #expect(req.args?.host == "myhost")
        #expect(req.args?.name == "work")
        #expect(req.args?.workspace == "remote")
    }
    @Test func tmuxDetachAndKillCarryTarget() throws {
        #expect(try makeRequest(["tmux", "detach", "AABBCC"]).cmd == .tmuxDetach)
        #expect(try makeRequest(["tmux", "detach", "AABBCC"]).target == "AABBCC")
        #expect(try makeRequest(["tmux", "kill", "AABBCC"]).cmd == .tmuxKill)
    }
    @Test func tmuxListBuildsRequest() throws {
        #expect(try makeRequest(["tmux", "list"]).cmd == .tmuxList)
    }
```
(Match the exact `makeRequest` helper signature already in `CommandsTests.swift` — it parses argv
into the `ParsableCommand` and returns `try command.makeRequest()`. If the helper is named
differently, use that.)

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter CommandsTests 2>&1 | tail -12`
Expected: FAIL (`tmux` subcommand unknown).

- [ ] **Step 3: Implement the subcommands**

Add to `Commands.swift`, mirroring `Session`/`Rename`:
```swift
struct Tmux: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attach/detach/list/kill tmux -CC connections.",
        subcommands: [Attach.self, Detach.self, List.self, Kill.self])
}
extension Tmux {
    struct Attach: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Attach an ssh+tmux -CC connection.")
        @Argument(help: "Host to ssh into.") var host: String
        @Option(help: "tmux session name.") var session: String?
        @Option(help: "Workspace name for the connection.") var workspace: String?
        @OptionGroup var options: ClientOptions
        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .tmuxAttach, args: options.withWindow(ControlArgs(name: session, workspace: workspace, host: host)))
        }
    }
    struct Detach: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Detach a tmux connection (session survives).")
        @Argument(help: "Connection id (workspace id).") var id: String
        @OptionGroup var options: ClientOptions
        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .tmuxDetach, target: id, args: options.withWindow()) }
    }
    struct List: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "List active tmux connections.")
        @OptionGroup var options: ClientOptions
        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .tmuxList, args: options.withWindow()) }
    }
    struct Kill: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Kill a tmux session (hard, remote).")
        @Argument(help: "Connection id (workspace id).") var id: String
        @OptionGroup var options: ClientOptions
        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .tmuxKill, target: id, args: options.withWindow()) }
    }
}
```
Register `Tmux.self` in `Agtermctl.subcommands`. (Match the real `ClientOptions`/`withWindow()`
helper names in the file — the `Tree`/`Session` subcommands show them.)

- [ ] **Step 4: Run — expect PASS + full suite**

Run: `cd agtermCore && swift test 2>&1 | tail -4`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermctlKit/Commands.swift agtermCore/Tests/agtermctlKitTests/CommandsTests.swift
git commit -m "agtermctl: tmux attach/detach/list/kill subcommands"
```

---

### Task 4: `TmuxCommand.killSession` + `TmuxController` identity/list/kill + `AppActions` routing

Give the controller a public identity (workspace id + host + window summaries), a hard `kill()`,
and add `AppActions` methods the control arms call. App target (+ a host-free `TmuxCommand` case).

**Files:**
- Modify: `agtermCore/Sources/agtermCore/TmuxCommand.swift` (+`killSession`)
- Modify: `agtermCore/Tests/agtermCoreTests/TmuxCommandTests.swift`
- Modify: `agterm/Tmux/TmuxController.swift`
- Modify: `agterm/AppActions.swift`

**Interfaces:**
- `TmuxCommand.killSession` → encodes to `"kill-session"`.
- `TmuxController`: `var connectionWorkspaceID: UUID? { workspaceID }`; `private(set) var host: String`
  (set in attach/attachLocal — "local" for attachLocal); `func windowSummaries() -> [String]`
  (session display names for its windows, via `store.session(withID:)`); `func kill()` — sends
  `.killSession` then `teardownWorkspace()`.
- `AppActions`: `func detachTmux(connectionID: String?)` (id = workspace uuid string; nil →
  the active tmux controller), `func killTmux(connectionID: String?)`, and
  `func listTmux() -> [(id: String, host: String, windows: [String])]` — each iterates
  `tmuxControllers.values`, matching `connectionWorkspaceID`.

- [ ] **Step 1: TmuxCommand.killSession (TDD)**

Append to `TmuxCommandTests.swift`: `@Test func encodesKillSession() { #expect(TmuxCommandEncoder.encode(.killSession) == "kill-session") }`.
Run → FAIL. Add `case killSession` + `case .killSession: return "kill-session"`. Run → PASS.

- [ ] **Step 2: TmuxController identity + kill**

Add to `TmuxController.swift`:
```swift
    private(set) var host: String = ""
    var connectionWorkspaceID: UUID? { workspaceID }
    func windowSummaries() -> [String] {
        windowToSession.values.compactMap { store.session(withID: $0)?.customName }
    }
    func kill() { gateway?.send(.killSession); teardownWorkspace() }
```
Set `host = host` in `attach(host:...)` and `host = "local"` in `attachLocal(...)` (at the top,
before spawning). (If `session.customName` is nil for unnamed windows, fall back to a placeholder
in `windowSummaries` — use `store.session(withID: $0)?.customName ?? "window"`.)

- [ ] **Step 3: AppActions routing methods**

Add to `AppActions.swift`:
```swift
    func detachTmux(connectionID: String?) {
        for controller in tmuxControllers.values where matches(controller, connectionID) { controller.detach(); return }
    }
    func killTmux(connectionID: String?) {
        for controller in tmuxControllers.values where matches(controller, connectionID) { controller.kill(); return }
    }
    func listTmux() -> [(id: String, host: String, windows: [String])] {
        tmuxControllers.values.compactMap { c in
            guard let wid = c.connectionWorkspaceID else { return nil }
            return (wid.uuidString, c.host, c.windowSummaries())
        }
    }
    private func matches(_ c: TmuxController, _ id: String?) -> Bool {
        guard let wid = c.connectionWorkspaceID else { return false }
        return id == nil || id == wid.uuidString
    }
```

- [ ] **Step 4: Build + lint + commit**

Run: `cd agtermCore && swift test --filter TmuxCommandTests 2>&1 | tail -4` (PASS), then
`make build 2>&1 | tail -6 && make lint 2>&1 | tail -3` (SUCCEEDED, clean).
```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermCore/TmuxCommand.swift agtermCore/Tests/agtermCoreTests/TmuxCommandTests.swift agterm/Tmux/TmuxController.swift agterm/AppActions.swift
git commit -m "app: TmuxController identity/kill + AppActions detach/list/kill routing"
```

---

### Task 5: `ControlServer` — 4 `tmux.*` dispatch arms

Wire the commands to `AppActions`. App target; build.

**Files:**
- Modify: `agterm/Control/ControlServer.swift`

**Interfaces:**
- Consumes `AppActions.attachTmux`/`detachTmux`/`killTmux`/`listTmux`; produces `ControlResponse`s.

- [ ] **Step 1: Add the arms**

In `dispatch(_:)`'s switch:
```swift
        case .tmuxAttach:
            guard let host = request.args?.host else {
                return ControlResponse(ok: false, error: "tmux.attach requires a host")
            }
            actions.attachTmux(host: host, sessionName: request.args?.name ?? "main")
            return ControlResponse(ok: true)
        case .tmuxDetach:
            actions.detachTmux(connectionID: request.target)
            return ControlResponse(ok: true)
        case .tmuxKill:
            actions.killTmux(connectionID: request.target)
            return ControlResponse(ok: true)
        case .tmuxList:
            let nodes = actions.listTmux().map { ControlTmuxNode(id: $0.id, host: $0.host, windows: $0.windows) }
            return ControlResponse(ok: true, result: ControlResult(tmuxConnections: nodes))
```
(Match the surrounding arms' `ControlResponse` construction. If `actions` isn't directly reachable
in the switch context, use the same reference the `session.*`/`workspace.*` arms use — the map
confirms `ControlServer` holds `actions: AppActions`.)

- [ ] **Step 2: Build + lint + commit**

Run: `make build 2>&1 | tail -6 && make lint 2>&1 | tail -3` (SUCCEEDED, clean).
```bash
cd /Users/eshreder/projects/agterm
git add agterm/Control/ControlServer.swift
git commit -m "app: ControlServer — tmux.attach/detach/list/kill arms"
```

---

### Task 6: e2e — raw-socket tmux control tests + Phase-4 gate

Add XCUITest coverage driving the socket directly (mirroring `sendCommand`), and re-verify the
whole path (controller-run gate) against local tmux.

**Files:**
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [ ] **Step 1: Add the e2e test**

Mirror the file's `sendCommand(_:)` raw-socket helper + isolated-socket setup. Because a real
`tmux.attach` needs a live tmux and is timing-heavy, keep the e2e focused and deterministic:
assert the PROTOCOL contract that doesn't need a live server — `tmux.list` on a fresh instance
returns `ok: true` with an empty (or absent) `tmuxConnections`, and `tmux.attach` with no `host`
returns `ok: false` with the "requires a host" error. (A full attach→list→detach against local
tmux is exercised by the controller-run gate in Step 3, not the sandboxed XCUITest runner, which
can't spawn tmux reliably.)
```swift
    func testTmuxListEmptyAndAttachValidation() throws {
        let list = try sendCommand(#"{"cmd":"tmux.list"}"#)
        XCTAssertEqual(list["ok"] as? Bool, true)
        let bad = try sendCommand(#"{"cmd":"tmux.attach","args":{}}"#)
        XCTAssertEqual(bad["ok"] as? Bool, false)
    }
```
(Adapt to the file's actual `sendCommand` signature/return type — it decodes to `[String: Any]`.)

- [ ] **Step 2: Run the XCUITest**

Run the control e2e (the file's scheme). Confirm the new test passes. (This runs locally, not in
CI, per the project's CI setup.)

- [ ] **Step 3: Phase-4 gate (controller-run) — full CLI path against local tmux**

The controller runs this: local tmux (2 windows), a patched dev instance, then drive the REAL
`agtermctl` against the isolated socket:
```bash
TMUXBIN=/opt/homebrew/bin/tmux
"$TMUXBIN" -L agtgate kill-server 2>/dev/null
"$TMUXBIN" -L agtgate new-session -d -s agtgate -x 80 -y 24
"$TMUXBIN" -L agtgate new-window -t agtgate -n second
TMP=$(mktemp -d); CTL=build/DerivedData/Build/Products/Debug/agterm.app/Contents/MacOS/agtermctl
open -n --env AGTERM_TMUX_LOCAL=1 --env AGTERM_TMUX_BIN="$TMUXBIN" --env AGTERM_TMUX_SOCKET=agtgate \
        --env AGTERM_STATE_DIR="$TMP" --env AGTERM_CONTROL_SOCKET="$TMP/agterm.sock" build/DerivedData/Build/Products/Debug/agterm.app
sleep 8
"$CTL" tmux list --socket "$TMP/agterm.sock"     # expect the local connection with windows zsh/second
```
Expected: `tmux list` reports the local connection + its windows. Then optionally
`agtermctl tmux detach <id> --socket …` and confirm the workspace disappears from `agtermctl tree`.
Quit the dev instance by PID; do not touch the deployed app.

- [ ] **Step 4: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermUITests/ControlAPIUITests.swift
git commit -m "test: tmux control-api e2e (raw socket) + list/attach validation"
```

---

### Task 7: agent-skill — tmux section + command-count bump

Update the bundled skill (the fifth keep-in-sync surface). Edit ONLY the app-repo bundle, never
the installed copies.

**Files:**
- Modify: `agterm/Resources/agent-skill/SKILL.md`
- Modify: `agterm/Resources/agent-skill/reference.md`

- [ ] **Step 1: SKILL.md**

Change `## Command summary (46 commands)` → `## Command summary (50 commands)`. Add a `**tmux**`
bullet block in the command summary (after the `**session**` block):
```
**tmux**
- `attach <host> [--session NAME] [--workspace NAME]` — start an ssh + `tmux -CC` connection; its windows become native sessions.
- `detach <id>` — detach (the tmux session survives on the server). · `kill <id>` — hard `kill-session`. · `list` — active connections + their windows.
```

- [ ] **Step 2: reference.md**

Add a `## tmux` section (after `## session`) with one detailed bullet per command:
```
## tmux

- `tmux attach <host> [--session NAME] [--workspace NAME]` — spawn `ssh <host> tmux -CC …`; each tmux window becomes an agterm session in a `tmux: <host>` workspace. No splits (a split window shows its leading pane).
- `tmux detach <id>` — soft detach (`detach-client`); the local workspace is removed, the remote tmux session persists for reattach. `<id>` is the connection/workspace id from `tmux list`.
- `tmux kill <id>` — hard `kill-session` on the remote; the tmux session is destroyed.
- `tmux list` — active tmux connections: `id`, `host`, window names.
```

- [ ] **Step 3: Verify count + commit**

Confirm the ControlProtocol case count matches the doc: `grep -c "case " agtermCore/Sources/agtermCore/ControlProtocol.swift` should read 50.
```bash
cd /Users/eshreder/projects/agterm
git add agterm/Resources/agent-skill/SKILL.md agterm/Resources/agent-skill/reference.md
git commit -m "skill: document tmux attach/detach/list/kill (command count 46->50)"
```

---

## Self-Review

**Spec coverage (component 5, control-API half):** `tmux.attach/detach/list/kill` across all five
keep-in-sync surfaces — protocol (Task 2), server (Task 5), CLI (Task 3), tests (Tasks 2/3/6),
agent-skill (Task 7); plus the host-free Phase-3 hardening gap (Task 1) and the `TmuxController`
list/kill identity needed to drive them (Task 4). ✓
- **Deferred to Phase 5 (correctly out of scope):** backend-aware `session.rename`/`session.close`
  (needs a `Session.tmuxBinding` field + the AppActions seam routed from both the sidebar and the
  control arm), the GUI "Attach tmux session…" menu item + NSAlert prompt, and the remaining
  app-target Phase-3 hardening (surface spawn-error, don't persist mirror workspaces, os.Logger).
  These are noted in the ledger and the design spec's keep-in-sync section.

**Placeholder scan:** Tasks 1–3 are host-free TDD with complete code. Tasks 4–5 are app-target with
complete new-code + exact edit points, verified by `make build`. Task 6's XCUITest asserts the
protocol contract deterministically; the full CLI-against-local-tmux path is the controller-run
gate (Step 3), consistent with the project's "CI doesn't run XCUITests / real-tmux is a local
gate" reality. Task 7 has the exact doc edits + the count-verify command.

**Type consistency:** `Command.tmuxAttach/tmuxDetach/tmuxList/tmuxKill`, `ControlArgs.host`,
`ControlTmuxNode`, `ControlResult.tmuxConnections`, `TmuxCommand.killSession`,
`TmuxController.connectionWorkspaceID`/`host`/`windowSummaries()`/`kill()`,
`AppActions.attachTmux`/`detachTmux(connectionID:)`/`killTmux(connectionID:)`/`listTmux()` are
named consistently across the protocol, CLI, server, controller, and tests.
