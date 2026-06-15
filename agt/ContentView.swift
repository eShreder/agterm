import agtCore
import SwiftUI

/// Top-level layout: the workspace/session sidebar on the left, the active
/// session's terminal surface on the right. The detail pane swaps surfaces via
/// `.id(session.id)` — each session gets its own `TerminalView` identity, so the
/// session-owned surfaces survive switching.
///
/// The sidebar is an AppKit `NSOutlineView` (`WorkspaceSidebar`) so cross-workspace
/// drag-and-drop works natively. The "New Workspace" toolbar button stays here on
/// the sidebar column.
struct ContentView: View {
    @Bindable var store: AppStore
    let makeSurface: (Session) -> GhosttySurfaceView

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .toolbar {
                    ToolbarItem {
                        Button {
                            store.addWorkspace(name: defaultWorkspaceName)
                        } label: {
                            Label("New Workspace", systemImage: "plus")
                        }
                        .accessibilityLabel("New Workspace")
                    }
                }
        } detail: {
            if let active = store.activeSession {
                TerminalView(session: active, makeSurface: makeSurface)
                    .id(active.id)
            } else {
                Text("No session selected")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var defaultWorkspaceName: String {
        "workspace \(store.workspaces.count + 1)"
    }
}
