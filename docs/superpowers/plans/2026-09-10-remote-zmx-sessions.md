# Remote zmx Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attach to, list, and kill zmx sessions on any host that runs zmx and nothing of agterm's, each attached session being an ordinary agterm session marked remote.

**Architecture:** A new `remote` control group beside the agterm-to-agterm `zmx tree`/`zmx attach`. `remote.list` runs the far side's `zmx list` over ssh and parses its tab rows; `remote.attach` inserts a command session whose command is `ssh -tt … zmx attach <name>` with `Session.remoteHost` set; `remote.kill` runs `zmx kill <name>` over ssh. Host-free parsing, argv building, validation, dispatch, and CLI live in `agtermCore`; the app target only runs ssh through the existing `RemoteCommandRunner` seam and touches the store.

**Tech Stack:** Swift 6 (`agtermCore`, complete concurrency checking), Swift Testing for `agtermCore`, XCTest for hosted `agtermTests`, swift-argument-parser for `agtermctl`, Xcode 26 / xcodegen for the app.

**Spec:** `docs/superpowers/specs/2026-09-10-remote-zmx-sessions-design.md`

## Global Constraints

- The far side needs zmx 0.7 or later and key-based, prompt-free ssh; every ssh runs with `BatchMode=yes`.
- No `ZMX_DIR` is set on the far side; `ZMX_SESSION=`, `ZMX_SESSION_PREFIX=`, `ZMX_NO_DETACH_KEY=1` are.
- zmx is resolved through the far side's PATH plus `$HOME/.local/bin:$HOME/bin:/usr/local/bin:/opt/homebrew/bin`.
- Without `create`, the attach argv carries the create-only guard `/bin/sh -c "printf '%s\n' 'agterm: remote session is gone'; exit 1"`.
- `command` without `create` is refused; `remote.kill` requires `force`.
- A host is validated by `RemoteSession`'s rule and never echoed unless it passed; the constant error is `invalid host`. A session name must be plain (no whitespace or control characters), contain no `/`, and not start with `-`; the constant error is `invalid remote session`.
- Exit 127 from a list or kill chain reports `zmx is not installed on <host>`.
- `remote list` omits names for which `ZmxSupport.isDaemonName` is true.
- Attached sessions are not persisted (`Session.remoteHost` already guarantees it); no GUI.
- No surface states a command count.
- Every commit message ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Gates run ONCE at the end (Task 8); every earlier step runs only the targeted tests it names.

Working directory for every command: `/Users/eshreder/projects/agterm/.claude/worktrees/tmux-remote-sessions`, branch `remote-zmx-sessions`. Never run `agtermctl` against the default socket, never launch or quit the app.

---

### Task 1: `zmx list` row parser and its payload

**Files:**
- Create: `agtermCore/Sources/agtermCore/RemoteHost.swift`
- Test: `agtermCore/Tests/agtermCoreTests/RemoteHostListTests.swift`

**Interfaces:**
- Produces: `public struct ControlRemoteHostSession: Codable, Sendable, Equatable { name: String, clients: Int, cwd: String?, created: Int?, labels: [String: String] }` and `public enum RemoteHostList { public static func parse(_ text: String) -> [ControlRemoteHostSession] }`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import agtermCore

/// What the far side's own `zmx list` prints, read back row by row.
struct RemoteHostListTests {
    private static let rows = """
    name=api\tpid=22598\tclients=1\tcreated=1788988802\tcwd=file://devbox/home/me/api\tproject=api\trole=worker
      name=build\tpid=22600\tclients=0\tcreated=1788988810
    name=agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1\tpid=1\tclients=1
    No sessions found in /tmp/zmx-1000
    """

    @Test func parsesEveryFieldAndKeepsTheRestAsLabels() throws {
        let sessions = RemoteHostList.parse(Self.rows)
        let api = try #require(sessions.first { $0.name == "api" })
        #expect(api.clients == 1)
        #expect(api.created == 1_788_988_802)
        #expect(api.cwd == "/home/me/api")
        #expect(api.labels == ["project": "api", "role": "worker"])
    }

    @Test func aRowWithoutCwdOrLabelsStillParses() throws {
        let build = try #require(RemoteHostList.parse(Self.rows).first { $0.name == "build" })
        #expect(build.clients == 0)
        #expect(build.cwd == nil)
        #expect(build.labels.isEmpty)
    }

    // agterm's own live-pane daemons on a host that also runs agterm belong to `zmx tree`
    @Test func omitsAgtermDaemonNamesAndProseLines() {
        #expect(RemoteHostList.parse(Self.rows).map(\.name) == ["api", "build"])
    }

    @Test func anEmptyListingIsEmpty() {
        #expect(RemoteHostList.parse("").isEmpty)
        #expect(RemoteHostList.parse("No sessions found in /tmp/zmx-1000\n").isEmpty)
    }

