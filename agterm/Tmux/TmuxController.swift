import AppKit
import Foundation
import agtermCore

/// Bridges a tmux `-CC` control-mode gateway to a live agterm workspace.
///
/// Owns a `TmuxGateway` (the ssh+tmux transport, agtermCore) and a `TmuxSessionModel`
/// (the window→session folding, agtermCore), and mirrors each tmux window as a
/// headless-backed agterm `Session`: a `GhosttySurfaceView` seeded into `Session.surface`
/// BEFORE the eager deck mounts its `TerminalView`, so the deck hosts the headless surface
/// instead of spawning a shell. `%output` bytes render via the surface's `writeOutput`; the
/// surface's keystrokes/resizes flow back out as `send-keys`/`refresh-client -C`.
///
/// `@MainActor`: every store/session/surface touch is main-actor work. The gateway's
/// `Callbacks` closures arrive OFF the main actor (on `PTYProcess`'s background queue), so each
/// hops via `DispatchQueue.main.async` before touching anything here — mirroring
/// `GhosttyCallbacks`. It NEVER uses `MainActor.assumeIsolated`.
@MainActor final class TmuxController {
    private let store: AppStore
    private var gateway: TmuxGateway?
    private var model = TmuxSessionModel()
    private var workspaceID: UUID?
    private var windowToSession: [TmuxWindowID: UUID] = [:]       // tmux window -> agterm session
    private var pendingLeadingPane: [TmuxWindowID: TmuxPaneID] = [:]
    private var bootstrapSessionID: UUID?
    private var blockLines: [Int: [String]] = [:]
    private var initializedWindows = false

    /// The connection's target host: the ssh host for `attach`, `"local"` for `attachLocal`. Set at the
    /// top of the attach path (before spawning). Exposed via `AppActions.listTmux` for the control channel.
    private(set) var host: String = ""

    /// The id of the workspace this connection mirrors into, or nil before an attach / after teardown.
    /// Exposes the private `workspaceID` so `AppActions` can address the connection by workspace uuid.
    var connectionWorkspaceID: UUID? { workspaceID }

    /// The display names of this connection's mirrored windows, for the control channel's `tmux.list`.
    /// A window with no manual/tmux name (`customName` nil) reports the `"window"` placeholder.
    func windowSummaries() -> [String] {
        // Sort NUMERICALLY by the tmux window id (the `@N` sigil), so `@10` follows `@2` rather than
        // sorting lexicographically before it. Output is stable/testable (dictionary order is otherwise
        // undefined). Each surviving window maps through its session's manual/tmux name (`customName`),
        // falling back to the `"window"` placeholder.
        windowToSession.keys
            .sorted { (Int($0.raw.dropFirst()) ?? 0) < (Int($1.raw.dropFirst()) ?? 0) }
            .compactMap { window in
            guard let sessionID = windowToSession[window] else { return nil }
            return store.session(withID: sessionID)?.customName ?? "window"
        }
    }

    /// Hard-kill the tmux SERVER-side session (`kill-session`, terminating every window), then tear down
    /// the local workspace/gateway. Distinct from `detach`, which leaves the tmux session running.
    func kill() {
        gateway?.send(.killSession)
        teardownWorkspace()
    }

    init(store: AppStore) { self.store = store }

    deinit { gateway?.stop() }

    /// Spawn `ssh -tt <host> tmux -CC new -A -s <name>` in a pty and begin the bootstrap phase.
    /// `-tt` forces a tty so tmux enters control mode; `new -A` attaches-or-creates the session.
    func attach(host: String, sessionName: String, workspaceName: String? = nil) {
        // Re-attach without an intervening detach: tear down the live gateway first so it's
        // `stop()`ped (a bare reassign would leak its pty fd / orphan the child) before the new
        // workspace is created.
        if gateway != nil { teardownWorkspace() }
        self.host = host
        workspaceID = store.addWorkspace(name: workspaceName ?? "tmux: \(host)").id
        let remote = "tmux -CC new -A -s \(sessionName)"
        startGateway(path: "/usr/bin/ssh", args: ["/usr/bin/ssh", "-tt", host, remote],
                     env: ProcessInfo.processInfo.environment)
    }

