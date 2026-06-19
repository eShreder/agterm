import XCTest

/// Drives the menu bar to verify the app's actions are reachable as standard menu items: a
/// store action (File ▸ New Session adds a session) and a ghostty-forwarded action (View ▸
/// Increase Font Size zooms the focused terminal, which also confirms the keybind-action string).
/// Both assert through observable side effects — a new sidebar row, and the persisted font size.
@MainActor
final class MenuUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["AGT_STATE_DIR"] = stateDir.path
        app.launchForUITest()
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    func testNewSessionMenuAddsSession() throws {
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")
        let before = app.staticTexts.matching(identifier: "session-row").count

        app.menuBars.menuBarItems["File"].click()
        let item = app.menuItems["New Session"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "File menu should offer New Session")
        item.click()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, app.staticTexts.matching(identifier: "session-row").count <= before {
            usleep(150_000)
        }
        XCTAssertEqual(app.staticTexts.matching(identifier: "session-row").count, before + 1,
                       "New Session should add a sidebar row")
    }

    func testIncreaseFontSizeMenuPersists() throws {
        let row = app.staticTexts["session-row"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded session should exist")
        row.click()
        usleep(800_000)

        let baseline = try XCTUnwrap(pollFontSize(timeout: 8), "the terminal should report a font size on launch")
        for _ in 0..<3 {
            app.menuBars.menuBarItems["View"].click()
            let item = app.menuItems["Increase Font Size"]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "View menu should offer Increase Font Size")
            item.click()
            usleep(250_000)
        }
        let increased = try XCTUnwrap(pollFontSize(where: { $0 > baseline }, timeout: 8),
                                      "Increase Font Size should grow the persisted size")
        XCTAssertGreaterThan(increased, baseline)
    }

    private func pollFontSize(where predicate: (Double) -> Bool = { _ in true }, timeout: TimeInterval) -> Double? {
        let file = stateDir.windowSnapshotFile()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let size = currentFontSize(file), predicate(size) { return size }
            usleep(200_000)
        }
        return nil
    }

    private func currentFontSize(_ file: URL) -> Double? {
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let workspaces = obj["workspaces"] as? [[String: Any]],
              let sessions = workspaces.first?["sessions"] as? [[String: Any]],
              let size = sessions.first?["fontSize"] as? Double
        else { return nil }
        return size
    }
}