    @Test func aPercentEncodedPathIsDecoded() throws {
        let row = "name=x\tclients=0\tcwd=file://h/home/me/My%20Project"
        #expect(try #require(RemoteHostList.parse(row).first).cwd == "/home/me/My Project")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd agtermCore && swift test --filter RemoteHostListTests`
Expected: compile failure, `ControlRemoteHostSession` and `RemoteHostList` undefined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// One session on a host that runs zmx without agterm, as that host's own `zmx list` reports it.
public struct ControlRemoteHostSession: Codable, Sendable, Equatable {
    public let name: String
    public let clients: Int
    /// The path of the row's `cwd=file://host/path`, absent when zmx reported none.
    public let cwd: String?
    /// Unix seconds, as zmx prints them.
    public let created: Int?
    /// Every other key on the row: zmx labels such as `project=api`.
    public let labels: [String: String]

    public init(name: String, clients: Int, cwd: String? = nil, created: Int? = nil,
                labels: [String: String] = [:]) {
        self.name = name
        self.clients = clients
        self.cwd = cwd
        self.created = created
        self.labels = labels
    }
}

/// Reads `zmx list`: one row per session, tab-separated `key=value` fields, a leading indent on some rows,
/// and prose lines such as `No sessions found in …` that carry no `name=`.
public enum RemoteHostList {
    private static let builtinKeys: Set<String> = ["name", "pid", "clients", "created", "cwd"]

    public static func parse(_ text: String) -> [ControlRemoteHostSession] {
        text.split(separator: "\n").compactMap { line in
            var fields: [String: String] = [:]
            for field in line.split(separator: "\t") {
                let trimmed = field.trimmingCharacters(in: .whitespaces)
                guard let separator = trimmed.firstIndex(of: "=") else { continue }
                fields[String(trimmed[..<separator])] = String(trimmed[trimmed.index(after: separator)...])
            }
            guard let name = fields["name"], !name.isEmpty else { return nil }
            // agterm's own daemons on a host that also runs agterm are reached through `zmx tree`, where
            // their split and ownership are known
            guard !ZmxSupport.isDaemonName(name) else { return nil }
            return ControlRemoteHostSession(name: name,
                                            clients: fields["clients"].flatMap { Int($0) } ?? 0,
                                            cwd: fields["cwd"].flatMap(path(fromFileURI:)),
                                            created: fields["created"].flatMap { Int($0) },
                                            labels: fields.filter { !builtinKeys.contains($0.key) })
        }
    }

    /// `file://host/path` → `/path`, percent-decoded; a bare path passes through.
    static func path(fromFileURI value: String) -> String? {
        guard value.hasPrefix("file://") else { return value.isEmpty ? nil : value }
        let rest = value.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let path = String(rest[slash...])
        return path.removingPercentEncoding ?? path
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd agtermCore && swift test --filter RemoteHostListTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add agtermCore/Sources/agtermCore/RemoteHost.swift agtermCore/Tests/agtermCoreTests/RemoteHostListTests.swift
git commit -m "feat(remote): parse a zmx host's session list

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: ssh argv builders for list, attach, and kill

**Files:**
- Modify: `agtermCore/Sources/agtermCore/RemoteSession.swift` (make `sshArguments` and `validate(host:)` internal)
- Create: `agtermCore/Sources/agtermCore/RemoteHostCommands.swift`
- Test: `agtermCore/Tests/agtermCoreTests/RemoteSessionTests.swift` (append; the private `FakeRemote` fixture lives there)

**Interfaces:**
- Consumes: `RemoteSession.sshArguments(host:connectTimeout:interactive:)`, `RemoteSession.validate(host:)`, `RemoteSession.isPlain(_:)`, `CommandRestore.shellQuotedLine(_:)`.
- Produces on `RemoteSession`: `hostListCommand(host:connectTimeout:) throws -> [String]`, `hostAttachCommand(host:name:create:command:connectTimeout:) throws -> [String]`, `hostAttachPaneCommand(host:name:create:command:) throws -> String`, `hostKillCommand(host:name:connectTimeout:) throws -> [String]`, `isSessionName(_:) -> Bool`. All throw `RemoteSession.InvocationError` (`invalidSession` for a bad name).

- [ ] **Step 1: Write the failing tests** (append inside `struct RemoteSessionTests`, before its closing brace)

```swift
    // MARK: - hosts that run zmx without agterm

    @Test func hostAttachRunsZmxAttachWithTheGuardByDefault() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        _ = try fake.installZmx()

        let run = try fake.runRemote(try RemoteSession.hostAttachCommand(host: "devbox", name: "api", create: false),
                                     exporting: ["ZMX_DIR": "/tmp/the-hosts-own"])

        #expect(run.status == 0)
        #expect(try fake.calls().first == ["attach", "api", "/bin/sh", "-c",
                                           "printf '%s\\n' 'agterm: remote session is gone'; exit 1"])
        #expect(try fake.recordedZmxSessionEnv() == "session=[] prefix=[] nodetach=[1]")
        #expect(try fake.recordedZmxDir() == "/tmp/the-hosts-own", "the far side's own socket directory is left alone")
    }

    @Test func hostAttachWithCreateDropsTheGuardAndRunsTheCommand() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        _ = try fake.installZmx()

        let run = try fake.runRemote(try RemoteSession.hostAttachCommand(
            host: "devbox", name: "api", create: true, command: "cd ~/api && claude"))

        #expect(run.status == 0)
        #expect(try fake.calls().first == ["attach", "api", "/bin/sh", "-c", "cd ~/api && claude"])
    }

    @Test func hostAttachWithCreateAndNoCommandStartsTheLoginShell() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        _ = try fake.installZmx()

        _ = try fake.runRemote(try RemoteSession.hostAttachCommand(host: "devbox", name: "api", create: true))

        #expect(try fake.calls().first == ["attach", "api"])
    }

    @Test func hostListAndKillRunTheFarSidesOwnZmx() throws {
        let fake = try FakeRemote()
        defer { fake.cleanUp() }
        _ = try fake.installZmx()

        _ = try fake.runRemote(try RemoteSession.hostListCommand(host: "devbox"))
        _ = try fake.runRemote(try RemoteSession.hostKillCommand(host: "devbox", name: "api"))

        #expect(try fake.calls() == [["list"], ["kill", "api"]])
    }

    @Test func hostCommandsWidenPathToTheUserInstallDirectories() throws {
        let remote = try #require(try RemoteSession.hostListCommand(host: "devbox").last)
        for directory in ["$HOME/.local/bin", "$HOME/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
            #expect(remote.contains(directory))
        }
    }

    @Test func hostListIsNonInteractiveAndHostAttachForcesAPty() throws {
        #expect(try RemoteSession.hostListCommand(host: "devbox", connectTimeout: 9).prefix(7)
            == ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=9", "devbox"])
        #expect(try RemoteSession.hostAttachCommand(host: "devbox", name: "api", create: false).prefix(7)
            == ["ssh", "-tt", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "devbox"])
    }

    @Test(arguments: ["", "-rf", "a/b", "a b", "a\nb", "a\u{7F}"])
    func hostCommandsRefuseAnUnsafeSessionName(_ name: String) {
        #expect(throws: RemoteSession.InvocationError.invalidSession) {
            try RemoteSession.hostAttachCommand(host: "devbox", name: name, create: true)
        }
        #expect(throws: RemoteSession.InvocationError.invalidSession) {
            try RemoteSession.hostKillCommand(host: "devbox", name: name)
        }
        #expect(!RemoteSession.isSessionName(name))
    }

    @Test(arguments: ["", "-oProxyCommand=x", "dev box"])
    func hostCommandsRefuseAnUnsafeHost(_ host: String) {
        #expect(throws: (any Error).self) { try RemoteSession.hostListCommand(host: host) }
    }

    @Test func hostAttachPaneCommandReportsTheDisconnectAndKeepsSshsStatus() throws {
        let line = try RemoteSession.hostAttachPaneCommand(host: "devbox", name: "api", create: false)
        #expect(line.hasPrefix("'ssh' '-tt'"))
        #expect(line.contains("'agterm: api on devbox disconnected, exit'"))
        #expect(line.hasSuffix("exit \"$status\""))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd agtermCore && swift test --filter RemoteSessionTests`
Expected: compile failure, `hostAttachCommand` undefined.

- [ ] **Step 3: Open the two helpers and write the builders**

In `agtermCore/Sources/agtermCore/RemoteSession.swift` change `private static func sshArguments(` to `static func sshArguments(` and `private static func validate(host: String) throws {` to `static func validate(host: String) throws {`.

Create `agtermCore/Sources/agtermCore/RemoteHostCommands.swift`:

```swift
import Foundation

/// The ssh command lines that reach zmx on a host that runs no agterm. The far side keeps its own socket
/// directory and PATH conventions; agterm only widens the PATH sshd's non-interactive shell starts with.
extension RemoteSession {
    /// zmx.sh installs into `~/.local/bin`, Homebrew into `/usr/local/bin` or `/opt/homebrew/bin`, and sshd's
    /// remote-command shell reads no profile, so none of these is on PATH unless added here.
    static let hostPathPrefix = "PATH=\"$PATH:$HOME/.local/bin:$HOME/bin:/usr/local/bin:/opt/homebrew/bin\""

    private static let guardScript = "printf '%s\\n' 'agterm: remote session is gone'; exit 1"

    public static func hostListCommand(host: String, connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false)
            + [remoteChain(["zmx", "list"])]
    }

    /// `create: false` appends the create-only guard, so a name zmx no longer has fails visibly instead of
    /// becoming a fresh shell. `create: true` lets zmx create it, running `command` through `/bin/sh -c`
    /// instead of a login shell when one is given; an existing daemon ignores that payload.
    public static func hostAttachCommand(host: String, name: String, create: Bool, command: String? = nil,
                                         connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        try validate(sessionName: name)
        var attach = ["zmx", "attach", name]
        if !create {
            attach += ["/bin/sh", "-c", guardScript]
        } else if let command {
            attach += ["/bin/sh", "-c", command]
        }
        // the three the local pane clears too, empty being unset to zmx; ZMX_DIR stays the host's own
        let remote = CommandRestore.shellQuotedLine([
            "/usr/bin/env", "ZMX_SESSION=", "ZMX_SESSION_PREFIX=", "ZMX_NO_DETACH_KEY=1",
            "/bin/sh", "-c", hostPathPrefix + " && exec " + CommandRestore.shellQuotedLine(attach),
        ])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: true) + [remote]
    }

    /// The pane's command: the attach, then one line saying what died, held by `commandWait`.
    public static func hostAttachPaneCommand(host: String, name: String, create: Bool,
                                             command: String? = nil) throws -> String {
        let attach = CommandRestore.shellQuotedLine(
            try hostAttachCommand(host: host, name: name, create: create, command: command))
        let label = CommandRestore.shellQuotedLine(["agterm: \(name) on \(host) disconnected, exit"])
        return "\(attach); status=$?; printf '%s %s\\n' \(label) \"$status\"; exit \"$status\""
    }

    public static func hostKillCommand(host: String, name: String, connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        try validate(sessionName: name)
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false)
            + [remoteChain(["zmx", "kill", name])]
    }

    public static func isSessionName(_ value: String) -> Bool {
        (try? validate(sessionName: value)) != nil
    }

    /// A zmx session name becomes a socket file name, and zmx reads a leading `-` as an option.
    static func validate(sessionName: String) throws {
        guard isPlain(sessionName), !sessionName.contains("/"), !sessionName.hasPrefix("-") else {
            throw InvocationError.invalidSession
        }
    }

    /// One command for the far side's login shell, whatever shell that is: `/bin/sh -c '<PATH widening> && exec …>'`.
    private static func remoteChain(_ argv: [String]) -> String {
        CommandRestore.shellQuotedLine(["/bin/sh", "-c", hostPathPrefix + " && exec " + CommandRestore.shellQuotedLine(argv)])
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd agtermCore && swift test --filter RemoteSessionTests`
Expected: all PASS, including the pre-existing tests in that file.

- [ ] **Step 5: Commit**

```bash
git add agtermCore/Sources/agtermCore/RemoteSession.swift agtermCore/Sources/agtermCore/RemoteHostCommands.swift agtermCore/Tests/agtermCoreTests/RemoteSessionTests.swift
git commit -m "feat(remote): ssh argv for zmx list, attach, and kill on a plain host

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Protocol: commands, `create`, `remoteSessions`

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift` (`Command` cases after `zmxAttach`; `ControlArgs.create` after `host`; `ControlResult.remoteSessions` after `remote`)
- Modify: `agterm/Control/ControlServer.swift:514-515` (the exhaustive "dispatcher did not handle" list)
- Test: `agtermCore/Tests/agtermCoreTests/ControlDispatcherRemoteTests.swift` (created here with the wire tests; Task 4 adds the routing tests)

**Interfaces:**
- Produces: `Command.remoteList = "remote.list"`, `.remoteAttach = "remote.attach"`, `.remoteKill = "remote.kill"`; `ControlArgs.create: Bool?` (init parameter `create:` immediately after `host:`); `ControlResult.remoteSessions: [ControlRemoteHostSession]?` (init parameter `remoteSessions:` immediately after `remote:`).

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import agtermCore

/// Dispatcher and wire coverage for the `remote` group: sessions on a host that runs zmx and no agterm.
@MainActor
struct ControlDispatcherRemoteTests {
    private func dispatch(_ request: ControlRequest, _ actions: MockControlActions) async -> ControlResponse? {
        await ControlDispatcher(actions: actions).dispatch(request)
    }

    @Test(arguments: [(Command.remoteList, "remote.list"), (.remoteAttach, "remote.attach"), (.remoteKill, "remote.kill")])
    func remoteCommandsKeepTheirWireNames(command: Command, wire: String) throws {
        let json = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(ControlRequest(cmd: command))) as? [String: Any])
        #expect(json["cmd"] as? String == wire)
    }

    @Test func createAndRemoteSessionsSurviveTheWire() throws {
        let request = ControlRequest(cmd: .remoteAttach, target: "api",
                                     args: ControlArgs(host: "devbox", create: true, command: "claude"))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)

        let session = ControlRemoteHostSession(name: "api", clients: 2, cwd: "/srv", created: 7, labels: ["k": "v"])
        let data = try JSONEncoder().encode(ControlResult(remoteSessions: [session]))
        #expect(try JSONDecoder().decode(ControlResult.self, from: data).remoteSessions == [session])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd agtermCore && swift test --filter ControlDispatcherRemoteTests`
Expected: compile failure on `.remoteList`, `create:`, `remoteSessions:`.

- [ ] **Step 3: Add the protocol pieces**

In `ControlProtocol.swift`, after `case zmxAttach = "zmx.attach"`:

```swift
    case remoteList = "remote.list"
    case remoteAttach = "remote.attach"
    case remoteKill = "remote.kill"
```

In `ControlArgs`, after `public var host: String?`:

```swift
    /// For `remote.attach`: let zmx create the session when the name is absent (the CLI's `--create`);
    /// omitted/`false` attaches only, behind the create-only guard.
    public var create: Bool?
```

In `ControlArgs.init`, add `create: Bool? = nil,` immediately after `host: String? = nil,` in the parameter list, and `self.create = create` after `self.host = host`.

In `ControlResult`, after `public var remote: ControlRemoteTree?`:

```swift
    /// A zmx host's sessions, for `remote list`.
    public var remoteSessions: [ControlRemoteHostSession]?
```

In `ControlResult.init`, add `remoteSessions: [ControlRemoteHostSession]? = nil,` immediately after `remote: ControlRemoteTree? = nil,` and `self.remoteSessions = remoteSessions` after `self.remote = remote`.

In `agterm/Control/ControlServer.swift`, in the case list that ends `.zmxAttach, .dashboard, .version:`, change it to `.zmxAttach, .remoteList, .remoteAttach, .remoteKill, .dashboard, .version:` so the app target keeps compiling until Task 5 wires the arms.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd agtermCore && swift test --filter ControlDispatcherRemoteTests`
Expected: PASS. Also run `cd agtermCore && swift build` to confirm nothing else in the package broke.

- [ ] **Step 5: Commit**

```bash
git add agtermCore/Sources/agtermCore/ControlProtocol.swift agterm/Control/ControlServer.swift agtermCore/Tests/agtermCoreTests/ControlDispatcherRemoteTests.swift
git commit -m "feat(control): remote.list, remote.attach, remote.kill on the wire

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `ControlActions` requirements, defaults, mock, and the dispatcher arm

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlDispatcher.swift` (protocol after `attachRemoteSession(host:session:window:)`; routing switch near line 200)
- Modify: `agtermCore/Sources/agtermCore/ControlActionsDefaults.swift` (after `attachRemoteSession(host:session:)` default)
- Create: `agtermCore/Sources/agtermCore/ControlDispatcher+Remote.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/MockControlActions.swift` (`Call` cases after `zmxAttach`; `next…` vars after `nextRemoteAttachResponse`; methods after `attachRemoteSession`)
- Test: `agtermCore/Tests/agtermCoreTests/ControlDispatcherRemoteTests.swift` (append)

**Interfaces:**
- Consumes: `RemoteSession.isSessionName(_:)`, `ControlArgs.create`.
- Produces on `ControlActions`: `listRemoteHostSessions(host: String) async -> ControlResponse`, `attachRemoteHostSession(host: String, name: String, window: String?, create: Bool, command: String?) async -> ControlResponse`, `killRemoteHostSession(host: String, name: String) async -> ControlResponse`. Mock `Call` cases: `.remoteList(host:)`, `.remoteAttach(host:name:window:create:command:)`, `.remoteKill(host:name:)`.

- [ ] **Step 1: Write the failing tests** (append inside `struct ControlDispatcherRemoteTests`)

```swift
    @Test func listRoutesTheHost() async {
        let actions = MockControlActions()
        _ = await dispatch(ControlRequest(cmd: .remoteList, args: ControlArgs(host: " devbox ")), actions)
        #expect(actions.calls == [.remoteList(host: "devbox")])
    }

    @Test func attachRoutesEveryArgumentAndDefaultsCreateToFalse() async {
        let actions = MockControlActions()
        _ = await dispatch(ControlRequest(cmd: .remoteAttach, target: "api",
                                          args: ControlArgs(host: "devbox", window: "w1")), actions)
        _ = await dispatch(ControlRequest(cmd: .remoteAttach, target: "api",
                                          args: ControlArgs(host: "devbox", create: true, command: "claude")), actions)
        #expect(actions.calls == [
            .remoteAttach(host: "devbox", name: "api", window: "w1", create: false, command: nil),
            .remoteAttach(host: "devbox", name: "api", window: nil, create: true, command: "claude"),
        ])
    }