    /// Attach to a LOCAL tmux (no ssh): spawn `tmux -CC new -A -s <name>` directly. Reuses the SAME
    /// gateway/event/effect plumbing as `attach` via `startGateway`. There's no ssh auth, so the
    /// handshake arrives immediately and the bootstrap phase is effectively a no-op (still safe — the
    /// `applyBootstrap`/`onHandshake` path just never has interactive prompt bytes to show). The tmux
    /// path comes from `AGTERM_TMUX_BIN` (else Homebrew's `/opt/homebrew/bin/tmux`); an optional
    /// `AGTERM_TMUX_SOCKET` selects a named server via `-L <socket>` (so the Phase-3 gate can point at
    /// an isolated `tmux -L agtgate` without threading args through the binary path).
    func attachLocal(sessionName: String) {
        // Re-attach without an intervening detach: tear down the live gateway first so it's
        // `stop()`ped (a bare reassign would leak its pty fd / orphan the child) before the new
        // workspace is created.
        if gateway != nil { teardownWorkspace() }
        self.host = "local"
        workspaceID = store.addWorkspace(name: "tmux: local").id
        let env = ProcessInfo.processInfo.environment
        let tmuxPath = env["AGTERM_TMUX_BIN"] ?? "/opt/homebrew/bin/tmux"
        let socketArgs = env["AGTERM_TMUX_SOCKET"].map { ["-L", $0] } ?? []
        let args = [tmuxPath] + socketArgs + ["-CC", "new", "-A", "-s", sessionName]
        startGateway(path: tmuxPath, args: args, env: env)
    }

    /// Build the `TmuxGateway` with the shared callback set (each closure hops to the main actor
    /// before touching `self`) and start it on `path`/`args`/`env`. Used by both `attach` (ssh) and
    /// `attachLocal` (local tmux) so the two entry points can't drift in how they wire events.
    private func startGateway(path: String, args: [String], env: [String: String]) {
        let gw = TmuxGateway(callbacks: .init(
            onBootstrapBytes: { data in DispatchQueue.main.async { [weak self] in self?.applyBootstrap(data) } },
            onHandshake: { DispatchQueue.main.async { [weak self] in self?.onHandshake() } },
            onEvent: { event in DispatchQueue.main.async { [weak self] in self?.apply(event) } },
            onExit: { _ in DispatchQueue.main.async { [weak self] in self?.onExit() } }))
        self.gateway = gw
        try? gw.start(path: path, args: args, env: env)
    }

    /// Send `detach-client` and tear down the local workspace (also stops the gateway).
    func detach() {
        gateway?.send(.detachClient)
        teardownWorkspace()
    }

    // MARK: - Event → model → effects

    private func apply(_ event: TmuxEvent) {
        // Collect the `list-windows` reply block (requested on handshake). tmux sends no
        // `%window-add` for windows that already existed at attach, so on the FIRST completed block
        // we parse it and synthesize per-window events to create those sessions. These `.block*`
        // events fold to `[]` in the model, so the model.handle fold below stays harmless.
        switch event {
        case .blockBegin(let num): blockLines[num] = []
        case .blockLine(let num, let text): blockLines[num, default: []].append(text)
        case .blockEnd(let num, _):
            let lines = blockLines.removeValue(forKey: num) ?? []
            if !initializedWindows {
                let windows = TmuxWindowList.parse(lines)
                if !windows.isEmpty {
                    initializedWindows = true
                    for w in windows { applyInitialWindow(w) }
                }
            }
        default: break
        }
        // Record the window's leading pane BEFORE folding into the model, so `sendKeys` has a
        // target the instant a fresh surface is wired. The model tracks pane→window internally
        // but doesn't expose the leading pane.
        if case let .layoutChange(window, layout) = event {
            if let leading = TmuxLayout.panes(in: layout).panes.first { pendingLeadingPane[window] = leading }
        }
        for effect in model.handle(event) { apply(effect) }
    }

    /// Synthesize the `windowAdd`+`layoutChange`+`windowRenamed` events for a window that already
    /// existed at attach (from the `list-windows` reply), driving the SAME effect path as a live
    /// `%window-add` so the session is created with its leading pane bound and its name applied.
    private func applyInitialWindow(_ w: (id: TmuxWindowID, name: String, layout: String)) {
        if let leading = TmuxLayout.panes(in: w.layout).panes.first { pendingLeadingPane[w.id] = leading }
        for effect in model.handle(.windowAdd(w.id)) { apply(effect) }
        for effect in model.handle(.layoutChange(window: w.id, layout: w.layout)) { apply(effect) }
        if !w.name.isEmpty { for effect in model.handle(.windowRenamed(w.id, name: w.name)) { apply(effect) } }
    }

