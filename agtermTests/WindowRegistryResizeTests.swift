import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class WindowRegistryResizeTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var window: NSWindow!
    private var windowID: UUID!

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-resize-\(UUID().uuidString)")
        library = WindowLibrary(directory: stateDir)
        windowID = try XCTUnwrap(library.activeWindowID)
        server = ControlServer(library: library, actions: AppActions(library: library),
            settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
            identity: AppIdentity(version: "test", commit: "test"), socketPath: stateDir.appendingPathComponent("control.sock").path)
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        window = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20, width: 400, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 160, height: 120)
        WindowRegistry.shared.register(windowID, window: window)
    }

    override func tearDown() async throws {
        if let windowID { WindowRegistry.shared.unregister(windowID) }
        window?.orderOut(nil)
        window = nil
        server = nil
        library = nil
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        try await super.tearDown()
    }

    func testResizeClampsToTheMinimumAndDisplayWithAFixedTopEdge() throws {
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main ?? NSScreen.screens.first)
        let top = window.frame.maxY
        _ = WindowRegistry.shared.resize(windowID, width: 1, height: 1)
        XCTAssertEqual(window.frame.size, window.minSize)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.01)
        _ = WindowRegistry.shared.resize(windowID, width: 100_000, height: 100_000)
        XCTAssertEqual(window.frame.size, screen.visibleFrame.size)
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.01)
    }

    func testResizeReplyEchoesTheAppliedSize() async throws {
        for requested in [1, 100_000] {
            let dispatched = await ControlDispatcher(actions: server).dispatch(ControlRequest(
                cmd: .windowResize, target: windowID.uuidString, args: ControlArgs(width: requested, height: requested)))
            let response = try XCTUnwrap(dispatched)
            XCTAssertTrue(response.ok)
            let result = try XCTUnwrap(response.result)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            let frame = try XCTUnwrap(WindowRegistry.shared.geometry(for: windowID))
            XCTAssertEqual(json["width"] as? Int, Int(window.frame.width.rounded()))
            XCTAssertEqual(json["height"] as? Int, Int(window.frame.height.rounded()))
            XCTAssertEqual(json["width"] as? Int, frame.width)
            XCTAssertEqual(json["height"] as? Int, frame.height)
            XCTAssertEqual(result.id, windowID.uuidString)
        }
    }

    func testResizeRefusesAnUnregisteredWindowWithoutChangingAnother() {
        let original = window.frame
        WindowRegistry.shared.unregister(windowID)
        let response = server.windowResize(windowID.uuidString, width: 500, height: 400)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(window.frame, original)
    }

}