    @Test func killRoutesOnlyWithForce() async {
        let actions = MockControlActions()
        let refused = await dispatch(ControlRequest(cmd: .remoteKill, target: "api",
                                                    args: ControlArgs(host: "devbox")), actions)
        #expect(refused?.error == "remote.kill requires --force")
        _ = await dispatch(ControlRequest(cmd: .remoteKill, target: "api",
                                          args: ControlArgs(force: true, host: "devbox")), actions)
        #expect(actions.calls == [.remoteKill(host: "devbox", name: "api")])
    }

    @Test(arguments: [Command.remoteList, .remoteAttach, .remoteKill])
    func everyRemoteCommandRequiresAHost(command: Command) async {
        let actions = MockControlActions()
        let response = await dispatch(ControlRequest(cmd: command, target: "api", args: ControlArgs(force: true)), actions)
        #expect(response?.error == "\(command.rawValue) requires a host")
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [Command.remoteAttach, .remoteKill])
    func attachAndKillRequireASessionName(command: Command) async {
        let actions = MockControlActions()
        let response = await dispatch(ControlRequest(cmd: command, args: ControlArgs(force: true, host: "devbox")), actions)
        #expect(response?.error == "\(command.rawValue) requires a session name")
        #expect(actions.calls.isEmpty)
    }

    // the unresolved-session message names the session, so a control character reaching it would be
    // printed to a terminal by agtermctl after JSON decoding
    @Test(arguments: ["api\nrm -rf /", "a b", "a/b", "-rf"])
    func attachRefusesAnUnsafeNameBeforeTheHostIsReached(_ name: String) async {
        let actions = MockControlActions()
        let response = await dispatch(ControlRequest(cmd: .remoteAttach, target: name,
                                                     args: ControlArgs(host: "devbox")), actions)
        #expect(response?.error == "invalid remote session")
        #expect(actions.calls.isEmpty)
    }

