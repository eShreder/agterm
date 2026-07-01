# tmux `-CC` — Phase 3: gateway + headless surfaces + controller (implementation plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Activate `swift-concurrency` and `swiftui-expert` for the app-target tasks (4–6).

**Goal:** Wire the host-free tmux protocol layer (Phase 2) into a running attach: a
subprocess PTY driving `ssh … tmux -CC`, a gateway that turns its bytes into `TmuxEvent`s
(with an ssh-auth bootstrap phase), and an app-target `TmuxController` that turns
`TmuxModelEffect`s into a live agterm workspace whose sessions are headless libghostty
surfaces — tmux windows appear as native sessions, output renders, keystrokes and resizes
round-trip back to tmux. (Design spec:
`docs/superpowers/specs/2026-07-01-tmux-cc-native-design.md`, component 4 + lifecycle.)

**Architecture:** Most of the work is host-free and lives in `agtermCore`: a `PTYProcess`
(spawn a command with a pty via `posix_openpt`/`posix_spawn`, async-read stdout, write
stdin), a `TmuxGateway` (PTYProcess + `TmuxControlParser` + handshake detection + outbound
`TmuxCommand` send), and a `TmuxWindowList` parser (the initial `list-windows` block →
windows). Only the thin `@MainActor` glue is in the app target: `TmuxController` bridges
gateway events → `AppStore`/`Session`/headless `GhosttySurfaceView`, plus a small
pending-output buffer on the surface and the attach entry point.

**Tech Stack:** Swift 6 strict concurrency; `agtermCore` (Foundation + Darwin, `swift test`)
for the host-free parts; app target (AppKit + libghostty bridge) for the controller;
XcodeGen/xcodebuild for the app build; a real local `tmux 3.7a` for the manual end-to-end
gate.

## Global Constraints

- `agtermCore` must NOT import GhosttyKit/AppKit/Metal/CoreGraphics (no `CGSize`/`CGPoint`/`CGRect`/`CGFloat`).
  `import Foundation` and `import Darwin` ARE allowed there (PTYProcess uses Darwin pty +
  posix_spawn APIs). Tasks 1–3 stay in `agtermCore`, tested with `swift test`.
- App-target types touching `Session`/`AppStore`/`GhosttySurfaceView` are `@MainActor`.
  Any gateway callback that arrives off-main MUST copy bytes into Swift value types and hop
  via `DispatchQueue.main.async` before touching those — never `MainActor.assumeIsolated`
  in a C trampoline or a pipe-read handler (mirror `GhosttyCallbacks`).
- `Session`, `AppStore`, `AppActions`, `GhosttySurfaceView`, `TerminalSurface`, `GhosttyApp`
  are `@MainActor`. `AppStore` mutation is the ONLY way to change workspaces/sessions.
- CI runs only `agtermCore`'s `swift test` (not the app target). So Tasks 1–3 carry the
  automated coverage; the gateway test must NOT depend on a real `tmux` being installed on
  the test host — drive it with a scripted subprocess that emits a captured `-CC` transcript.
  Real-tmux end-to-end is the manual Phase-3 gate (Task 6), run locally.
- `swift test` + `make lint` + (for Tasks 4–6) `make build` must pass after every task. Do
  NOT kill/relaunch the deployed `~/Applications/agterm.app`; the gate uses an isolated dev
  instance quit by PID.
- v1 scope (unchanged): no splits (leading pane only); manual reattach; one tmux session per
  connection.

## Integration seams (verified from the app target)

- Headless surface API on `agterm/Ghostty/GhosttySurfaceView.swift` (a `final class
  GhosttySurfaceView: NSView, TerminalSurface`, `@MainActor`; owns `surface: ghostty_surface_t?`):
  `func makeHeadless(onInput: @escaping (Data) -> Void)`, `var headlessOnResize: ((UInt16, UInt16) -> Void)?`,
  `func writeOutput(_ data: Data)` (no-op if `surface == nil`), `func sendText(_:)`,
  `func readViewportText() -> String?`. `createHeadlessSurface()` runs when the view mounts
  (windowed, non-zero size), like a normal surface.
- `Session` (`agtermCore`, `@MainActor @Observable`): `@ObservationIgnored public var surface: (any TerminalSurface)?`
  — a slot the view factory fills lazily. `agterm/Views/TerminalView.swift` (`NSViewRepresentable`)
  does `(session[keyPath: surfaceKeyPath] as? GhosttySurfaceView) ?? makeSurface(session)`
  in `makeNSView`, so **if `session.surface` is already set, the shell factory never runs**.
  `agterm/ContentView.swift` eager-decks every session's `TerminalView`.
- `AppStore` (`@MainActor`) mutation: `addWorkspace(name:) -> Workspace`,
  `addSession(toWorkspace: UUID, cwd: String, command: String? = nil, name: String? = nil) -> Session?`,
  `renameSession(_ id: UUID, to: String)`, `closeSession(_ id: UUID)`, `removeWorkspace(_ id: UUID)`,
  `selectSession(_ id: UUID?)`, `session(withID: UUID) -> Session?`.
