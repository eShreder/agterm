import XCTest

extension XCUIApplication {
    /// Launch arguments that make an isolated UI test deterministically start with the sidebar
    /// visible, regardless of the host's persisted NSSplitView collapse (which lives in the bundle's
    /// GLOBAL UserDefaults, not under `AGT_STATE_DIR`). Keep AppKit window restoration enabled so the
    /// main window is ordered forward the same way as a normal launch; the sentinel tells `ContentView`
    /// to apply a test-only AppKit split-view fixup after the window attaches. Production never sees
    /// the sentinel, so its remember-the-collapse behavior is untouched.
    static var sidebarIsolationArguments: [String] {
        ["AGT_UITEST_FORCE_SIDEBAR_VISIBLE"]
    }
}
