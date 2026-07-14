import agtermCore
import AppKit

/// The tmux (-CC control mode, local relay — no libghostty patch) half of `AppActions`: the
/// per-connection `TmuxController` lifecycle (attach/detach/kill/list), the backend-aware `session.*`
/// routers, and `tmux:` target/identity resolution. Split out of `AppActions.swift` to keep that file
/// under the swiftlint size limit; the `tmuxControllers` store stays on the main class body (a stored
/// property can't live in an extension).
extension AppActions {
    /// The `TmuxController` that owns `sessionID` (has a live tmux window mapped to it), or nil.
    func tmuxControllerOwning(_ sessionID: UUID) -> TmuxController? {
        tmuxControllers.first { $0.owns(session: sessionID) }
    }

    /// Resolve a `tmux:%pane`/`tmux:@window` control target (payload after the prefix) to its mirrored
    /// session, searching every live connection. nil when no live window/pane matches.
    func tmuxSession(forTarget raw: String) -> UUID? {
        for controller in tmuxControllers {
            if let id = controller.session(forTmuxTarget: raw) { return id }
        }
        return nil
    }

    /// A mirror session's relay child (`agtermctl tmux-pipe`) exited on its OWN (crash, external kill)
    /// — NOT a controller-driven teardown. Unmirror the window in its owning controller so the maps,
    /// `tmux.list`, and `tmux:` addressing stay truthful (the remote window survives server-side).
    /// Clean no-op for plain local sessions and for controller-initiated closes (mapping already gone).
    /// Wired from the stock exec surface's `onExit` in `agtermApp.makeSurface`.
    func tmuxRelayChildExited(_ sessionID: UUID) {
        tmuxControllerOwning(sessionID)?.relayChildExited(session: sessionID)
    }

    /// The tmux window/pane identity of a mirrored session, or nil for a plain local session. The read
    /// side of the `tmux:` addressing, surfaced on `tree` nodes.
    func tmuxIdentity(forSession id: UUID) -> (window: String, pane: String?)? {
        for controller in tmuxControllers {
            if let identity = controller.tmuxIdentity(forSession: id) { return identity }
        }
        return nil
    }

    private func makeTmuxController(for store: AppStore) -> TmuxController {
        let controller = TmuxController(store: store)
        controller.onClose = { [weak self] in
            self?.tmuxControllers.removeAll { $0.connectionWorkspaceID == nil }
        }
        return controller
    }

    /// Attach to a remote tmux session over ssh, mirroring each window into a fresh "tmux: host/session"
    /// workspace. A repeat attach to an already-mirrored host+session focuses that connection instead of
    /// duplicating it. Returns the discriminated outcome (see `TmuxAttachOutcome`); `.attached` carries
    /// the connection id for the control arm to echo.
    @discardableResult
    func attachTmux(host: String, sessionName: String, workspaceName: String? = nil) -> TmuxAttachOutcome {
        guard let store else { return .noWindow }
        // Reject a host ssh would parse as an OPTION rather than a destination (e.g.
        // `-oProxyCommand=…` → LOCAL command execution). ssh has no reliable `--` end-of-options for the
        // destination across versions, so screen it here — the single funnel for both the control channel
        // (`tmux.attach`) and the GUI prompt.
        guard !host.isEmpty, !host.hasPrefix("-") else { return .invalidHost }
        if let existing = tmuxControllers.first(where: { $0.mirrors(host: host, session: sessionName) }),
           let existingID = existing.connectionWorkspaceID {   // `mirrors` implies a live workspace
            existing.focus()
            return .attached(existingID)
        }
        let controller = makeTmuxController(for: store)
        // Only track the controller if its child actually spawned — a spawn failure tears its own
        // ephemeral workspace back down (and `attach` returns false), so appending it would leave a dead,
        // workspace-less controller in the array.
        guard controller.attach(host: host, sessionName: sessionName, workspaceName: workspaceName),
              let connectionID = controller.connectionWorkspaceID else {
            return .spawnFailed
        }
        tmuxControllers.append(controller)
        return .attached(connectionID)
    }