    private func apply(_ effect: TmuxModelEffect) {
        guard let workspaceID else { return }
        switch effect {
        case .createSession(let window, let name):
            guard let session = store.addSession(
                toWorkspace: workspaceID, cwd: "", name: name.isEmpty ? "tmux" : name)
            else { return }
            windowToSession[window] = session.id
            session.surface = makeHeadlessSurface(for: window)
        case .renameSession(let window, let name):
            if let id = windowToSession[window] { store.renameSession(id, to: name) }
        case .removeSession(let window):
            if let id = windowToSession.removeValue(forKey: window) { store.closeSession(id) }
            pendingLeadingPane[window] = nil
        case .routeOutput(let window, let bytes):
            if let id = windowToSession[window], let session = store.session(withID: id),
               let view = session.surface as? GhosttySurfaceView {
                view.writeOutput(Data(bytes))
            }
        case .tearDown:
            teardownWorkspace()
        case .diagnostic(let message):
            NSLog("tmux: \(message)")
        }
    }

    /// A headless `GhosttySurfaceView` wired to route this window's input/resize back to tmux.
    /// Seeding it into `Session.surface` before the deck mounts stops the shell factory.
    private func makeHeadlessSurface(for window: TmuxWindowID) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: "")   // headless ignores cwd
        view.makeHeadless(onInput: { [weak self] data in
            self?.sendKeys(window: window, bytes: Array(data))
        })
        view.headlessOnResize = { [weak self] cols, rows in
            self?.gateway?.send(.resizeClient(cols: Int(cols), rows: Int(rows)))
        }
        return view
    }

    private func sendKeys(window: TmuxWindowID, bytes: [UInt8]) {
        // Under no-splits the target is the window's leading pane, recorded from `.layoutChange`.
        guard let pane = pendingLeadingPane[window] else { return }
        gateway?.send(.sendKeys(pane: pane, bytes: bytes))
    }

    // MARK: - Bootstrap (ssh auth)

    /// On the FIRST bootstrap bytes, create one visible "connecting…" session whose headless
    /// surface forwards keystrokes raw via `writeBootstrap`; render each ssh-prompt chunk into it.
    private func applyBootstrap(_ data: Data) {
        guard let workspaceID else { return }
        if bootstrapSessionID == nil {
            guard let session = store.addSession(toWorkspace: workspaceID, cwd: "", name: "connecting…")
            else { return }
            bootstrapSessionID = session.id
            let view = GhosttySurfaceView(workingDirectory: "")   // headless ignores cwd
            view.makeHeadless(onInput: { [weak self] bytes in self?.gateway?.writeBootstrap(bytes) })
            session.surface = view
            store.selectSession(session.id)
        }
        if let id = bootstrapSessionID, let session = store.session(withID: id),
           let view = session.surface as? GhosttySurfaceView {
            view.writeOutput(data)
        }
    }

    /// tmux entered control mode: the auth phase is over, so close the bootstrap session.
    private func onHandshake() {
        if let id = bootstrapSessionID { store.closeSession(id); bootstrapSessionID = nil }
        // tmux sends no `%window-add` for windows that existed before we attached. Ask for the
        // current list; the reply block is parsed in `apply(_:)` and turned into per-window events.
        gateway?.send(.listWindows)
    }

    // MARK: - Teardown

    private func onExit() { teardownWorkspace() }

    /// Remove the local workspace and stop the gateway. Stopping is MANDATORY on every teardown
    /// path: `PTYProcess.deinit` does not reliably close its fd, so an explicit `stop()`
    /// (→ `pty.terminate()`) is required to avoid an fd leak / orphaned child.
    private func teardownWorkspace() {
        if let id = bootstrapSessionID { store.closeSession(id); bootstrapSessionID = nil }
        if let workspaceID { store.removeWorkspace(workspaceID) }
        workspaceID = nil
        windowToSession.removeAll()
        pendingLeadingPane.removeAll()
        blockLines.removeAll()
        initializedWindows = false
        gateway?.stop()
        gateway = nil
    }
}