    @Test func aCommandWithoutCreateIsRefused() async {
        let actions = MockControlActions()
        let response = await dispatch(ControlRequest(cmd: .remoteAttach, target: "api",
                                                     args: ControlArgs(host: "devbox", command: "claude")), actions)
        #expect(response?.error == "remote.attach --command requires --create")
        #expect(actions.calls.isEmpty)
    }

    // agtermCore is a library the agterm-linux fork consumes, so every Mac-only requirement ships a default
    @Test func theDefaultsRefuseByName() {
        #expect(ControlActionsUnsupported.message("remote.list") == "remote.list is not supported on this platform")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd agtermCore && swift test --filter ControlDispatcherRemoteTests`
Expected: compile failure on `.remoteList(host:)` in `Call`.

- [ ] **Step 3: Add the requirements, defaults, mock, and arm**

`ControlDispatcher.swift`, protocol, after the `attachRemoteSession(host:session:window:)` requirement:

```swift
    /// `remote.list`: the sessions zmx reports on a host that runs no agterm.
    func listRemoteHostSessions(host: String) async -> ControlResponse
    /// `remote.attach`: a local session running `ssh … zmx attach <name>` on that host.
    func attachRemoteHostSession(host: String, name: String, window: String?, create: Bool,
                                 command: String?) async -> ControlResponse
    /// `remote.kill`: `zmx kill <name>` on that host.
    func killRemoteHostSession(host: String, name: String) async -> ControlResponse
```

`ControlDispatcher.swift`, routing switch, after the `case .restoreMode, .zmxList, … .zmxAttach:` arm:

```swift
        case .remoteList, .remoteAttach, .remoteKill:
            return await dispatchRemoteCommand(request)
```

`ControlActionsDefaults.swift`, after the `attachRemoteSession(host:session:)` default:

```swift
    func listRemoteHostSessions(host _: String) async -> ControlResponse {
        ControlResponse(ok: false, error: ControlActionsUnsupported.message("remote.list"))
    }

    func attachRemoteHostSession(host _: String, name _: String, window _: String?, create _: Bool,
                                 command _: String?) async -> ControlResponse {
        ControlResponse(ok: false, error: ControlActionsUnsupported.message("remote.attach"))
    }

    func killRemoteHostSession(host _: String, name _: String) async -> ControlResponse {
        ControlResponse(ok: false, error: ControlActionsUnsupported.message("remote.kill"))
    }
```

New `agtermCore/Sources/agtermCore/ControlDispatcher+Remote.swift`:

```swift
import Foundation

extension ControlDispatcher {
    /// The `remote` group. Split out like `+Zmx` so `ControlDispatcher.swift` stays inside the file limit.
    func dispatchRemoteCommand(_ request: ControlRequest) async -> ControlResponse {
        // the target names a session on ANOTHER machine, so there is no `active` default anywhere here
        guard let host = request.args?.host?.trimmedOrNil else {
            return ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a host")
        }
        if request.cmd == .remoteList {
            return await actions.listRemoteHostSessions(host: host)
        }
        guard let name = request.target?.trimmedOrNil else {
            return ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a session name")
        }
        // refused before it can reach an argv or an error message a terminal would print
        guard RemoteSession.isSessionName(name) else {
            return ControlResponse(ok: false, error: "invalid remote session")
        }
        switch request.cmd {
        case .remoteKill:
            guard request.args?.force == true else {
                return ControlResponse(ok: false, error: "remote.kill requires --force")
            }
            return await actions.killRemoteHostSession(host: host, name: name)
        case .remoteAttach:
            let create = request.args?.create == true
            let command = request.args?.command?.trimmedOrNil
            guard command == nil || create else {
                return ControlResponse(ok: false, error: "remote.attach --command requires --create")
            }
            return await actions.attachRemoteHostSession(host: host, name: name,
                                                         window: request.args?.window?.trimmedOrNil,
                                                         create: create, command: command)
        default:
            preconditionFailure("unexpected remote command: \(request.cmd.rawValue)")
        }
    }
}
```

`MockControlActions.swift`: in `enum Call`, after `case zmxAttach(host: String, session: String)`:

```swift
        case remoteList(host: String)
        case remoteAttach(host: String, name: String, window: String?, create: Bool, command: String?)
        case remoteKill(host: String, name: String)
```

after `var nextRemoteAttachResponse = ControlResponse(ok: true)`:

```swift
    var nextRemoteListResponse = ControlResponse(ok: true)
    var nextRemoteHostAttachResponse = ControlResponse(ok: true)
    var nextRemoteKillResponse = ControlResponse(ok: true)
```

after the `attachRemoteSession(host:session:)` method:

```swift
    func listRemoteHostSessions(host: String) async -> ControlResponse {
        calls.append(.remoteList(host: host))
        return nextRemoteListResponse
    }

    func attachRemoteHostSession(host: String, name: String, window: String?, create: Bool,
                                 command: String?) async -> ControlResponse {
        calls.append(.remoteAttach(host: host, name: name, window: window, create: create, command: command))
        return nextRemoteHostAttachResponse
    }

    func killRemoteHostSession(host: String, name: String) async -> ControlResponse {
        calls.append(.remoteKill(host: host, name: name))
        return nextRemoteKillResponse
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd agtermCore && swift test --filter "ControlDispatcherRemoteTests|ControlDispatcherZmxTests"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add agtermCore/Sources/agtermCore/ControlDispatcher.swift agtermCore/Sources/agtermCore/ControlDispatcher+Remote.swift agtermCore/Sources/agtermCore/ControlActionsDefaults.swift agtermCore/Tests/agtermCoreTests/MockControlActions.swift agtermCore/Tests/agtermCoreTests/ControlDispatcherRemoteTests.swift
git commit -m "feat(control): dispatch the remote group with host, name, create, and force checks

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The app arms: ssh through the runner, the pane into the store

**Files:**
- Create: `agterm/Control/ControlServer+Remote.swift`
- Modify: `agterm/Control/ControlServer.swift:422` (`waitsOnNetwork`)
- Test: `agtermTests/ControlServerRemoteTests.swift`

**Interfaces:**
- Consumes: `RemoteSession.hostListCommand/hostAttachPaneCommand/hostKillCommand`, `RemoteHostList.parse`, `ControlServer.remoteRunner: any RemoteCommandRunner`, `ControlServer.remoteTreeDeadline`, `resolveOpenWindow(_:)`, `AppStore.addSession(toWorkspace:cwd:command:name:wait:at:select:remoteHost:)`, `AppActions.focusSplitPane(_:wantSplit:)`.
- Produces: `ControlServer` conformance for the three `ControlActions` requirements from Task 4.

- [ ] **Step 1: Write the failing tests**

Targeted run needs the project generated once: `./scripts/setup.sh && xcodegen generate` (idempotent).

```swift
import AppKit
import XCTest
@testable import agterm
import agtermCore

/// Hosted coverage for the `remote` group: ssh goes through the injected runner, and the pane lands in
/// the store as an ordinary command session marked remote.
@MainActor
final class ControlServerRemoteTests: XCTestCase {
    private static let listing = """
    name=api\tpid=1\tclients=1\tcreated=5\tcwd=file://devbox/home/me/api\tproject=api
    name=agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1\tpid=2\tclients=1
    """

    func testListParsesTheFarSidesRowsInOneInvocation() async throws {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: Self.listing, stderr: ""))
        let server = makeServer(remoteRunner: runner)

        let response = await server.listRemoteHostSessions(host: "devbox")

        let sessions = try XCTUnwrap(response.result?.remoteSessions)
        XCTAssertEqual(sessions.map(\.name), ["api"])
        XCTAssertEqual(sessions.first?.labels, ["project": "api"])
        XCTAssertEqual(runner.invocations.count, 1)
        let argv = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(argv.prefix(2), ["ssh", "-T"])
        XCTAssertEqual(argv.last?.contains("zmx"), true)
        XCTAssertEqual(argv.last?.contains("list"), true)
    }