- `agterm/agtermApp.swift`: singletons built in `init()`; `applicationDidFinishLaunching`
  boots `GhosttyApp.shared` and (Phase 1) `if HeadlessHarness.isEnabled { HeadlessHarness.start() }`
  — the place to construct/start a real controller. `agterm/AppActions.swift` (`@MainActor`)
  `newSession()` shows the `store.addSession(...) → selectSession → focusActiveSession()` idiom.
- No PTY/subprocess-with-stdio helper exists in the repo — Task 2 adds the first one.

## File Structure

| File | Responsibility |
|---|---|
| `agtermCore/Sources/agtermCore/TmuxWindowList.swift` | parse a `list-windows` block's `.blockLine`s → `[(TmuxWindowID, name)]` |
| `agtermCore/Sources/agtermCore/PTYProcess.swift` | spawn a command in a pty (posix_openpt+posix_spawn), async-read stdout, write stdin, terminate |
| `agtermCore/Sources/agtermCore/TmuxGateway.swift` | PTYProcess + `TmuxControlParser` + handshake detection + outbound `TmuxCommand`; emits bootstrap bytes / events / exit |
| `agterm/Ghostty/GhosttySurfaceView.swift` | add a pending-output buffer flushed on headless surface create (small edit) |
| `agterm/Tmux/TmuxController.swift` | `@MainActor` bridge: gateway → AppStore/Session/headless surfaces; input/resize back to gateway; bootstrap surface |
| `agterm/AppActions.swift` | `attachTmux(host:sessionName:)` entry |
| `agterm/agtermApp.swift` | construct/own the `TmuxController` |
| Tests: `TmuxWindowListTests`, `PTYProcessTests`, `TmuxGatewayTests` (host-free) | one per host-free type |

---

### Task 1: `TmuxWindowList` — parse the initial `list-windows` block

On attach, existing windows arrive as `list-windows` response rows inside a `%begin`/`%end`
block (not `%window-add`). Parse those `.blockLine` texts into `(windowId, name)` so the
controller can create the initial sessions. Host-free, TDD. Deliverable: real captured rows
parse to the right windows.

**Files:**
- Create: `agtermCore/Sources/agtermCore/TmuxWindowList.swift`
- Test: `agtermCore/Tests/agtermCoreTests/TmuxWindowListTests.swift`

**Interfaces:**
- Consumes: `TmuxWindowID` (Phase 2).
- Produces: `public enum TmuxWindowList { public static func parse(_ blockLines: [String]) -> [(id: TmuxWindowID, name: String)] }`

A row looks like (real capture): `0: zsh- (1 panes) [80x24] [layout b25d,80x24,0,0,0] @0` and
`1: second* (1 panes) [80x24] [layout b25e,80x24,0,0,1] @1 (active)`. The window id is the
`@N` token; the name is the text after `<index>: ` up to the trailing `*`/`-`/` ` flag before
` (`. Extract: id = the whitespace token starting with `@`; name = substring after the first
`: ` up to the first ` (` , with a trailing `*`/`-` flag char stripped.

- [ ] **Step 1: Write the failing tests**

`TmuxWindowListTests.swift`:
```swift
import Testing
@testable import agtermCore

struct TmuxWindowListTests {
    @Test func parsesTwoWindowsWithNamesAndIds() {
        let rows = [
            "0: zsh- (1 panes) [80x24] [layout b25d,80x24,0,0,0] @0",
            "1: second* (1 panes) [80x24] [layout b25e,80x24,0,0,1] @1 (active)",
        ]
        let result = TmuxWindowList.parse(rows)
        #expect(result.count == 2)
        #expect(result[0].id == TmuxWindowID("@0"))
        #expect(result[0].name == "zsh")
        #expect(result[1].id == TmuxWindowID("@1"))
        #expect(result[1].name == "second")
    }

    @Test func ignoresRowsWithoutAWindowId() {
        #expect(TmuxWindowList.parse(["garbage line", ""]).isEmpty)
    }

    @Test func handlesMultiDigitIndexAndPlainName() {
        let rows = ["12: api (1 panes) [80x24] [layout abcd,80x24,0,0,5] @7"]
        let r = TmuxWindowList.parse(rows)
        #expect(r.count == 1)
        #expect(r[0].id == TmuxWindowID("@7"))
        #expect(r[0].name == "api")
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter TmuxWindowListTests 2>&1 | tail -12`
Expected: FAIL (`TmuxWindowList` undefined).

- [ ] **Step 3: Implement**

`TmuxWindowList.swift`:
```swift
public enum TmuxWindowList {
    public static func parse(_ blockLines: [String]) -> [(id: TmuxWindowID, name: String)] {
        var result: [(id: TmuxWindowID, name: String)] = []
        for line in blockLines {
            // Window id: the whitespace token beginning with '@'.
            guard let idToken = line.split(separator: " ").first(where: { $0.hasPrefix("@") })
            else { continue }
            // Name: text after the first ": " up to the first " (".
            guard let colon = line.range(of: ": ") else { continue }
            let afterColon = line[colon.upperBound...]
            let namePart = afterColon.range(of: " (").map { String(afterColon[..<$0.lowerBound]) }
                ?? String(afterColon)
            // Strip a trailing tmux flag char ('*' active / '-' last).
            var name = namePart
            if let last = name.last, last == "*" || last == "-" { name.removeLast() }
            result.append((TmuxWindowID(String(idToken)), name))
        }
        return result
    }
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `cd agtermCore && swift test --filter TmuxWindowListTests 2>&1 | tail -6`
Expected: all 3 PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermCore/TmuxWindowList.swift agtermCore/Tests/agtermCoreTests/TmuxWindowListTests.swift
git commit -m "agtermCore: parse tmux list-windows block into initial windows"
```

