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