    func testListNamesAMissingZmxInsteadOfTheShellsComplaint() async {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 127, stdout: "", stderr: "sh: zmx: not found"))
        let response = await makeServer(remoteRunner: runner).listRemoteHostSessions(host: "devbox")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "zmx is not installed on devbox")
    }

    func testAnSshFailureReportsItsStderr() async {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 255, stdout: "", stderr: "Permission denied (publickey).\n"))
        let response = await makeServer(remoteRunner: runner).listRemoteHostSessions(host: "devbox")
        XCTAssertEqual(response.error, "Permission denied (publickey).")
    }

    func testAHostileHostIsRefusedWithoutRunningAnythingAndNotEchoed() async {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: "", stderr: ""))
        let response = await makeServer(remoteRunner: runner).listRemoteHostSessions(host: "-oProxyCommand=x")
        XCTAssertEqual(response.error, "invalid host")
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testAttachInsertsARemoteCommandSessionWithoutSshingFirst() async throws {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: "", stderr: ""))
        let server = makeServer(remoteRunner: runner)
        let store = try XCTUnwrap(library.activeStore)

        let response = await ControlDispatcher(actions: server).dispatch(ControlRequest(
            cmd: .remoteAttach, target: "api", args: ControlArgs(host: "devbox", create: true, command: "claude")))

        XCTAssertEqual(response?.ok, true)
        let created = try XCTUnwrap(store.workspaces.flatMap(\.sessions).first { $0.remoteHost != nil })
        XCTAssertEqual(created.id.uuidString, response?.result?.id)
        XCTAssertEqual(created.remoteHost, "devbox")
        XCTAssertEqual(created.customName, "api")
        XCTAssertTrue(created.commandWait)
        let command = try XCTUnwrap(created.initialCommand)
        XCTAssertTrue(command.contains("'ssh' '-tt'"))
        XCTAssertTrue(command.contains("claude"))
        XCTAssertEqual(store.selectedSessionID, created.id)
        XCTAssertTrue(runner.invocations.isEmpty, "attach builds a pane; ssh starts inside it")
    }

    func testAttachWithoutCreateCarriesTheGuard() async throws {
        let server = makeServer(remoteRunner: FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: "", stderr: "")))
        let store = try XCTUnwrap(library.activeStore)
        _ = await server.attachRemoteHostSession(host: "devbox", name: "api", window: nil, create: false, command: nil)
        let created = try XCTUnwrap(store.workspaces.flatMap(\.sessions).first { $0.remoteHost != nil })
        XCTAssertTrue(try XCTUnwrap(created.initialCommand).contains("remote session is gone"))
    }

    func testAttachTargetsABackgroundWindowAndRefusesAClosedOne() async throws {
        let front = try XCTUnwrap(library.activeWindowID)
        let frontStore = try XCTUnwrap(library.activeStore)
        let destination = library.newWindow(name: "other").id
        let destinationStore = try XCTUnwrap(library.loadStore(for: destination))
        library.frontmostWindowID = front
        let before = frontStore.workspaces.flatMap(\.sessions).count
        let server = makeServer(remoteRunner: FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: "", stderr: "")))

        let placed = await server.attachRemoteHostSession(host: "devbox", name: "api",
                                                          window: String(destination.uuidString.prefix(8)),
                                                          create: false, command: nil)
        XCTAssertTrue(placed.ok)
        XCTAssertEqual(destinationStore.workspaces.flatMap(\.sessions).filter { $0.remoteHost != nil }.count, 1)
        XCTAssertEqual(frontStore.workspaces.flatMap(\.sessions).count, before)
        XCTAssertEqual(library.activeWindowID, front)

        let refused = await server.attachRemoteHostSession(host: "devbox", name: "api",
                                                           window: UUID().uuidString, create: false, command: nil)
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(frontStore.workspaces.flatMap(\.sessions).count, before)
    }

    func testKillRunsZmxKillAndEchoesWhatItSaid() async throws {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 0, stdout: "killed session api\n", stderr: ""))
        let response = await makeServer(remoteRunner: runner).killRemoteHostSession(host: "devbox", name: "api")
        XCTAssertEqual(response.result?.text, "killed session api")
        let remote = try XCTUnwrap(runner.invocations.first?.last)
        XCTAssertTrue(remote.contains("kill"))
        XCTAssertTrue(remote.contains("api"))
    }

    func testKillNamesAMissingZmx() async {
        let runner = FakeRemoteRunner(result: RemoteCommandResult(status: 127, stdout: "", stderr: ""))
        let response = await makeServer(remoteRunner: runner).killRemoteHostSession(host: "devbox", name: "api")
        XCTAssertEqual(response.error, "zmx is not installed on devbox")
    }

    private var stateDir: URL!
    private var library: WindowLibrary!
    private var settingsModel: SettingsModel!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-remote-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            settingsModel = SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir))
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            settingsModel = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
        }
        try await super.tearDown()
    }

    private func makeServer(remoteRunner: any RemoteCommandRunner) -> ControlServer {
        ControlServer(library: library, actions: AppActions(library: library), settingsModel: settingsModel,
                      identity: AppIdentity(version: "9.9.9", commit: "testsha"),
                      remoteRunner: remoteRunner,
                      socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
    }
}

/// Records what it was asked to run and answers with a canned result.
private final class FakeRemoteRunner: RemoteCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let result: RemoteCommandResult

    var invocations: [[String]] { lock.withLock { recorded } }

    init(result: RemoteCommandResult) { self.result = result }

    func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
        lock.withLock { recorded.append(argv) }
        return result
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project agterm.xcodeproj -scheme agtermTests -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:agtermTests/ControlServerRemoteTests 2>&1 | tail -30`
Expected: compile failure, `listRemoteHostSessions` is not a member of `ControlServer`.

- [ ] **Step 3: Write the arms**

Create `agterm/Control/ControlServer+Remote.swift`:

```swift
import AppKit
import agtermCore
import Foundation

/// The `remote` group: zmx sessions on a host that runs nothing of agterm's. List and kill are one ssh each
/// through the injected runner; attach never sshes here — the pane's own command does, so a transport
/// failure is an ordinary held pane exit, as for `zmx.attach`.
extension ControlServer {
    func listRemoteHostSessions(host: String) async -> ControlResponse {
        let argv: [String]
        do {
            argv = try RemoteSession.hostListCommand(host: host)
        } catch {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteTreeDeadline)
        if let failure = Self.remoteHostFailure(result, host: host) { return failure }
        return ControlResponse(ok: true, result: ControlResult(remoteSessions: RemoteHostList.parse(result.stdout)))
    }

    func attachRemoteHostSession(host: String, name: String, window: String?, create: Bool,
                                 command: String?) async -> ControlResponse {
        let pane: String
        do {
            pane = try RemoteSession.hostAttachPaneCommand(host: host, name: name, create: create, command: command)
        } catch RemoteSession.InvocationError.invalidSession {
            return ControlResponse(ok: false, error: "invalid remote session")
        } catch {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let store: AppStore
        switch resolveOpenWindow(window) {
        case .failure(let response): return response
        case .success(let (_, resolved)): store = resolved
        }
        guard let workspace = store.currentWorkspaceID else {
            return ControlResponse(ok: false, error: "no window to attach into")
        }
        // the LOCAL home: libghostty chdirs the ssh process here, and the far side's path may not exist
        guard let created = store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), command: pane,
                                             name: name, wait: true, remoteHost: host) else {
            return ControlResponse(ok: false, error: "could not create the session")
        }
        actions.focusSplitPane(created, wantSplit: false)
        return ControlResponse(ok: true, result: ControlResult(id: created.id.uuidString))
    }

    func killRemoteHostSession(host: String, name: String) async -> ControlResponse {
        let argv: [String]
        do {
            argv = try RemoteSession.hostKillCommand(host: host, name: name)
        } catch RemoteSession.InvocationError.invalidSession {
            return ControlResponse(ok: false, error: "invalid remote session")
        } catch {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteTreeDeadline)
        if let failure = Self.remoteHostFailure(result, host: host) { return failure }
        let said = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ControlResponse(ok: true, result: ControlResult(text: said.isEmpty ? "killed \(name) on \(host)" : said))
    }

    /// 127 is the far side's shell failing to find zmx, which deserves its own sentence; any other nonzero
    /// status reports what ssh or zmx said, intact, as `zmx.tree` does.
    private static func remoteHostFailure(_ result: RemoteCommandResult, host: String) -> ControlResponse? {
        guard result.status != 0 else { return nil }
        if result.status == 127 { return ControlResponse(ok: false, error: "zmx is not installed on \(host)") }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return ControlResponse(ok: false, error: stderr.isEmpty ? "the remote command failed on \(host)" : stderr)
    }
}
```

In `ControlServer.swift`, `waitsOnNetwork` becomes:

```swift
    nonisolated private static func waitsOnNetwork(_ cmd: Command) -> Bool {
        cmd == .zmxTree || cmd == .zmxAttach || cmd == .remoteList || cmd == .remoteKill
    }