---

### Task 2: `PTYProcess` — spawn a command in a pty with async stdout + stdin

A host-free PTY wrapper: open a pty, `posix_spawn` a command with the slave as its
stdin/out/err, read the master async on a background queue (callback with bytes), write to
the master, and terminate. This is the transport the gateway drives. TDD against `/bin/cat`
(always present; echoes stdin → stdout through the pty). Deliverable: writing to a spawned
`/bin/cat` yields the same bytes back via the read callback.

**Files:**
- Create: `agtermCore/Sources/agtermCore/PTYProcess.swift`
- Test: `agtermCore/Tests/agtermCoreTests/PTYProcessTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public final class PTYProcess: @unchecked Sendable {
      public init()
      /// Spawn `path` with `args` (argv[0] is set to `path`) and `env`. `onData` is called
      /// on a background queue with each chunk read from the pty master. `onExit` is called
      /// once the child exits. Throws on spawn failure.
      public func start(path: String, args: [String], env: [String: String],
                        onData: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws
      public func write(_ data: Data)
      public func terminate()
  }
  ```
- `@unchecked Sendable`: it owns an fd + a `DispatchSourceRead`; access is serialized on its
  own queue. Callbacks fire on that background queue — the CONSUMER hops to main.

- [ ] **Step 1: Write the failing test**

`PTYProcessTests.swift`:
```swift
import Testing
import Foundation
@testable import agtermCore

struct PTYProcessTests {
    // Spawn /bin/cat in a pty; bytes written to stdin echo back on stdout.
    @Test func catEchoesThroughThePty() async throws {
        let pty = PTYProcess()
        let received = LockedBox()
        try pty.start(path: "/bin/cat", args: ["/bin/cat"], env: [:],
                      onData: { received.append($0) },
                      onExit: { _ in })
        pty.write(Data("hello\n".utf8))
        // Poll up to ~2s for the echo (cat is line-buffered on a tty).
        try await waitUntil(2.0) { received.contains("hello") }
        #expect(received.text.contains("hello"))
        pty.terminate()
    }
}

// Small test helpers (put in the same file).
final class LockedBox: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func contains(_ s: String) -> Bool { text.contains(s) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

func waitUntil(_ seconds: Double, _ cond: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if cond() { return }
        try await Task.sleep(nanoseconds: 20_000_000)   // 20ms
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter PTYProcessTests 2>&1 | tail -12`
Expected: FAIL (`PTYProcess` undefined).

- [ ] **Step 3: Implement**

`PTYProcess.swift` — open a pty master/slave with `posix_openpt`/`grantpt`/`unlockpt`/`ptsname`,
`posix_spawn` with a `posix_spawn_file_actions_t` dup'ing the slave onto fd 0/1/2, close the
slave in the parent, read the master via a `DispatchSourceRead`, reap the child with a
`DispatchSource.makeProcessSource`:
```swift
import Foundation
import Darwin

public final class PTYProcess: @unchecked Sendable {
    private var masterFD: Int32 = -1
    private var pid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var procSource: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "agterm.pty")

    public init() {}

    public func start(path: String, args: [String], env: [String: String],
                      onData: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let slaveName = ptsname(master) else {
            if master >= 0 { close(master) }
            throw PTYError.openFailed
        }
        let slave = open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { close(master); throw PTYError.openFailed }

        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, slave, 0)
        posix_spawn_file_actions_adddup2(&actions, slave, 1)
        posix_spawn_file_actions_adddup2(&actions, slave, 2)
        posix_spawn_file_actions_addclose(&actions, slave)
        posix_spawn_file_actions_addclose(&actions, master)
        defer { posix_spawn_file_actions_destroy(&actions) }

        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0)=\($1)") } + [nil]
        defer { for p in argv where p != nil { free(p) }; for p in envp where p != nil { free(p) } }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, path, &actions, nil, argv, envp)
        close(slave)
        guard rc == 0 else { close(master); throw PTYError.spawnFailed(rc) }
        self.masterFD = master
        self.pid = childPID

        let rs = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        rs.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(self.masterFD, &buf, buf.count)
            if n > 0 { onData(Data(buf[0..<n])) }
        }
        rs.resume()
        self.readSource = rs

        let ps = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        ps.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(childPID, &status, 0)
            onExit(status)
            self?.readSource?.cancel()
            self?.procSource?.cancel()
        }
        ps.resume()
        self.procSource = ps
    }

    public func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                _ = Darwin.write(self.masterFD, raw.baseAddress, raw.count)
            }
        }
    }

    public func terminate() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.pid > 0 { kill(self.pid, SIGTERM) }
            if self.masterFD >= 0 { close(self.masterFD); self.masterFD = -1 }
        }
    }
}

public enum PTYError: Error { case openFailed; case spawnFailed(Int32) }
```

