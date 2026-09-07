import XCTest
@testable import agterm
import agtermCore

@MainActor
final class ControlServerSplitCwdTests: XCTestCase {
    func testTreeDispatcherReportsTheHiddenSplitDirectory() async throws {
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-split-cwd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let library = WindowLibrary(directory: stateDir)
        let windowID = try XCTUnwrap(library.activeWindowID)
        let server = ControlServer(library: library, actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "test", commit: "test"), socketPath: stateDir.appendingPathComponent("control.sock").path)
        let session = try XCTUnwrap(library.activeStore?.activeSession)
        session.hasSplit = true
        session.isSplit = false
        session.splitCwd = "/other"
        let dispatched = await ControlDispatcher(actions: server).dispatch(ControlRequest(
            cmd: .tree, args: ControlArgs(window: windowID.uuidString)))
        let response = try XCTUnwrap(dispatched)
        XCTAssertTrue(response.ok)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded.result?.tree?.workspaces.flatMap(\.sessions).first?.splitCwd, "/other")
    }
}
