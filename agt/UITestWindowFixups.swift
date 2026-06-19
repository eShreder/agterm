import AppKit

/// Test-only AppKit fixups so isolated XCUITests get a usable window. They run ONLY when
/// `ContentView.forceSidebarVisibleForUITests` is true (`AGT_STATE_DIR` + the launch-arg sentinel),
/// so production never executes any of this — it keeps the plain unbound `NavigationSplitView` and
/// the normal `NSApp.activate()`.
///
/// Why it exists: the sidebar collapse is persisted in the bundle's GLOBAL `NSSplitView` autosave,
/// which leaks past `AGT_STATE_DIR`, so a test launch can inherit a collapsed sidebar. SwiftUI's
/// `columnVisibility` binding desyncs once AppKit window-state restoration mutates the split, so the
/// reliable fix is to un-collapse the underlying `NSSplitView` directly. Disabling restoration with
/// `-ApplePersistenceIgnoreState` would also fix the sidebar, but it stops the window being ordered
/// forward (it launches hidden under XCUITest) — so restoration stays on and only the split is fixed.
@MainActor
enum UITestWindowFixups {
    private static let sidebarSplitIdentifier = "main, SidebarNavigationSplitView"
    private static let idealSidebarWidth = CGFloat(220)

    /// Force the sidebar split open: clear the (global) autosave so the test never writes the user's
    /// production value, un-collapse the sidebar item, and set the divider to a sensible width.
    static func expandSidebar(in window: NSWindow) {
        guard ContentView.forceSidebarVisibleForUITests,
              let root = window.rootView,
              let splitView = sidebarSplitView(in: root),
              splitView.subviews.count > 1 else { return }

        // do not let the UI-test process write the user's production split autosave value.
        splitView.autosaveName = nil

        let sidebarIndex = 0
        let sidebarPane = splitView.subviews[sidebarIndex]
        if let controller = splitViewController(for: splitView),
           sidebarIndex < controller.splitViewItems.count {
            let item = controller.splitViewItems[sidebarIndex]
            item.isCollapsed = false
            item.canCollapse = false
        }

        sidebarPane.isHidden = false
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()

        let dividerIndex = 0
        let lower = splitView.minPossiblePositionOfDivider(at: dividerIndex)
        let upper = splitView.maxPossiblePositionOfDivider(at: dividerIndex)
        guard upper > lower else { return }
        let target = Swift.min(Swift.max(idealSidebarWidth, lower + 1), upper - 1)
        splitView.setPosition(target, ofDividerAt: dividerIndex)
        splitView.adjustSubviews()
    }

    /// The sidebar's `NSSplitView`: prefer the one enclosing the tagged sidebar scroll view, then fall
    /// back to matching the SwiftUI split identifier/autosave name (the scroll view may not be in the
    /// tree yet when the sidebar restored collapsed), then any vertical split with >1 subview.
    private static func sidebarSplitView(in root: NSView) -> NSSplitView? {
        if let scroll = root.firstDescendant(withIdentifier: "agt-sidebar-scroll"),
           let splitView = scroll.firstAncestor(ofType: NSSplitView.self) {
            return splitView
        }
        if let splitView = root.firstDescendant(ofType: NSSplitView.self, where: isSidebarSplitView) {
            return splitView
        }
        return root.firstDescendant(ofType: NSSplitView.self) { splitView in
            splitView.isVertical && splitView.subviews.count > 1
        }
    }

    private static func isSidebarSplitView(_ splitView: NSSplitView) -> Bool {
        if splitView.identifier?.rawValue == sidebarSplitIdentifier { return true }
        if let autosaveName = splitView.autosaveName, autosaveName == sidebarSplitIdentifier { return true }
        return false
    }

    private static func splitViewController(for splitView: NSSplitView) -> NSSplitViewController? {
        var responder = splitView.nextResponder
        while let current = responder {
            if let controller = current as? NSSplitViewController { return controller }
            responder = current.nextResponder
        }
        return nil
    }
}

extension NSWindow {
    /// The window's root theme frame (top of the content view's superview chain).
    var rootView: NSView? {
        guard let contentView else { return nil }
        var root = contentView
        while let parent = root.superview { root = parent }
        return root
    }
}

extension NSView {
    /// First ancestor of the given type, walking up the superview chain.
    func firstAncestor<T: NSView>(ofType _: T.Type) -> T? {
        var node = superview
        while let current = node {
            if let match = current as? T { return match }
            node = current.superview
        }
        return nil
    }

    /// First descendant of the given type satisfying `matches`, depth-first.
    func firstDescendant<T: NSView>(ofType _: T.Type, where matches: (T) -> Bool) -> T? {
        for subview in subviews {
            if let typed = subview as? T, matches(typed) { return typed }
            if let found: T = subview.firstDescendant(ofType: T.self, where: matches) { return found }
        }
        return nil
    }
}
