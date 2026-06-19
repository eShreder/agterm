import XCTest

/// Drives the View > Hide/Show Status Bar menu item and verifies the choice both
/// persists to disk and is restored across a relaunch. The assertions go through
/// the persisted `statusBarHidden` flag (file-backed, like the sidebar tests) and
/// the menu item's flipped label, which is deterministic regardless of whether the
/// seeded session's cwd happens to be a git work tree.
@MainActor
final class StatusBarMenuUITests: XCTestCase {
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
    }

    override func tearDown() async throws {
        app?.terminate()
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
    }

    func testHideStatusBarTogglesAndPersists() throws {
        // seeded session exists -> the window (and its menu) are up.
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 20), "seeded session should exist")

        clickViewMenuItem("Hide Status Bar")
        XCTAssertTrue(pollStatusBarHidden(true, timeout: 5), "hiding the status bar should persist statusBarHidden=true")

        // the item flips to its inverse, and toggling back persists the inverse.
        clickViewMenuItem("Show Status Bar")
        XCTAssertTrue(pollStatusBarHidden(false, timeout: 5), "showing the status bar should persist statusBarHidden=false")
    }

    func testHiddenStatusBarRestoredOnRelaunch() throws {
        XCTAssertTrue(app.staticTexts["session-row"].waitForExistence(timeout: 20), "seeded session should exist")
        clickViewMenuItem("Hide Status Bar")
        XCTAssertTrue(pollStatusBarHidden(true, timeout: 5), "hiding the status bar should persist")

        app.terminate()
        app = XCUIApplication()
        app.launchEnvironment["AGT_STATE_DIR"] = stateDir.path
        app.launchArguments += XCUIApplication.sidebarIsolationArguments
        app.launch()

        // restored hidden -> the menu offers the inverse action.
        app.menuBars.menuBarItems["View"].click()
        XCTAssertTrue(app.menuItems["Show Status Bar"].waitForExistence(timeout: 5),
                      "after relaunch the menu should show 'Show Status Bar', proving the hidden state was restored")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    private func clickViewMenuItem(_ title: String) {
        app.menuBars.menuBarItems["View"].click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "View menu should offer '\(title)'")
        item.click()
    }

    /// Polls the hermetic snapshot file until `statusBarHidden` equals `expected`.
    private func pollStatusBarHidden(_ expected: Bool, timeout: TimeInterval) -> Bool {
        let file = stateDir.appendingPathComponent("workspaces.json")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: file),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["statusBarHidden"] as? Bool) == expected {
                return true
            }
            usleep(200_000)
        }
        return false
    }
}