- [ ] **Step 4: Run — expect PASS**

Run: `cd agtermCore && swift test --filter PTYProcessTests 2>&1 | tail -8`
Expected: the echo test PASSES. If the read never fires, verify the slave fd dup order and
that the master is non-blocking-safe under DispatchSourceRead (it is; the handler reads
what's available). Iterate until green.

- [ ] **Step 5: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermCore/PTYProcess.swift agtermCore/Tests/agtermCoreTests/PTYProcessTests.swift
git commit -m "agtermCore: PTYProcess — spawn a command in a pty with async stdout/stdin"
```

---

### Task 3: `TmuxGateway` — PTY + parser + handshake, over a scripted transcript

Combine `PTYProcess` + `TmuxControlParser` into the gateway: spawn the control-mode command,
feed its bytes to the parser, detect the `\u{1b}P1000p` handshake to switch from a "bootstrap"
(ssh-auth) phase to the control-mode phase, surface `TmuxEvent`s, and encode/send outbound
`TmuxCommand`s. TDD against a scripted subprocess emitting a captured `-CC` transcript (CI-safe,
no real tmux). Deliverable: driving a `printf`-scripted transcript yields the bootstrap
bytes, then the handshake, then the parsed events.

**Files:**
- Create: `agtermCore/Sources/agtermCore/TmuxGateway.swift`
- Test: `agtermCore/Tests/agtermCoreTests/TmuxGatewayTests.swift`

**Interfaces:**
- Consumes: `PTYProcess`, `TmuxControlParser`, `TmuxCommand`/`TmuxCommandEncoder`, `TmuxEvent`.
- Produces:
  ```swift
  public final class TmuxGateway: @unchecked Sendable {
      public struct Callbacks: Sendable {
          public var onBootstrapBytes: @Sendable (Data) -> Void   // pre-handshake (ssh prompts)
          public var onHandshake: @Sendable () -> Void            // control mode entered
          public var onEvent: @Sendable (TmuxEvent) -> Void       // post-handshake events
          public var onExit: @Sendable (Int32) -> Void
          public init(onBootstrapBytes: ..., onHandshake: ..., onEvent: ..., onExit: ...)
      }
      public init(callbacks: Callbacks)
      public func start(path: String, args: [String], env: [String: String]) throws
      public func send(_ command: TmuxCommand)   // encodes + writes "<line>\n"
      public func writeBootstrap(_ data: Data)    // raw stdin during the auth phase (user keystrokes)
      public func stop()
  }
  ```
- The handshake marker is `\u{1b}P1000p`. Before it: raw bytes → `onBootstrapBytes`. On seeing
  it: emit `onHandshake`, then feed everything from the marker onward (inclusive) to
  `TmuxControlParser` and forward each `TmuxEvent` to `onEvent`. The parser already strips the
  DCS intro, so feed it the marker+remainder.

- [ ] **Step 1: Write the failing test**

`TmuxGatewayTests.swift` — drive a scripted transcript through `/bin/sh -c 'printf %s "<transcript>"'`
so no real tmux is needed. Use a transcript with a short pre-handshake preamble, the DCS
handshake, a `%window-add`, a `%output`, and `%exit`:
```swift
import Testing
import Foundation
@testable import agtermCore

struct TmuxGatewayTests {
    @Test func splitsBootstrapFromControlAndParsesEvents() async throws {
        // Pre-handshake "password:" preamble, then the DCS handshake + a couple notifications.
        let transcript = "password: \u{1b}P1000p%window-add @0\r\n%output %0 hi\r\n%exit\r\n\u{1b}\\"
        let boot = LockedBox()
        let events = EventBox()
        let handshaken = FlagBox()
        let gw = TmuxGateway(callbacks: .init(
            onBootstrapBytes: { boot.append($0) },
            onHandshake: { handshaken.set() },
            onEvent: { events.append($0) },
            onExit: { _ in }))
        // Emit the transcript verbatim from a subprocess.
        let escaped = transcript.replacingOccurrences(of: "'", with: "'\\''")
        try gw.start(path: "/bin/sh", args: ["/bin/sh", "-c", "printf %s '\(escaped)'"], env: [:])
        try await waitUntil(2.0) { events.contains(.exit(reason: nil)) }
        #expect(boot.text.contains("password:"))
        #expect(handshaken.isSet)
        #expect(events.all.contains(.windowAdd(TmuxWindowID("@0"))))
        #expect(events.all.contains(.output(pane: TmuxPaneID("%0"), bytes: Array("hi".utf8))))
        #expect(events.all.contains(.exit(reason: nil)))
        gw.stop()
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock(); private var items: [TmuxEvent] = []
    func append(_ e: TmuxEvent) { lock.lock(); items.append(e); lock.unlock() }
    func contains(_ e: TmuxEvent) -> Bool { lock.lock(); defer { lock.unlock() }; return items.contains(e) }
    var all: [TmuxEvent] { lock.lock(); defer { lock.unlock() }; return items }
}
final class FlagBox: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
```
(`LockedBox`/`waitUntil` are the helpers from Task 2; if the test target complains about
duplicate definitions, move them into a shared `TmuxTestSupport.swift` test file in
`Tests/agtermCoreTests/` and remove them from `PTYProcessTests.swift`.)

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter TmuxGatewayTests 2>&1 | tail -12`
Expected: FAIL (`TmuxGateway` undefined).

- [ ] **Step 3: Implement**

`TmuxGateway.swift`:
```swift
import Foundation

public final class TmuxGateway: @unchecked Sendable {
    public struct Callbacks: Sendable {
        public var onBootstrapBytes: @Sendable (Data) -> Void
        public var onHandshake: @Sendable () -> Void
        public var onEvent: @Sendable (TmuxEvent) -> Void
        public var onExit: @Sendable (Int32) -> Void
        public init(onBootstrapBytes: @escaping @Sendable (Data) -> Void,
                    onHandshake: @escaping @Sendable () -> Void,
                    onEvent: @escaping @Sendable (TmuxEvent) -> Void,
                    onExit: @escaping @Sendable (Int32) -> Void) {
            self.onBootstrapBytes = onBootstrapBytes; self.onHandshake = onHandshake
            self.onEvent = onEvent; self.onExit = onExit
        }
    }

    private let callbacks: Callbacks
    private let pty = PTYProcess()
    private let lock = NSLock()
    private var parser = TmuxControlParser()
    private var inControlMode = false
    private var preHandshake = Data()
    private static let marker = Data("\u{1b}P1000p".utf8)

    public init(callbacks: Callbacks) { self.callbacks = callbacks }

    public func start(path: String, args: [String], env: [String: String]) throws {
        try pty.start(path: path, args: args, env: env,
                      onData: { [weak self] in self?.ingest($0) },
                      onExit: { [weak self] in self?.callbacks.onExit($0) })
    }

    private func ingest(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if inControlMode {
            for event in parser.feed(Array(data)) { callbacks.onEvent(event) }
            return
        }
        preHandshake.append(data)
        if let range = preHandshake.range(of: Self.marker) {
            // Everything before the marker is bootstrap output.
            let before = preHandshake[..<range.lowerBound]
            if !before.isEmpty { callbacks.onBootstrapBytes(Data(before)) }
            callbacks.onHandshake()
            inControlMode = true
            let fromMarker = Data(preHandshake[range.lowerBound...])   // include the DCS intro
            preHandshake.removeAll()
            for event in parser.feed(Array(fromMarker)) { callbacks.onEvent(event) }
        } else {
            // No marker yet: flush what we have as bootstrap, but KEEP a trailing partial
            // marker prefix in the buffer so a marker split across reads still matches.
            let keep = min(preHandshake.count, Self.marker.count - 1)
            let flush = preHandshake.count - keep
            if flush > 0 {
                callbacks.onBootstrapBytes(Data(preHandshake.prefix(flush)))
                preHandshake.removeFirst(flush)
            }
        }
    }

    public func send(_ command: TmuxCommand) {
        pty.write(Data((TmuxCommandEncoder.encode(command) + "\n").utf8))
    }

    public func writeBootstrap(_ data: Data) { pty.write(data) }

    public func stop() { pty.terminate() }
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `cd agtermCore && swift test --filter TmuxGatewayTests 2>&1 | tail -8`
Expected: PASS. Then the full host-free suite: `cd agtermCore && swift test 2>&1 | tail -5`.

- [ ] **Step 5: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermCore/TmuxGateway.swift agtermCore/Tests/agtermCoreTests/TmuxGatewayTests.swift agtermCore/Tests/agtermCoreTests/TmuxTestSupport.swift 2>/dev/null
git add -A agtermCore/Tests/agtermCoreTests
git commit -m "agtermCore: TmuxGateway — pty + parser + ssh-bootstrap/handshake split"
```

---

### Task 4: Headless surface pending-output buffer

`writeOutput` no-ops while `surface == nil` (before the eager-deck view mounts), so the first
`%output` bytes after attach would be lost. Buffer them and flush on `createHeadlessSurface`.
App-target edit; verified by build + a targeted check via the existing harness pattern.

**Files:**
- Modify: `agterm/Ghostty/GhosttySurfaceView.swift`

**Interfaces:**
- Consumes: existing `writeOutput(_:)`, `createHeadlessSurface()`, `surface`.
- Produces: unchanged public API; `writeOutput` now buffers when `surface == nil` and the
  buffer flushes once the headless surface is created.

- [ ] **Step 1: Add the buffer + flush**

In `GhosttySurfaceView.swift`, add `private var pendingHeadlessOutput = Data()`. In
`writeOutput(_:)`, when `surface == nil` (and `isHeadless`), append to
`pendingHeadlessOutput` and return. At the END of `createHeadlessSurface()` (after
`surface = ghostty_surface_new(...)` succeeds), if `!pendingHeadlessOutput.isEmpty`, call the
real write with the buffered data and clear it:
```swift
    func writeOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let surface else {
            if isHeadless { pendingHeadlessOutput.append(data) }
            return
        }
        data.withUnsafeBytes { raw in
            ghostty_surface_write_output(surface, raw.baseAddress!.assumingMemoryBound(to: CChar.self), UInt(data.count))
        }
    }
```
And in `createHeadlessSurface()`, right after the surface is assigned:
```swift
        if !pendingHeadlessOutput.isEmpty {
            let buffered = pendingHeadlessOutput
            pendingHeadlessOutput.removeAll()
            writeOutput(buffered)
        }
```
(Adapt to the file's actual `writeOutput` body / surface-assignment line — keep the raw-pointer
write identical to what's there.)

- [ ] **Step 2: Build + lint**

Run: `make build 2>&1 | tail -5 && make lint 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`, lint clean.

- [ ] **Step 3: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agterm/Ghostty/GhosttySurfaceView.swift
git commit -m "ghostty: buffer headless writeOutput until the surface exists"
```

---

### Task 5: `TmuxController` — bridge gateway effects to a live workspace

The `@MainActor` glue: own a `TmuxGateway` + `TmuxSessionModel`, create a workspace + a
headless-backed session per tmux window, seed each `session.surface` with a headless
`GhosttySurfaceView` (so the eager deck hosts it instead of spawning a shell), route
`%output` → the session's `writeOutput`, wire the surface's `headlessOnInput` → `send-keys`
and `headlessOnResize` → `refresh-client -C`, and tear down on `%exit`. Includes the bootstrap
phase (a visible headless surface showing ssh prompts until the handshake). App-target;
verified by build (the real run is Task 6).

**Files:**
- Create: `agterm/Tmux/TmuxController.swift`

**Interfaces:**
- Consumes: `TmuxGateway`, `TmuxSessionModel`, `TmuxModelEffect`, `TmuxWindowList`, `TmuxCommand`,
  `AppStore`, `Session`, `GhosttySurfaceView`, `GhosttyApp`.
- Produces:
  ```swift
  @MainActor final class TmuxController {
      init(store: AppStore)
      func attach(host: String, sessionName: String)   // spawns ssh+tmux -CC, begins bootstrap
      func detach()                                     // sends detach-client, tears down local workspace
  }
  ```

- [ ] **Step 1: Implement the controller**

`agterm/Tmux/TmuxController.swift`. Key mechanics (all mutation on the main actor; gateway
callbacks arrive off-main and MUST `DispatchQueue.main.async` before touching store/surfaces):
```swift
import Foundation
import AppKit
import agtermCore

@MainActor final class TmuxController {
    private let store: AppStore
    private var gateway: TmuxGateway?
    private var model = TmuxSessionModel()
    private var workspaceID: UUID?
    private var windowToSession: [TmuxWindowID: UUID] = [:]      // tmux window -> agterm session
    private var pendingLeadingPane: [TmuxWindowID: TmuxPaneID] = [:]

    init(store: AppStore) { self.store = store }

    func attach(host: String, sessionName: String) {
        let ws = store.addWorkspace(name: "tmux: \(host)")
        workspaceID = ws.id
        let gw = TmuxGateway(callbacks: .init(
            onBootstrapBytes: { data in DispatchQueue.main.async { [weak self] in self?.applyBootstrap(data) } },
            onHandshake: { DispatchQueue.main.async { [weak self] in self?.onHandshake() } },
            onEvent: { event in DispatchQueue.main.async { [weak self] in self?.apply(event) } },
            onExit: { _ in DispatchQueue.main.async { [weak self] in self?.onExit() } }))
        self.gateway = gw
        // ssh -tt <host> tmux -CC new -A -s <name>   (-tt forces a tty so tmux enters control mode)
        let args = ["/usr/bin/ssh", "-tt", host, "tmux -CC new -A -s \(sessionName)"]
        try? gw.start(path: "/usr/bin/ssh", args: args, env: ProcessInfo.processInfo.environment)
    }

    private func apply(_ event: TmuxEvent) {
        // Track the leading pane per window so we can wire a freshly-created surface to output.
        for effect in model.handle(event) { apply(effect) }
    }

    private func apply(_ effect: TmuxModelEffect) {
        guard let workspaceID else { return }
        switch effect {
        case .createSession(let window, let name):
            guard let session = store.addSession(toWorkspace: workspaceID, cwd: "", name: name.isEmpty ? "tmux" : name)
            else { return }
            windowToSession[window] = session.id
            // Seed a headless surface so the eager deck hosts it (no shell spawn).
            let view = GhosttySurfaceView(workingDirectory: nil)
            view.makeHeadless(onInput: { [weak self] data in
                self?.sendKeys(window: window, bytes: Array(data))
            })
            view.headlessOnResize = { [weak self] cols, rows in
                self?.gateway?.send(.resizeClient(cols: Int(cols), rows: Int(rows)))
            }
            session.surface = view
        case .renameSession(let window, let name):
            if let id = windowToSession[window] { store.renameSession(id, to: name) }
        case .removeSession(let window):
            if let id = windowToSession.removeValue(forKey: window) { store.closeSession(id) }
        case .routeOutput(let window, let bytes):
            if let id = windowToSession[window], let session = store.session(withID: id),
               let view = session.surface as? GhosttySurfaceView {
                view.writeOutput(Data(bytes))
            }
        case .tearDown:
            teardownWorkspace()
        case .diagnostic(let message):
            NSLog("tmux: \(message)")
        }
    }

    private func sendKeys(window: TmuxWindowID, bytes: [UInt8]) {
        // Under no-splits, the pane we send to is the window's leading pane. The model bound
        // it in paneToWindow; ask the model's inverse via the last layout. Simplest: send to
        // the window's leading pane id we recorded, else skip.
        guard let pane = pendingLeadingPane[window] else { return }
        gateway?.send(.sendKeys(pane: pane, bytes: bytes))
    }

    private func applyBootstrap(_ data: Data) { /* Step 2 wires a visible bootstrap surface */ }
    private func onHandshake() { /* Step 2 closes the bootstrap surface */ }
    private func onExit() { teardownWorkspace() }

    private func teardownWorkspace() {
        if let workspaceID { store.removeWorkspace(workspaceID) }
        workspaceID = nil; windowToSession.removeAll(); gateway = nil
    }

    func detach() { gateway?.send(.detachClient); teardownWorkspace() }
}
```
Note: the `pendingLeadingPane` map must be populated. The model tracks pane→window internally
but doesn't expose the leading pane. Add a tiny accessor to `TmuxSessionModel` OR have the
controller also observe `.layoutChange` events directly: extend `apply(_ event:)` to record
the leading pane before folding into the model:
```swift
    private func apply(_ event: TmuxEvent) {
        if case let .layoutChange(window, layout) = event {
            if let leading = TmuxLayout.panes(in: layout).panes.first { pendingLeadingPane[window] = leading }
        }
        for effect in model.handle(event) { apply(effect) }
    }
```

- [ ] **Step 2: Bootstrap surface (ssh auth)**

Implement `applyBootstrap`/`onHandshake`: on the FIRST bootstrap bytes, create ONE extra
"connecting" session in the workspace with a headless surface whose `headlessOnInput` writes
raw to `gateway.writeBootstrap(...)`, and `writeOutput` renders the ssh prompt bytes; store its
session id in `private var bootstrapSessionID: UUID?`. On `onHandshake`, `store.closeSession`
the bootstrap session. Keep it minimal — reuse the same headless-surface seeding as a normal
session:
```swift
    private var bootstrapSessionID: UUID?
    private func applyBootstrap(_ data: Data) {
        guard let workspaceID else { return }
        if bootstrapSessionID == nil {
            guard let session = store.addSession(toWorkspace: workspaceID, cwd: "", name: "connecting…") else { return }
            bootstrapSessionID = session.id
            let view = GhosttySurfaceView(workingDirectory: nil)
            view.makeHeadless(onInput: { [weak self] d in self?.gateway?.writeBootstrap(d) })
            session.surface = view
            store.selectSession(session.id)
        }
        if let id = bootstrapSessionID, let s = store.session(withID: id),
           let view = s.surface as? GhosttySurfaceView { view.writeOutput(data) }
    }
    private func onHandshake() {
        if let id = bootstrapSessionID { store.closeSession(id); bootstrapSessionID = nil }
    }
```

- [ ] **Step 3: Build + lint**

Run: `make build 2>&1 | tail -6 && make lint 2>&1 | tail -3`
Expected: BUILD SUCCEEDED, lint clean. Fix any concurrency/type errors (the `swift-concurrency`
skill covers the `@Sendable` gateway-callback → main-actor hop).

- [ ] **Step 4: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agterm/Tmux/TmuxController.swift
git commit -m "app: TmuxController — bridge gateway events to a headless-backed workspace"
```

---

### Task 6: Wire the attach entry + Phase-3 end-to-end gate

Add an `AppActions.attachTmux` entry, construct the `TmuxController` in the app lifecycle, and
prove the whole path against a LOCAL `tmux -CC` (no ssh): windows become sessions, output
renders, a keystroke reaches tmux. This is the Phase-3 viability gate (run by the controller
in an isolated dev instance).

**Files:**
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/agtermApp.swift`

**Interfaces:**
- Consumes: `TmuxController`, `AppStore` (via `library.activeStore`).
- Produces: `AppActions.attachTmux(host: String, sessionName: String)`; a `TmuxController`
  owned by the app (constructed alongside the other singletons). Add an env-gated
  auto-attach-to-local-tmux for the gate: if `AGTERM_TMUX_LOCAL == "1"`, attach to a local
  session by spawning `tmux -CC` directly (no ssh) — see Step 3.

- [ ] **Step 1: Add the AppActions entry + app-lifecycle owner**

In `AppActions.swift`, add:
```swift
    func attachTmux(host: String, sessionName: String) {
        guard let store else { return }
        tmuxController(for: store).attach(host: host, sessionName: sessionName)
    }
```
Own a `TmuxController` per store (a small cache keyed by `ObjectIdentifier(store)`), or — simpler
for Phase 3 — construct a single `TmuxController` in `agtermApp.init()` bound to the primary
store and hand it to `AppActions`. Follow the existing singleton-wiring in `agtermApp.init()`
(where `AppActions`, `ControlServer`, etc. are built). Keep the wiring minimal and match the
surrounding style.

- [ ] **Step 2: Local-tmux gate hook**

For a deterministic gate WITHOUT ssh, add a controller method `attachLocal(sessionName:)` that
spawns `tmux -CC new -A -s <name>` directly (path from `AGTERM_TMUX_BIN` env or
`/opt/homebrew/bin/tmux`), reusing all the same event handling as `attach`. In
`applicationDidFinishLaunching`, after `GhosttyApp.shared`, add:
```swift
        if ProcessInfo.processInfo.environment["AGTERM_TMUX_LOCAL"] == "1" {
            tmuxController.attachLocal(sessionName: "agtgate")
        }
```

- [ ] **Step 3: Build + lint**

Run: `make build 2>&1 | tail -6 && make lint 2>&1 | tail -3`
Expected: BUILD SUCCEEDED, lint clean.

- [ ] **Step 4: Run the Phase-3 gate (controller-run, isolated instance)**

Prepare a local tmux session with two windows, then launch the dev instance pointed at a
local `tmux -CC`:
```bash
TMUXBIN=/opt/homebrew/bin/tmux
"$TMUXBIN" -L agtgate kill-server 2>/dev/null
"$TMUXBIN" -L agtgate new-session -d -s agtgate -x 80 -y 24
"$TMUXBIN" -L agtgate new-window -t agtgate -n second
TMP=$(mktemp -d)
open -n --env AGTERM_TMUX_LOCAL=1 --env AGTERM_TMUX_BIN="$TMUXBIN -L agtgate" \
        --env AGTERM_STATE_DIR="$TMP" --env AGTERM_CONTROL_SOCKET="$TMP/agterm.sock" \
        build/DerivedData/Build/Products/Debug/agterm.app
```
(If threading `-L agtgate` through `AGTERM_TMUX_BIN` is awkward, hardcode the socket in
`attachLocal` for the gate.) Expected on screen: a "tmux: …" workspace with two sessions
(`agtgate`/`second`), each rendering the remote shell prompt. Then, via `agtermctl` against the
isolated socket OR by typing, confirm output routes and input reaches tmux. Quit the dev
instance BY PID; do not touch the deployed app.

- [ ] **Step 5: Record the gate result + commit**

If green (windows→sessions, output renders, input round-trips): Phase 3 is done. If red,
diagnose (bootstrap vs handshake vs surface-seed timing) before proceeding.
```bash
cd /Users/eshreder/projects/agterm
git add agterm/AppActions.swift agterm/agtermApp.swift
git commit -m "app: attach-tmux entry + local-tmux Phase 3 gate hook"
```

---

## Self-Review

**Spec coverage (component 4 + lifecycle):** gateway subprocess+PTY (Tasks 2–3), ssh-auth
bootstrap phase + handshake detection (Task 3 + Task 5 Step 2), `TmuxController` effect
execution + headless-surface seeding + input/resize round-trip (Task 5), initial-attach
window list (Task 1), `%exit`/detach teardown (Task 5), pending-output buffering so no early
bytes are lost (Task 4), attach entry + gate (Task 6). ✓
- **Deferred to Phase 4–5 (correctly out of scope):** the `tmux.*` control-API commands +
  `agtermctl` + backend-aware `session.*` + agent-skill + the GUI "Attach…" affordance (Task 6
  adds only a programmatic `AppActions.attachTmux` + an env-gated local hook, not the full
  control surface). Real-ssh auth UX polish and auto-reconnect are also deferred.

**Placeholder scan:** Tasks 1–3 have complete code + real-fixture tests. Tasks 4–6 are
app-target integration: they give complete code for the new types and exact edit points, with
`make build` + the manual gate as verification (host-free unit tests don't apply to
AppKit/libghostty wiring). The `pendingLeadingPane` wiring gap in Task 5 is called out and
resolved inline (record leading pane from `.layoutChange` in the controller).

**Type consistency:** `PTYProcess.start(path:args:env:onData:onExit:)`, `TmuxGateway.Callbacks`/
`start`/`send`/`writeBootstrap`/`stop`, `TmuxWindowList.parse`, `TmuxController.attach/detach/
attachLocal`, and the reused Phase-2 types (`TmuxEvent`, `TmuxCommand`, `TmuxSessionModel`,
`TmuxLayout`) are named consistently across tasks. `GhosttySurfaceView.writeOutput`/`makeHeadless`/
`headlessOnResize` match the app-target seams verified in the integration map.

**Known risks to watch in review/gate:** (1) `ssh -tt` + `tmux -CC` control-mode entry timing
vs the handshake-split buffer (marker split across reads is handled by keeping a marker-length-1
tail); (2) surface-seed vs eager-deck mount ordering (seed synchronously in `createSession`
before SwiftUI renders); (3) the leading-pane send-keys target depends on a `%layout-change`
having arrived before the first keystroke (true in practice — tmux sends layout on window
creation).