```

and update its doc comment's first sentence to `Commands whose dispatch awaits an ssh round trip: the zmx tree and attach, and the remote list and kill.`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project agterm.xcodeproj -scheme agtermTests -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:agtermTests/ControlServerRemoteTests 2>&1 | tail -30`
Expected: `** TEST SUCCEEDED **` with every `ControlServerRemoteTests` method passing.

- [ ] **Step 5: Commit**

```bash
git add agterm/Control/ControlServer+Remote.swift agterm/Control/ControlServer.swift agtermTests/ControlServerRemoteTests.swift
git commit -m "feat(remote): list, attach, and kill zmx sessions on a plain host

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `agtermctl remote list|attach|kill` and its human output

**Files:**
- Create: `agtermCore/Sources/agtermctlKit/RemoteCommands.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift:91-93` (register `Remote.self` after `Zmx.self`)
- Modify: `agtermCore/Sources/agtermctlKit/SocketClient.swift` (formatting chain before the `remote` branch; new `formatRemoteHostSessions`)
- Test: `agtermCore/Tests/agtermctlKitTests/RemoteCommandsTests.swift`

**Interfaces:**
- Consumes: `Command.remoteList/.remoteAttach/.remoteKill`, `ControlArgs(host:create:command:window:)`, `ControlResult.remoteSessions`, `RequestCommand`, `BasicOptions`.
- Produces: `Remote.List`, `Remote.Attach`, `Remote.Kill` parsable commands; `SocketClient.formatRemoteHostSessions(_:) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
import ArgumentParser
import Foundation
import Testing
@testable import agtermCore
@testable import agtermctlKit

/// The requests the remote group builds and the rows it prints. Nothing here touches a socket.
struct RemoteCommandsTests {
    @Test func listSendsTheHostAsAnArgument() throws {
        let request = try Remote.List.parse(["devbox"]).makeRequest()
        #expect(request.cmd == .remoteList)
        #expect(request.args?.host == "devbox")
        #expect(request.target == nil)
    }