    /// Prompt for an ssh host + tmux session name, then `attachTmux`. GUI entry for File ▸ Attach tmux
    /// Session…; the control channel's `tmux.attach` covers the same action non-interactively.
    func attachTmuxPrompt() {
        let alert = NSAlert()
        alert.messageText = "Attach tmux Session"
        alert.informativeText = "ssh host, and the tmux session name (default: main)."
        alert.addButton(withTitle: "Attach"); alert.addButton(withTitle: "Cancel")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        let hostField = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        hostField.placeholderString = "user@host"
        let sessionField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        sessionField.placeholderString = "session (default: main)"
        container.addSubview(hostField); container.addSubview(sessionField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = hostField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        let session = sessionField.stringValue.trimmingCharacters(in: .whitespaces)
        // Surface every non-attached outcome — the control arm reports these discriminated errors, and
        // the GUI caller of the same seam must not swallow them (a "-"-prefixed host or a spawn failure
        // silently closing the modal reads as success).
        switch attachTmux(host: host, sessionName: session.isEmpty ? "main" : session) {
        case .attached:
            break
        case .invalidHost:
            showTmuxAttachError("Enter a plain ssh destination like user@host — not empty and not starting with \"-\".")
        case .noWindow:
            showTmuxAttachError("No open window to attach into.")
        case .spawnFailed:
            showTmuxAttachError("Failed to launch ssh — the connection was not started.")
        }
    }

    private func showTmuxAttachError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "tmux Attach Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Attach to a LOCAL tmux session (no ssh) — the dev end-to-end gate path. No-op when no window open.
    func attachLocal(sessionName: String) {
        guard let store else { return }
        if let existing = tmuxControllers.first(where: { $0.mirrors(host: "local", session: sessionName) }) {
            existing.focus()
            return
        }
        let controller = makeTmuxController(for: store)
        // As in `attachTmux`: track the controller only if its child spawned; a spawn failure self-tears
        // the ephemeral workspace and returns false.
        guard controller.attachLocal(sessionName: sessionName) else { return }
        tmuxControllers.append(controller)
    }

    /// Detach every live tmux connection hosted in a CLOSING window's `store`, so a window close can't
    /// orphan the connection. The `TmuxController` is app-global (`tmuxControllers`) and retains its
    /// store + gateway strongly, so once `WindowLibrary.closeWindow` drops the library's ref the store,
    /// the ssh/tmux client, and the per-window relay sockets would all leak (with a phantom `tmux.list`
    /// entry) — nothing observes the NSWindow close otherwise. Detach (not kill) leaves the session
    /// server-side for a later reattach, matching the model. `detach()` prunes the controller via
    /// `onClose`; iterating `tmuxControllers` (an Array value) is unaffected by that mutation.
    func detachTmux(forClosingWindowStore store: AppStore) {
        for controller in tmuxControllers where controller.hosts(in: store) {
            controller.detach()
        }
    }

    /// Detach the live tmux connection whose ephemeral mirror IS `workspaceID`, so DELETING that
    /// workspace can't orphan the connection the way a raw `removeWorkspace` would. The tmux mirror is an
    /// ordinary (ephemeral) workspace with the standard "Delete Workspace" affordance; deleting it via
    /// `AppStore.removeWorkspace` tears down the local sessions but leaves the `TmuxController`'s gateway
    /// (the ssh/tmux `-CC` child) running and leaks the per-window relay sockets + a phantom `tmux.list`
    /// entry — the workspace-delete analog of the window-close orphan (`detachTmux(forClosingWindowStore:)`).
    /// Detach — NOT kill — so tmux survives server-side for a reattach, matching that guard; `detach()`
    /// removes the workspace via its own teardown. Returns whether a controller matched (and thus already
    /// handled the removal), so the caller skips its own `removeWorkspace`.
    @discardableResult
    func detachTmux(forConnectionWorkspace workspaceID: UUID) -> Bool {
        guard let controller = tmuxControllers.first(where: { $0.connectionWorkspaceID == workspaceID }) else {
            return false
        }
        controller.detach()
        return true
    }

    /// Detach the tmux connection matching `connectionID` (nil = the single live one). Sends
    /// `detach-client`; tmux survives server-side. See `resolveTmux` for the outcome.
    func detachTmux(connectionID: String?) -> TmuxSelection {
        resolveTmux(connectionID) { $0.detach() }
    }

    /// Hard-kill the tmux connection matching `connectionID` (nil = the single live one). Sends
    /// `kill-session`. See `resolveTmux` for the outcome.
    func killTmux(connectionID: String?) -> TmuxSelection {
        resolveTmux(connectionID) { $0.kill() }
    }

    /// The live tmux connections for `tmux.list`: workspace uuid, target host, tmux session name, and
    /// window names — already in wire shape (the `.tmuxList` arm returns it verbatim).
    func listTmux() -> [ControlTmuxNode] {
        tmuxControllers.compactMap { controller in
            guard let wid = controller.connectionWorkspaceID else { return nil }
            return ControlTmuxNode(id: wid.uuidString, host: controller.host,
                                   session: controller.sessionName,
                                   windows: controller.windowSummaries())
        }
    }

    /// Resolve a detach/kill selector to a target and apply `action`. An explicit `id` matches a live
    /// connection's workspace uuid like every other control target: case-insensitive, full uuid or a
    /// unique prefix (≥2 prefix hits = `.ambiguous`). A nil id targets the connection ONLY when exactly
    /// one is live — with more than one it is `.ambiguous` (the caller must name which, so a bare
    /// `tmux detach`/`kill` can't silently hit the wrong session). A torn-down controller never matches.
    /// The matched uuid is captured BEFORE `action` runs (a detach/kill tears the controller down,
    /// nil-ing `connectionWorkspaceID`) and echoed in `.ok`.
    private func resolveTmux(_ id: String?, _ action: (TmuxController) -> Void) -> TmuxSelection {
        let live = tmuxControllers.compactMap { controller in
            controller.connectionWorkspaceID.map { (controller: controller, workspaceID: $0) }
        }
        if let id {
            let needle = id.uppercased()   // `uuidString` is uppercase; ids arrive in either case
            guard !needle.isEmpty else { return .notFound }
            let matches = live.filter { $0.workspaceID.uuidString.hasPrefix(needle) }
            guard matches.count == 1 else { return matches.isEmpty ? .notFound : .ambiguous }
            action(matches[0].controller)
            return .ok(matches[0].workspaceID)
        }
        switch live.count {
        case 0: return .notFound
        case 1: action(live[0].controller); return .ok(live[0].workspaceID)
        default: return .ambiguous
        }
    }
}
