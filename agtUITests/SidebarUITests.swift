import XCTest

/// Real UI tests: launch the actual app and drive the sidebar through the
/// accessibility API. These exercise the SwiftUI wiring (rename focus, context
/// menus, move, close) the agtCore unit tests cannot reach.
///
/// Accessibility-tree facts these queries rely on (verified via app.debugDescription):
/// - session rows expose their name as a StaticText `value` (not `label`);
/// - workspace headers expose their name as a StaticText `label`;
/// - the inline rename field is a StaticText with identifier `edit-field` and is
///   keyboard-focused on appear, so typing goes straight to it.
final class SidebarUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // hermetic state: a fresh temp dir per test so the app seeds exactly one
        // "workspace 1" + one session, and we never touch the real workspaces.json.
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["AGT_STATE_DIR"] = stateDir.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    /// The (single, seeded) session row, matched by its stable accessibility
    /// identifier — the displayed name lands in the StaticText `value`, which the
    /// usual identifier/label lookups don't match.
    private func sessionRow() -> XCUIElement { app.staticTexts["session-row"] }

    /// Polls an element's `value` until it equals `expected`.
    private func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == expected { return true }
            usleep(150_000)
        }
        return false
    }

    /// Enter rename via the row's context menu, type a new name, commit with Return.
    private func rename(_ row: XCUIElement, to newName: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 20), "row to rename should exist")
        row.rightClick()
        let rename = app.menuItems["Rename"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "Rename menu item should appear")
        rename.click()
        // the field appears keyboard-focused (the rename fix); type into it. it
        // surfaces as a TextField (session rows) or StaticText (workspace headers),
        // so match by identifier across element types.
        let field = app.descendants(matching: .any).matching(identifier: "edit-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "rename did not enter edit mode (field never appeared)")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("\(newName)\r")
    }

    // The reported bug: renaming a session did nothing.
    func testRenameSession() throws {
        let row = sessionRow()
        rename(row, to: "renamed-session")
        XCTAssertTrue(waitForValue(row, "renamed-session", timeout: 5),
                      "session row should show the new name after rename")
    }

    func testRenameWorkspace() throws {
        let ws = app.staticTexts["workspace 1"]
        rename(ws, to: "work")
        XCTAssertTrue(app.staticTexts["work"].waitForExistence(timeout: 5),
                      "workspace header should show the new name after rename")
    }

    func testCloseSession() throws {
        let row = sessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.rightClick()
        let close = app.menuItems["Close Session"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5),
                      "session row should disappear after close")
    }

    func testMoveSession() throws {
        let row = sessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        app.buttons["New Workspace"].click()
        XCTAssertTrue(app.staticTexts["workspace 2"].waitForExistence(timeout: 5), "second workspace should appear")
        row.rightClick()
        let moveTo = app.menuItems["Move to"]
        XCTAssertTrue(moveTo.waitForExistence(timeout: 5), "Move to submenu should appear")
        moveTo.hover()
        let target = app.menuItems["workspace 2"]
        XCTAssertTrue(target.waitForExistence(timeout: 5), "target workspace in submenu should appear")
        target.click()
        XCTAssertTrue(pollSessionCount(workspace: "workspace 2", expected: 1, timeout: 5),
                      "session should be under workspace 2 in persisted state after move")
    }

    func testDragSessionToWorkspace() throws {
        let row = sessionRow()
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        app.buttons["New Workspace"].click()
        let ws2 = app.staticTexts["workspace 2"]
        XCTAssertTrue(ws2.waitForExistence(timeout: 5), "second workspace should appear")
        row.press(forDuration: 1.0, thenDragTo: ws2)
        XCTAssertTrue(pollSessionCount(workspace: "workspace 2", expected: 1, timeout: 5),
                      "session should move to workspace 2 via drag-and-drop")
    }

    /// Polls the hermetic snapshot file until the named workspace has `expected` sessions.
    private func pollSessionCount(workspace name: String, expected: Int, timeout: TimeInterval) -> Bool {
        let file = stateDir.appendingPathComponent("workspaces.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let workspaces = obj["workspaces"] as? [[String: Any]],
               let ws = workspaces.first(where: { ($0["name"] as? String) == name }),
               ((ws["sessions"] as? [[String: Any]])?.count ?? 0) == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }
}