    @Test func attachSendsHostNameWindowCreateAndCommand() throws {
        let plain = try Remote.Attach.parse(["devbox", "api"]).makeRequest()
        #expect(plain.cmd == .remoteAttach)
        #expect(plain.target == "api")
        #expect(plain.args?.host == "devbox")
        #expect(plain.args?.create == nil, "absent rather than false, like every optional flag on the wire")
        #expect(plain.args?.command == nil)

        let full = try Remote.Attach.parse(["devbox", "api", "--create", "--command", "claude", "--window", "w1"]).makeRequest()
        #expect(full.args?.create == true)
        #expect(full.args?.command == "claude")
        #expect(full.args?.window == "w1")
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(full)) == full)
    }

    @Test func attachRefusesACommandWithoutCreateBeforeSendingAnything() {
        #expect(throws: (any Error).self) { try Remote.Attach.parse(["devbox", "api", "--command", "claude"]) }
    }

    @Test(arguments: [[], ["devbox"]])
    func attachAndKillNeedBothAHostAndAName(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try Remote.Attach.parse(arguments) }
        #expect(throws: (any Error).self) { try Remote.Kill.parse(arguments + ["--force"]) }
    }

    @Test func killRequiresForceAndSendsIt() throws {
        #expect(throws: (any Error).self) { try Remote.Kill.parse(["devbox", "api"]) }
        let request = try Remote.Kill.parse(["devbox", "api", "--force"]).makeRequest()
        #expect(request.cmd == .remoteKill)
        #expect(request.target == "api")
        #expect(request.args?.host == "devbox")
        #expect(request.args?.force == true)
    }

    @Test func attachEchoesTheSessionItCreated() throws {
        #expect(try Remote.Attach.parse(["devbox", "api"]).echoesResultID)
        #expect(try !Remote.List.parse(["devbox"]).echoesResultID)
    }

    @Test func listRendersOneRowPerSessionAndSaysWhenThereAreNone() {
        let rows = [
            ControlRemoteHostSession(name: "api", clients: 1, cwd: "/home/me/api", labels: ["role": "worker", "project": "api"]),
            ControlRemoteHostSession(name: "build", clients: 0),
        ]
        #expect(SocketClient.formatRemoteHostSessions(rows) == """
          api  1 client  /home/me/api  project=api role=worker
          build  0 clients
        """)
        #expect(SocketClient.formatRemoteHostSessions([]) == "no sessions")
    }

    @Test func theRootCommandListsRemote() {
        #expect(Agtermctl.configuration.subcommands.contains { $0 == Remote.self })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd agtermCore && swift test --filter RemoteCommandsTests`
Expected: compile failure, `Remote` undefined.

- [ ] **Step 3: Write the commands and the formatter**

Create `agtermCore/Sources/agtermctlKit/RemoteCommands.swift`:

```swift
import ArgumentParser
import Foundation
import agtermCore

// MARK: - remote

struct Remote: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sessions on a host that runs zmx.",
        discussion: """
        Any Linux or Mac host with zmx installed and reachable over key-based ssh; nothing of agterm's is \
        needed there. `remote list` reads the host's own `zmx list`, `remote attach` opens one of those \
        sessions here as a session marked remote, and `remote kill` ends one. A host that also runs agterm \
        keeps its own live-pane sessions out of this listing: those are `zmx tree` and `zmx attach`.

        Every connection is non-interactive: ssh runs with BatchMode, so key-based auth must already work \
        for the host and a password or host-key prompt is a failure rather than a question. zmx is found \
        through the far side's PATH plus ~/.local/bin, ~/bin, /usr/local/bin and /opt/homebrew/bin.
        """,
        subcommands: [List.self, Attach.self, Kill.self]
    )

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the zmx sessions on a host.",
            discussion: """
            One row per session: its name, how many clients are attached, its working directory when zmx \
            reports one, and its labels. An empty list is a successful answer. A host without zmx answers \
            that zmx is not installed.
            """)
        @Argument(help: "The host, as ssh would take it.")
        var host: String
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .remoteList, args: ControlArgs(host: host))
        }
    }

    struct Attach: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Attach to a zmx session on a host, as a session here.",
            discussion: """
            Opens a session marked remote whose pane runs `ssh -tt HOST zmx attach NAME`, in the chosen local \
            window's current workspace, selected. Without --create the attach refuses a name zmx no longer \
            has, so a session gone since the listing fails visibly instead of becoming a fresh shell wearing \
            its name. With --create zmx creates it when absent, running --command instead of a login shell; \
            an existing session ignores that command.

            Closing the session here ends only this side's connection; the far-side process keeps running. \
            It is not restored after a relaunch.
            """)
        @Argument(help: "The host, as ssh would take it.")
        var host: String
        @Argument(help: "The zmx session name, as `remote list` prints it.")
        var name: String
        @Flag(name: .long, help: "Let zmx create the session when the name does not exist.")
        var create = false
        @Option(name: .long, help: "What a NEW session runs instead of a login shell; needs --create.")
        var command: String?
        @Option(name: .long, help: "Local open window id, unique prefix, or active (default: frontmost).")
        var window: String?
        @OptionGroup var options: BasicOptions

        /// It creates a local session, so it echoes that session's id like every other create command.
        var echoesResultID: Bool { true }

        func validate() throws {
            guard command == nil || create else {
                throw ValidationError("--command needs --create; an existing session keeps what it is running")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .remoteAttach, target: name,
                           args: ControlArgs(host: host, create: create ? true : nil, command: command, window: window))
        }
    }

    struct Kill: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "End a zmx session on a host and the process running in it.",
            discussion: """
            Runs `zmx kill NAME` on the host. Every client attached to that session, a pane here included, \
            sees its connection end, so --force is required as confirmation.
            """)
        @Argument(help: "The host, as ssh would take it.")
        var host: String
        @Argument(help: "The zmx session name, as `remote list` prints it.")
        var name: String
        @Flag(name: .long, help: "Required. Confirms ending the process running in that session.")
        var force = false
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard force else { throw ValidationError("--force is required to end a running process") }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .remoteKill, target: name, args: ControlArgs(force: true, host: host))
        }
    }
}
```

In `Commands.swift`, change `Zmx.self, Version.self]` to `Zmx.self, Remote.self, Version.self]`.

In `SocketClient.swift`, before `if let remote = response.result?.remote {`:

```swift
        if let sessions = response.result?.remoteSessions {
            return formatRemoteHostSessions(sessions)
        }
```

and after `formatRemoteTree`:

```swift
    /// A zmx host's sessions, one per line: name, attached clients, directory when reported, labels sorted
    /// by key. An empty answer says so rather than printing nothing.
    static func formatRemoteHostSessions(_ sessions: [ControlRemoteHostSession]) -> String {
        guard !sessions.isEmpty else { return "no sessions" }
        return sessions.map { session in
            let clients = session.clients == 1 ? "1 client" : "\(session.clients) clients"
            let labels = session.labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return ["  \(session.name)", clients, session.cwd, labels.isEmpty ? nil : labels]
                .compactMap { $0 }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd agtermCore && swift test --filter "RemoteCommandsTests|ZmxCommandsTests|CommandsTests"`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add agtermCore/Sources/agtermctlKit/RemoteCommands.swift agtermCore/Sources/agtermctlKit/Commands.swift agtermCore/Sources/agtermctlKit/SocketClient.swift agtermCore/Tests/agtermctlKitTests/RemoteCommandsTests.swift
git commit -m "feat(agtermctl): remote list, attach, and kill

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Documentation on every synchronized surface

**Files:**
- Modify: `.claude/rules/control-api.md` (catalog list after the `zmx.*` line; new subsection after the `## Remote sessions` bullets, before `## Session backgrounds`)
- Modify: `plugins/agterm/skills/agterm/SKILL.md` (a `**remote**` entry after the `**zmx**` entry in the command summary)
- Modify: `plugins/agterm/skills/agterm/reference.md` (results list near line 18; a `## remote` section after the zmx attach text, before the `restore-denylist.conf` paragraph)
- Modify: `plugins/agterm/skills/agterm/examples.md` (new section after `## Attach a session running on another Mac`)
- Modify: `site/commands.html` (results list near line 302; a `<section id="remote">` before `<section id="version">`; the page's section index if `href="#zmx"` appears in one)
- Modify: `site/docs.html` (a paragraph and code block after the Remote sessions paragraph that ends `Settings ▸ Interface.`)
- Modify: `README.md` (a bullet after `**Agent status.**`)
- Test: `agtermCore/Tests/agtermCoreTests/SkillInstallTests.swift` (`bundledSkillDocumentsEventSubscriptionCommand`)

- [ ] **Step 1: Write the failing test** (append inside `bundledSkillDocumentsEventSubscriptionCommand`, after its last `#expect`)

```swift
        #expect(skill.contains("`remote attach HOST NAME [--create] [--command CMD] [--window W]`"))
        #expect(reference.contains("## remote"))
        #expect(reference.contains("`agtermctl remote list HOST`"))
        #expect(examples.contains("agtermctl remote attach"))
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd agtermCore && swift test --filter SkillInstallTests`
Expected: FAIL on the four new expectations.

- [ ] **Step 3: Write the documentation**

`.claude/rules/control-api.md`, catalog: after `- \`zmx.list\`, \`zmx.prune\`, \`zmx.kill\`, \`zmx.tree\`, \`zmx.attach\`` add:

```
- `remote.list`, `remote.attach`, `remote.kill`
```

Same file, after the last bullet of `## Remote sessions` (the one ending `is not part of this work.`) and before `## Session backgrounds`:

```
## Remote zmx hosts

- The `remote` group reaches a host that runs zmx and nothing of agterm's; `zmx tree`/`zmx attach` stay the
  agterm-to-agterm teleport by session id. Two listings that answer different questions beat one verb
  with two shapes: a zmx host has no windows, workspaces, splits, or `agtermctl`.
- `remote.list {host}` runs the far side's own `zmx list` and parses its tab-separated `key=value` rows
  (`RemoteHostList`): `name`, `clients`, `cwd` (the path of the `file://` URI), `created`, and every other
  key as `labels`. Names passing `ZmxSupport.isDaemonName` are omitted: they belong to an agterm on that
  host and are reached through `zmx tree`, where their split and ownership are known. Prose lines carry no
  `name=` and are skipped, so an empty listing is a successful empty answer.
- `remote.attach {host, target, window?, create?, command?}` inserts an ordinary command session with
  `remoteHost`, `wait`, this Mac's home as cwd, and `RemoteSession.hostAttachPaneCommand` as the command.
  It never sshes before insertion: ssh starts inside the pane, so a transport failure is a held pane exit,
  as for `zmx.attach`. Without `create` the argv carries the same create-only guard `zmx.attach` uses; with
  it the guard is dropped and `command`, if given, runs through `/bin/sh -c` instead of a login shell for a
  NEW daemon (an existing one ignores it). `command` without `create` is refused by the dispatcher and by
  `agtermctl` before anything is sent.
- `remote.kill {host, target, force}` runs `zmx kill <name>` on the host; `force` is agterm's confirmation
  and is never passed to zmx, whose own `--force` unlinks an unreadable socket.
- The attach env clears `ZMX_SESSION`/`ZMX_SESSION_PREFIX` and sets `ZMX_NO_DETACH_KEY=1` like both other
  attach shapes, but sets NO `ZMX_DIR`: the daemon lives where the user's own ssh shell would find it. zmx is
  resolved through PATH widened with `$HOME/.local/bin:$HOME/bin:/usr/local/bin:/opt/homebrew/bin`, because
  sshd's non-interactive shell reads no profile and zmx.sh installs into `~/.local/bin`; the chain travels
  as `/bin/sh -c` for the same account-shell reason as `treeCommand`.
- Exit 127 from the list or kill chain reports `zmx is not installed on <host>`; any other nonzero exit
  reports the trimmed stderr intact, as `zmx.tree` does. The host is validated by `RemoteSession`'s rule
  and never echoed unless it passed; a session name must be plain, contain no `/` (it becomes a socket file
  name), and not start with `-` (zmx reads that as an option), refused as `invalid remote session` before
  it reaches an argv or an error message.
- `remote.list` and `remote.kill` join `zmx.tree`/`zmx.attach` in `waitsOnNetwork`; `remote.attach` stays
  inline because it touches only the model.
- Not restored after a relaunch, by `Session.remoteHost`'s existing rule. Lifting that for a plain zmx host
  is a separate change to `isPersistable` and the restore capture, recorded as a decision in the spec.
- When no other client holds the daemon, this attach is its leader and the far side is sized to the pane
  from the first byte; the follower limitations documented above apply only while another client is attached.
```

`plugins/agterm/skills/agterm/SKILL.md`: after the `**zmx**` summary entry (the paragraph that ends with the `zmx attach` text and its ssh precondition), add a new paragraph:

```
**remote** - sessions on a host that runs zmx and nothing of agterm's (Linux or Mac, zmx 0.7+, key-based
ssh) · `remote list HOST` - the host's own `zmx list`: one row per session with name, attached clients,
directory and labels; agterm's own live-pane daemons on a host that also runs agterm are omitted (use
`zmx tree` for those) · `remote attach HOST NAME [--create] [--command CMD] [--window W]` - open one here,
marked remote, in the chosen local window's current workspace; without `--create` a name zmx no longer has
fails instead of becoming a fresh shell, with it zmx creates the session and runs `--command` instead of a
login shell (an existing session ignores the command). Closing it ends only this side's connection and it
is not restored after a relaunch · `remote kill HOST NAME --force` - `zmx kill` on the host, ending the
process and every attached client.
```

`plugins/agterm/skills/agterm/reference.md`: in the results list, change `` `remote` (another Mac's attachable sessions, for `zmx tree`), `` to `` `remote` (another Mac's attachable sessions, for `zmx tree`), `remoteSessions` (a zmx host's sessions, for `remote list`), ``. After the paragraph `Every zmx command needs a running agterm: … With agterm stopped there is nothing to ask.` add:

```
## remote

Sessions on a host that runs zmx and nothing of agterm's: any Linux or Mac box with zmx 0.7 or later
installed (zmx.sh, `brew install neurosnap/tap/zmx`, or a distribution package) and reachable over
key-based ssh. Nothing else is needed on the host. A host that also runs agterm keeps its own live-pane
daemons out of this listing; those are `zmx tree` and `zmx attach`.

`agtermctl remote list HOST` — runs the host's own `zmx list` over ssh. `result.remoteSessions` carries one
row per session: `name`, `clients` (attached clients), `cwd` (when zmx reports one), `created` (unix
seconds) and `labels` (every other `key=value` on the row, as set with `zmx set`). An empty list is a
successful answer. A host without zmx answers `zmx is not installed on HOST`; any other failure reports what
ssh or zmx said.

`agtermctl remote attach HOST NAME [--create] [--command CMD] [--window W]` — opens NAME here as a session
marked remote, in the destination window's current workspace, selected; returns its `id`, and its tree node
carries `remoteHost`. The pane runs `ssh -tt HOST zmx attach NAME`, so the far side's screen and scrollback
replay into the pane and programs inside it reach agterm the way local ones do (notifications, working
directory, prompt marks). Without `--create` the attach refuses a name zmx no longer has, so a session gone
since the listing fails visibly instead of becoming a fresh shell wearing its name. With `--create` zmx
creates the session when absent, running `--command` through `/bin/sh -c` instead of a login shell; an
existing session ignores the command, and `--command` without `--create` is refused. `--window` takes a
local open window id, unique prefix, or `active`; omitted, the frontmost window. An invalid or closed
destination fails without creating anything. When ssh exits, the pane holds on Ghostty's press-any-key
prompt under one line naming the session, the host and the exit status. Closing the session here ends only
this side's connection; the far-side process keeps running. It is not restored after a relaunch.

`agtermctl remote kill HOST NAME --force` — runs `zmx kill NAME` on the host, ending the process and every
client attached to it, a pane here included. `--force` is required as confirmation.

The zmx session name is the address everywhere: plain text with no whitespace or `/`, not starting with
`-`. zmx is found through the host's `PATH` plus `~/.local/bin`, `~/bin`, `/usr/local/bin` and
`/opt/homebrew/bin`, since sshd's non-interactive shell reads no profile.
```

`plugins/agterm/skills/agterm/examples.md`: after the paragraph ending `and it does not come back after a relaunch.` (end of the another-Mac section) and before `## Read or change the local restore policy`, add:

```
## Attach a zmx session on a server

Any host with zmx installed and key-based ssh will do; agterm is not needed there. List its sessions, open
one, or create one that starts an agent in the project directory:

```bash
agtermctl remote list devbox
agtermctl remote attach devbox api
agtermctl remote attach devbox api --create --command 'cd ~/projects/api && claude'
agtermctl remote kill devbox api --force
```

Pipe the listing through the picker to let the user choose:

```bash
s=$(agtermctl remote list devbox --json |
  jq '[.result.remoteSessions[] | {id: .name, label: .name,
        subtitle: ((.cwd // "") + "  " + ([.labels | to_entries[] | "\(.key)=\(.value)"] | join(" ")))}]' |
  agtermctl pick --prompt "Attach which session?" | jq -r '.id // empty')
[ -n "$s" ] && agtermctl remote attach devbox "$s"
```

Closing the row ends only this side's connection. To start something on the host without attaching, run
`ssh devbox 'zmx run api -d make test'` yourself; agterm adds nothing there.
```

`site/commands.html`: in the results sentence near line 302 that lists `remote` (another Mac's attachable sessions, for `zmx tree`), add after it `<span style="font-family: &quot;JetBrains Mono&quot;, monospace; color: #cbc6bc">remoteSessions</span> (a zmx host's sessions, for <span style="font-family: &quot;JetBrains Mono&quot;, monospace; color: #cbc6bc">remote list</span>),` in the same sentence style. Then before `<section id="version" style="scroll-margin-top: 88px; padding-top: 56px">` insert a section copying the zmx section's opening markup (its `<section id="zmx" …>` tag and `<h2>` block) with id `remote` and heading `remote`, containing three cards in the exact card markup of the `agtermctl zmx tree [HOST]` card:

- card 1: command `agtermctl remote list HOST`, wire `remote.list`, lead paragraph `List the zmx sessions on a host that runs zmx and nothing of agterm's: any Linux or Mac box with zmx 0.7 or later, reachable over key-based ssh. It runs the host's own <code>zmx list</code> and prints one row per session. Sessions an agterm on that host created for its own live panes are omitted; those are <code>zmx tree</code>.` (write `<code>` as the page's monospace `<span>`), secondary paragraphs: the BatchMode sentence from the zmx tree card with `agtermctl` replaced by `zmx`, and `A host without zmx answers that zmx is not installed. zmx is found through the far side's PATH plus ~/.local/bin, ~/bin, /usr/local/bin and /opt/homebrew/bin.`, and a Result paragraph: `remoteSessions — name, clients (attached clients), cwd (when zmx reports one), created (unix seconds), labels (every other key=value on the row).`
- card 2: `agtermctl remote attach HOST NAME [--create] [--command CMD] [--window W]`, wire `remote.attach`, lead: `Open NAME here as a session marked remote, in the destination window's current workspace, selected. The pane runs ssh -tt HOST zmx attach NAME, so the far side's screen and scrollback replay into it and programs inside it reach agterm the way local ones do. Returns the new session's id; read remoteHost on its tree node.` secondary: `Without --create the attach refuses a name zmx no longer has, so a session gone since the listing fails visibly instead of becoming a fresh shell wearing its name. With --create zmx creates the session when absent and runs --command through /bin/sh -c instead of a login shell; an existing session ignores the command, and --command without --create is refused.` and `--window takes a local open window id, unique prefix, or active; omitted, the frontmost window. When ssh exits, the pane holds on Ghostty's press-any-key prompt under one line naming the session, the host and the exit status. Closing it here ends only this side's connection, and it is not restored after a relaunch.`
- card 3: `agtermctl remote kill HOST NAME --force`, wire `remote.kill`, lead: `Run zmx kill NAME on the host, ending the process and every client attached to it, a pane here included. --force is required as confirmation.` secondary: `A host without zmx answers that zmx is not installed; any other failure reports what ssh or zmx said.`

If the page has a section index (search for `href="#zmx"`), add a matching `href="#remote"` entry right after it.

`site/docs.html`: after the paragraph ending `which you can hide with the Remote host toggle in Settings ▸ Interface.</p>`, add a paragraph in the same `<p style="font-size: 16px; …">` style:

`A plain server works too. Any Linux or Mac host with zmx installed and key-based ssh can hold sessions that survive a closed laptop, and nothing of agterm's is needed there: <span mono>agtermctl remote list HOST</span> reads the host's own <span mono>zmx list</span>, <span mono>agtermctl remote attach HOST NAME</span> opens one of them as a session marked remote, and <span mono>--create --command 'cd ~/api && claude'</span> starts an agent in a new one. Because zmx is a transparent proxy with replay, the screen and scrollback come back on attach and programs inside the session notify and report their directory the way local ones do. Closing the row leaves the process running on the host; <span mono>agtermctl remote kill HOST NAME --force</span> ends it.`

(write each `<span mono>` as `<span style="font-family: &quot;JetBrains Mono&quot;, monospace; color: #cbc6bc">…</span>`), followed by a code block in the page's existing dark code-block markup:

```
agtermctl remote list devbox
agtermctl remote attach devbox api
agtermctl remote attach devbox api --create --command 'cd ~/projects/api && claude'
```

`README.md`: after the `**Agent status.**` bullet add:

```
- **Remote sessions.** Attach to a zmx session on any host over ssh (`agtermctl remote attach host name`), or to a session of another agterm (`agtermctl zmx attach`); the row is marked remote, its screen replays on attach, and closing it leaves the process running on the host.
```

- [ ] **Step 4: Run the test to verify it passes, and check the count rule**

Run: `cd agtermCore && swift test --filter SkillInstallTests`
Expected: PASS.

Run: `grep -rn "remote" site/llms.txt | head` and leave `site/llms.txt` alone unless it already lists `zmx tree` (it does not today). Run `grep -rnE "[0-9]+ commands" README.md site/*.html plugins/agterm/skills/agterm/*.md .claude/rules/control-api.md` and confirm no total appears.

- [ ] **Step 5: Commit**

```bash
git add .claude/rules/control-api.md plugins/agterm/skills/agterm/SKILL.md plugins/agterm/skills/agterm/reference.md plugins/agterm/skills/agterm/examples.md site/commands.html site/docs.html README.md agtermCore/Tests/agtermCoreTests/SkillInstallTests.swift
git commit -m "docs(remote): zmx hosts in the control rule, skill, site, and README

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Gates, once

**Files:** none new.

- [ ] **Step 1: Host-free tests**

Run: `cd agtermCore && swift test 2>&1 | tail -5`
Expected: every suite passes, `0 failures`.

- [ ] **Step 2: Hosted tests**

Run: `make test-app 2>&1 | tail -15`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Lint**

Run: `make lint 2>&1 | tail -5`
Expected: `Done linting! Found 0 violations`. Fix any finding in place (line length 200, no narrating comments) and re-run only lint.

- [ ] **Step 4: Release build**

Run: `make build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit any gate fixes and report**

```bash
git status --short
git log --oneline origin/master..HEAD
```

Report the commit list, the gate outputs' last lines, and the manual gate that remains for the user: against a real host with zmx, `remote list`, `remote attach --create --command claude`, closing the tab, `remote kill --force`, and a notification from inside the session, all on an isolated Debug instance with `--socket`.
