import XCTest

/// Drives the command palettes (actions + sessions) and the menu-triggered inline rename. The
/// result list is SwiftUI, so these assert through observable side effects in the persisted
/// snapshot: running an action changes the workspace/session tree, choosing a session changes the
/// persisted selection, and a rename changes the persisted name. Also covers ↑/↓ navigation (the
/// part most likely to fight the text field) over the now-alphabetical list.
@MainActor
final class PaletteUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-uitest-\(UUID().uuidString)", isDirectory: true)
        app = XCUIApplication()
        app.launchEnvironment["AGT_STATE_DIR"] = stateDir.path
        app.launchArguments += XCUIApplication.sidebarIsolationArguments
        app.launch()
        XCTAssertTrue(app.staticTexts["session-row"].firstMatch.waitForExistence(timeout: 20), "seeded session should exist")
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    func testActionPaletteFiltersAndRunsTopMatch() throws {
        let before = sessionCount()
        openPalette("Command Palette")
        typeIntoPalette("New Session")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.sessionCount() == before + 1 }, "running New Session should add a session")
    }

    func testActionPaletteArrowNavigationRunsSecondItem() throws {
        // "new" matches [New Session, New Workspace], alphabetical; ↓ selects New Workspace.
        let beforeWs = workspaceCount(), beforeSessions = sessionCount()
        openPalette("Command Palette")
        typeIntoPalette("new")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.workspaceCount() == beforeWs + 1 }, "↓ then Enter should run the second match (New Workspace)")
        XCTAssertEqual(sessionCount(), beforeSessions, "New Session should not have run")
    }

    func testRenameSessionFromMenuStartsInlineEdit() throws {
        renameActiveSession(to: "renamed-via-menu")
        XCTAssertTrue(poll { self.firstSessionName() == "renamed-via-menu" }, "menu rename should persist the new name")
    }

    func testSessionPaletteSelectsSession() throws {
        // rename the seeded session so the palette can target it unambiguously.
        renameActiveSession(to: "zeta")
        XCTAssertTrue(poll { self.firstSessionName() == "zeta" })
        let first = try XCTUnwrap(firstSessionID())

        // add a second session; it becomes selected.
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["New Session"].click()
        XCTAssertTrue(poll { self.sessionCount() == 2 }, "a second session should be added")
        XCTAssertNotEqual(selectedID(), first, "the new session should be selected after add")

        openPalette("Go to Session")
        typeIntoPalette("zeta")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(poll { self.selectedID() == first }, "Go to Session → zeta should select the first session")
    }

    // MARK: - Helpers

    private func openPalette(_ menuTitle: String) {
        app.menuBars.menuBarItems["View"].click()
        let item = app.menuItems[menuTitle]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "View menu should offer \(menuTitle)")
        item.click()
    }

    private func typeIntoPalette(_ text: String) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "palette search field should appear")
        field.click()
        field.typeText(text)
    }

    /// Renames the active session via File ▸ Rename Session (the menu-triggered inline edit).
    private func renameActiveSession(to name: String) {
        app.menuBars.menuBarItems["File"].click()
        let item = app.menuItems["Rename Session"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "File menu should offer Rename Session")
        item.click()
        let field = app.descendants(matching: .any).matching(identifier: "edit-field").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Rename Session should start the inline edit")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("\(name)\r")
    }

    private func poll(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(150_000)
        }
        return false
    }

    private func snapshot() -> [String: Any]? {
        let file = stateDir.appendingPathComponent("workspaces.json")
        guard let data = try? Data(contentsOf: file),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func workspaces() -> [[String: Any]] { snapshot()?["workspaces"] as? [[String: Any]] ?? [] }
    private func workspaceCount() -> Int { workspaces().count }
    private func sessionCount() -> Int { workspaces().reduce(0) { $0 + (($1["sessions"] as? [[String: Any]])?.count ?? 0) } }
    private func selectedID() -> String? { snapshot()?["selectedSessionID"] as? String }
    private func firstSession() -> [String: Any]? { (workspaces().first?["sessions"] as? [[String: Any]])?.first }
    private func firstSessionID() -> String? { firstSession()?["id"] as? String }
    private func firstSessionName() -> String? { firstSession()?["customName"] as? String }
}
