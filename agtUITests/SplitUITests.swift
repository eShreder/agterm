import XCTest

/// End-to-end test for the one-level vertical split. The split panes are Metal
/// `GhosttySurfaceView`s with no readable accessibility text, so this uses the terminal
/// itself as the oracle: each pane's shell has a distinct `tty`, so typing `tty > file`
/// in the focused pane records which shell received the keystrokes. That verifies the
/// split opens a separate shell and that focus follows it on open and returns on close.
@MainActor
final class SplitUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var markerDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-uitest-\(UUID().uuidString)", isDirectory: true)
        markerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: markerDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["AGT_STATE_DIR"] = stateDir.path
        app.launchForUITest()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        if let markerDir { try? FileManager.default.removeItem(at: markerDir) }
    }

    func testSplitOpensSeparateShellAndFocusFollows() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        // ensure the primary terminal holds focus before typing.
        row.click()
        usleep(800_000)

        // 1. record the primary shell's tty.
        let primaryTTY = ttyAfterCommand(named: "primary")
        XCTAssertNotNil(primaryTTY, "primary shell should write its tty (terminal must be focused)")

        // 2. open the split — focus should move to the new right pane (a separate shell).
        let splitButton = app.buttons["split-toggle"]
        XCTAssertTrue(splitButton.waitForExistence(timeout: 5), "split toolbar button should exist")
        splitButton.click()
        usleep(800_000)
        let splitTTY = ttyAfterCommand(named: "split")
        XCTAssertNotNil(splitTTY, "split shell should write its tty")
        XCTAssertNotEqual(primaryTTY, splitTTY, "opening the split focuses a new, separate shell")

        // 3. close the split — focus should return to the primary shell.
        splitButton.click()
        usleep(800_000)
        let afterTTY = ttyAfterCommand(named: "after")
        XCTAssertEqual(afterTTY, primaryTTY, "closing the split returns focus to the primary shell")
    }

    /// Types `tty > <markerDir>/<name>` into the focused terminal and returns the tty the
    /// shell wrote (trimmed), or nil if nothing was written within the timeout.
    private func ttyAfterCommand(named name: String) -> String? {
        let file = markerDir.appendingPathComponent(name)
        app.typeText("tty > '\(file.path)'")
        app.typeKey(.return, modifierFlags: [])
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let contents = try? String(contentsOf: file, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            usleep(150_000)
        }
        return nil
    }
}
