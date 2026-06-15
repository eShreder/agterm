import agtCore
import AppKit
import SwiftUI

@main
struct agtApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @State private var store = agtApp.restoredStore()

    var body: some Scene {
        Window("agt", id: "main") {
            ContentView(store: store) { Self.makeSurface(for: $0, store: store) }
                .frame(minWidth: 640, minHeight: 400)
                .task { appDelegate.store = store }
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
    }

    /// Loads the persisted snapshot and restores it; if there's nothing saved,
    /// seeds a single default workspace with one session at $HOME.
    @MainActor
    private static func restoredStore() -> AppStore {
        // UI tests pass AGT_STATE_DIR to isolate persistence in a temp dir so a
        // run never touches the user's real workspaces.json.
        let persistence = ProcessInfo.processInfo.environment["AGT_STATE_DIR"]
            .map { PersistenceStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) }
            ?? PersistenceStore()
        let store = AppStore(persistence: persistence)
        let snapshot = persistence.load()
        guard !snapshot.workspaces.isEmpty else {
            let workspace = store.addWorkspace(name: "workspace 1")
            store.addSession(toWorkspace: workspace.id, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
            return store
        }
        store.restore(from: snapshot)
        return store
    }

    /// Surface factory: creates a libghostty-backed view for the session, spawning
    /// a login shell in the session's initial working directory. On shell exit the
    /// view calls back to close the owning session in the store.
    @MainActor
    private static func makeSurface(for session: Session, store: AppStore) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: session.initialCwd)
        view.session = session
        let sessionID = session.id
        view.onExit = { store.closeSession(sessionID) }
        return view
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The shared app state, handed over once the scene appears so the delegate can
    /// persist it on terminate.
    var store: AppStore?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Boot libghostty: init, config, app_new, 120fps tick.
        _ = GhosttyApp.shared
    }

    func applicationWillTerminate(_: Notification) {
        store?.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
