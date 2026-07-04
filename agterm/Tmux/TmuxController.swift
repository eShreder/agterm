import AppKit
import Foundation
import os
import agtermCore

/// Bridges a tmux `-CC` control-mode gateway to a live agterm workspace — WITHOUT any libghostty
/// patch. Each tmux window is mirrored as an ORDINARY agterm command-session whose child process is
/// `agtermctl tmux-pipe`, connected to a per-window `RelaySocket`. tmux `%output` is written down the
/// socket (`RelaySocket.send(.data)`) → the child's stdout → the stock exec surface renders it; the
/// surface's keystrokes/resizes come back up the socket as `.data`/`.resize` frames → `send-keys` /
/// `refresh-client -C`. Because every surface is a normal local-PTY exec surface, notifications, ⌘F
/// search, and `view.session` linkage all work with no engine fork.
///
/// `@MainActor`: every store/session touch is main-actor work. The gateway's `Callbacks` and each
/// `RelaySocket.onFrame` fire OFF the main actor, so each hops via `DispatchQueue.main.async` before
/// touching anything here — mirroring `GhosttyCallbacks`. It NEVER uses `MainActor.assumeIsolated`.
@MainActor final class TmuxController {
    private static let log = Logger(subsystem: "com.umputun.agterm", category: "tmux")
    /// The bundled `agtermctl` used as the per-window relay child (`tmux-pipe`).
    private static let agtermctlPath = Bundle.main.url(forAuxiliaryExecutable: "agtermctl")?.path
    /// A real cwd for the relay command-sessions (the exec surface chdirs into it).
    private static let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

    private let store: AppStore
    private var gateway: TmuxGateway?
    private var model = TmuxSessionModel()
    private var workspaceID: UUID?
    private var windowToSession: [TmuxWindowID: UUID] = [:]        // tmux window -> agterm session
    private var windowToSocket: [TmuxWindowID: RelaySocket] = [:]  // tmux window -> its relay socket
    private var pendingLeadingPane: [TmuxWindowID: TmuxPaneID] = [:]
    private var bootstrapSessionID: UUID?
    private var bootstrapSocket: RelaySocket?
    private var blockLines: [Int: [String]] = [:]
    private var initializedWindows = false
    private var pendingCaptureWindows: [TmuxWindowID] = []
    /// True from the handshake `list-windows` send until its reply is processed. Any OTHER command sent
    /// in that gap (a debounced `refresh-client -C` from a fresh `%window-add`'s relay child, a held-input
    /// `send-keys` flush, a user ⌘T `new-window`) replies — tmux answers strictly in command order — AFTER
    /// the `list-windows` reply but BEFORE the `capture-pane`s enqueued while processing it. Without
    /// accounting, `pendingCaptureWindows` (a pure FIFO) would consume that reply as the first window's
    /// snapshot and every capture would paint into the WRONG window.
    private var awaitingWindowList = false
    /// How many such gap commands were sent; their replies are consumed (not painted) before the captures.
    private var preCaptureReplies = 0
    /// Windows whose initial `capture-pane` paint is still pending. Live `%output` for such a window is
    /// BUFFERED in `heldOutput` instead of hitting the surface, so the paint's screen-clear (`\e[2J`) can't
    /// wipe a prompt the shell printed during the capture round-trip: the snapshot predates that prompt,
    /// so once the clear lands the prompt is gone until a manual redraw (Ctrl-L) — the reported bug.
    private var windowsAwaitingCapture: Set<TmuxWindowID> = []
    private var heldOutput: [TmuxWindowID: [UInt8]] = [:]
    /// Cap on the per-window pre-capture hold, so a capture that never returns can't grow it unbounded.
    private static let maxHeldOutput = 4 * 1024 * 1024
    /// Keystrokes typed into a window whose leading pane is not known yet — a fresh `%window-add`'s pane
    /// id only lands with its first `%layout-change`, so input in that gap would otherwise be dropped
    /// (the input mirror of `heldOutput`). Flushed to `send-keys` when the pane arrives.
    private var heldInput: [TmuxWindowID: [UInt8]] = [:]
    private static let maxHeldInput = 64 * 1024
    /// Coalesces a resize DRAG into one `refresh-client -C`: a live drag fires many SIGWINCH → resize
    /// frames, and one `refresh-client` per frame storms tmux with redraws (a full-screen TUI like htop
    /// repaints on every one → visual chaos). Debounced so only the final size is sent, giving the app a
    /// single clean SIGWINCH → one full redraw.
    private var resizeWork: DispatchWorkItem?
    private var latestSize: (cols: Int, rows: Int)?
    /// Set by THIS client's `newWindow()` (⌘T) so the next `%window-add` echo selects its mirror
    /// session; every other `%window-add` (another attached client, a remote script) adds WITHOUT
    /// selecting — a background remote window creation must not steal the user's focus mid-typing.
    /// Cleared on consume, or by a timeout when the `new-window` never echoes (see `newWindow()`).
    private var pendingLocalWindowSelect = false
    private var localSelectGeneration = 0

    /// The connection's target host: the ssh host for `attach`, `"local"` for `attachLocal`.
    private(set) var host: String = ""
    /// The tmux session name; with `host` it forms the dedup identity for a repeat attach.
    private(set) var sessionName: String = ""

    /// The workspace this connection mirrors into, or nil before an attach / after teardown.
    var connectionWorkspaceID: UUID? { workspaceID }

    /// Fired ONCE when this connection tears down; the owner prunes the dead controller.
    var onClose: (() -> Void)?

    init(store: AppStore) { self.store = store }
    deinit { gateway?.stop() }

    /// True when this LIVE connection already mirrors `host`+`session` — the dedup key for a repeat attach.
    func mirrors(host: String, session: String) -> Bool {
        workspaceID != nil && self.host == host && self.sessionName == session
    }

    /// Bring this connection's workspace to front by selecting its lowest-numbered window's session
    /// (workspace focus derives from the selected session), or the bootstrap session while connecting.
    func focus() {
        let target = windowToSession
            .sorted { (Int($0.key.raw.dropFirst()) ?? 0) < (Int($1.key.raw.dropFirst()) ?? 0) }
            .first?.value ?? bootstrapSessionID
        if let target { store.selectSession(target) }
    }

    /// The display names of this connection's mirrored windows, for `tmux.list`.
    func windowSummaries() -> [String] {
        windowToSession.keys
            .sorted { (Int($0.raw.dropFirst()) ?? 0) < (Int($1.raw.dropFirst()) ?? 0) }
            .compactMap { window in
                guard let id = windowToSession[window] else { return nil }
                return store.session(withID: id)?.customName ?? "window"
            }
    }

    /// Hard-kill the tmux server-side session, then tear down locally. Distinct from `detach`.
    func kill() {
        guard gateway != nil else { teardownWorkspace(); return }
        sendCommand(.killSession)
        // Let tmux's resulting `%exit` (→ `onExit` → `teardownWorkspace`) drive teardown, NOT an immediate
        // one: `send(.killSession)` only ENQUEUES an async PTY write, while `teardownWorkspace` → `stop()`
        // → `PTYProcess.terminate()` SIGTERMs the transport synchronously — it would win the race and the
        // kill-session command would never reach the server, leaving the session alive (the exact opposite
        // of `kill`). Fall back to a forced teardown if no `%exit` arrives (dead connection);
        // `teardownWorkspace` is idempotent, so whichever fires first wins harmlessly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.teardownWorkspace() }
    }

    /// Spawn `ssh -tt <host> tmux -CC new -A -s <name>` and begin the bootstrap phase. Returns false (and
    /// tears the just-created workspace back down) when the ssh child fails to spawn.
    @discardableResult
    func attach(host: String, sessionName: String, workspaceName: String? = nil) -> Bool {
        if gateway != nil { teardownWorkspace() }
        self.host = host
        self.sessionName = sessionName
        workspaceID = store.addWorkspace(name: workspaceName ?? "tmux: \(host)/\(sessionName)", ephemeral: true).id
        // Single-quote the session name for the REMOTE shell — `ssh <host> <remote>` hands `remote` to
        // the remote login shell, so a raw name like `main; reboot` would run as a shell command. (The
        // local path in `attachLocal` is safe: it passes the name as a direct posix_spawn argv element.)
        let remote = "tmux -CC new -A -s \(Self.shquote(sessionName))"
        return startGateway(path: "/usr/bin/ssh", args: ["/usr/bin/ssh", "-tt", host, remote],
                            env: ProcessInfo.processInfo.environment)
    }

    /// Attach to a LOCAL tmux (no ssh): `tmux -CC new -A -s <name>` directly. Path from `AGTERM_TMUX_BIN`
    /// (else Homebrew's tmux); optional `AGTERM_TMUX_SOCKET` selects a named server via `-L`. Returns false
    /// (and tears the just-created workspace back down) when the tmux child fails to spawn (e.g. no tmux
    /// binary at the resolved path).
    @discardableResult
    func attachLocal(sessionName: String) -> Bool {
        if gateway != nil { teardownWorkspace() }
        self.host = "local"
        self.sessionName = sessionName
        workspaceID = store.addWorkspace(name: "tmux: local/\(sessionName)", ephemeral: true).id
        let env = ProcessInfo.processInfo.environment
        let tmuxPath = env["AGTERM_TMUX_BIN"] ?? "/opt/homebrew/bin/tmux"
        let socketArgs = env["AGTERM_TMUX_SOCKET"].map { ["-L", $0] } ?? []
        let args = [tmuxPath] + socketArgs + ["-CC", "new", "-A", "-s", sessionName]
        return startGateway(path: tmuxPath, args: args, env: env)
    }

    /// Build the gateway and spawn its child. Returns false on spawn/open failure — the child never
    /// launched, so no bootstrap/handshake/exit callback will EVER fire to drive teardown, which would
    /// otherwise strand the ephemeral workspace created by `attach`/`attachLocal` (an empty "tmux: …"
    /// workspace plus a phantom `tmux.list` entry). On failure we tear that workspace down here and report
    /// it up so `tmux.attach` doesn't falsely return ok.
    @discardableResult
    private func startGateway(path: String, args: [String], env: [String: String]) -> Bool {
        let gw = TmuxGateway(callbacks: .init(
            onBootstrapBytes: { data in DispatchQueue.main.async { [weak self] in self?.applyBootstrap(data) } },
            onHandshake: { DispatchQueue.main.async { [weak self] in self?.onHandshake() } },
            onEvent: { event in DispatchQueue.main.async { [weak self] in self?.apply(event) } },
            onExit: { _ in DispatchQueue.main.async { [weak self] in self?.onExit() } }))
        self.gateway = gw
        do {
            try gw.start(path: path, args: args, env: env)
        } catch {
            Self.log.error("tmux gateway spawn failed: \(String(describing: error), privacy: .public)")
            teardownWorkspace()
            return false
        }
        return true
    }

    /// Send `detach-client` and tear down the local workspace (tmux survives server-side).
    func detach() {
        sendCommand(.detachClient)
        teardownWorkspace()
    }

    // MARK: - Event → model → effects

    /// Encode + send a control command.
    private func sendCommand(_ command: TmuxCommand) {
        gateway?.send(command)
        // A command sent while the window-list reply is outstanding replies ahead of the capture-panes;
        // count it so its (empty) reply block isn't consumed as the first window's capture snapshot.
        if gateway != nil, awaitingWindowList { preCaptureReplies += 1 }
    }

    private func apply(_ event: TmuxEvent) {
        switch event {
        case .blockBegin(let num): blockLines[num] = []
        case .blockLine(let num, let text): blockLines[num, default: []].append(text)
        case .blockEnd(let num, let isError):
            let lines = blockLines.removeValue(forKey: num) ?? []
            if !pendingCaptureWindows.isEmpty, preCaptureReplies > 0 {
                // The reply of a command sent in the list-windows gap (see `awaitingWindowList`): it
                // precedes the capture replies in tmux's FIFO, so consume it here — painting it would
                // shift EVERY capture into the wrong window.
                preCaptureReplies -= 1
            } else if let window = pendingCaptureWindows.first {
                pendingCaptureWindows.removeFirst()
                // An %error reply (e.g. the pane died between list-windows and its capture-pane) must
                // not be painted as pane content: consume the block with EMPTY lines, which still
                // releases the hold + flushes any held live output, but paints no snapshot.
                paintCapturedContent(window: window, lines: isError ? [] : lines)
            } else if !isError, !initializedWindows {
                let windows = TmuxWindowList.parse(lines)
                if !windows.isEmpty {
                    initializedWindows = true
                    awaitingWindowList = false   // gap over: commands from here reply AFTER the captures
                    for w in windows { applyInitialWindow(w) }
                    for w in windows where pendingLeadingPane[w.id] != nil {
                        sendCommand(.capturePane(pendingLeadingPane[w.id]!))
                        pendingCaptureWindows.append(w.id)
                    }
                    // The mirror sessions were added WITHOUT selecting (a `%window-add` echo must not
                    // steal focus); select the lowest-numbered window once, deliberately, so the attach
                    // lands the user on the connection's first window.
                    focus()
                }
            }
        default: break
        }
        if case let .layoutChange(window, layout) = event {
            if let leading = TmuxLayout.panes(in: layout).panes.first {
                pendingLeadingPane[window] = leading
                // Flush keystrokes typed before the pane id was known (a fresh window's first layout).
                if let held = heldInput.removeValue(forKey: window), !held.isEmpty {
                    sendCommand(.sendKeys(pane: leading, bytes: held))
                }
            }
        }
        for effect in model.handle(event) { apply(effect) }
    }

    private func applyInitialWindow(_ w: (id: TmuxWindowID, name: String, layout: String)) {
        if let leading = TmuxLayout.panes(in: w.layout).panes.first {
            pendingLeadingPane[w.id] = leading
            windowsAwaitingCapture.insert(w.id)   // hold live %output until the capture paints (no clobber)
        }
        for effect in model.handle(.windowAdd(w.id)) { apply(effect) }
        for effect in model.handle(.layoutChange(window: w.id, layout: w.layout)) { apply(effect) }
        if !w.name.isEmpty { for effect in model.handle(.windowRenamed(w.id, name: w.name)) { apply(effect) } }
    }

    /// Seed a window's surface with its captured current content (via the relay socket). tmux sends no
    /// `%output` for a pre-existing window on attach, so without this a QUIESCENT window stays blank until
    /// a live write. But if the pane produced live output DURING the capture round-trip (a fresh shell
    /// printing its "Last login…" banner + prompt), that live stream is authoritative and complete from the
    /// start: painting the older snapshot would either CLOBBER the prompt (the `\e[2J` clear lands after the
    /// live bytes on the surface) or duplicate it. So when live output was held, deliver THAT and skip the
    /// snapshot; only a truly quiescent pane (nothing held) gets the captured-screen paint. Clear+home
    /// first; drop trailing blank rows so the cursor lands near the prompt.
    private func paintCapturedContent(window: TmuxWindowID, lines: [String]) {
        let wasAwaiting = windowsAwaitingCapture.remove(window) != nil
        let held = heldOutput.removeValue(forKey: window) ?? []
        guard let socket = windowToSocket[window] else { return }
        if !held.isEmpty {
            socket.send(.data(held)); return
        }
        // A capture that outlived its hold (released by the cap in `holdOutput`) must NOT paint: live
        // output has been routing straight to the surface since the release, and the stale snapshot's
        // clear+home would wipe it — the exact clobber this machinery exists to prevent.
        guard wasAwaiting else { return }
        var rows = lines
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
        guard !rows.isEmpty else { return }
        socket.send(.data(Array(("\u{1b}[2J\u{1b}[H" + rows.joined(separator: "\r\n")).utf8)))
    }

    /// Buffer pre-capture live output for a window awaiting its `capture-pane` paint. If the hold exceeds
    /// the cap (a capture that never returns), release it — flush what's buffered and route live from then
    /// on — so a stuck capture can't grow the buffer without bound.
    private func holdOutput(_ window: TmuxWindowID, _ bytes: [UInt8]) {
        var buf = heldOutput[window] ?? []
        buf.append(contentsOf: bytes)
        if buf.count > Self.maxHeldOutput {
            windowsAwaitingCapture.remove(window)
            heldOutput[window] = nil
            windowToSocket[window]?.send(.data(buf))
            return
        }
        heldOutput[window] = buf
    }

    private func apply(_ effect: TmuxModelEffect) {
        guard let workspaceID else { return }
        switch effect {
        case .createSession(let window, let name):
            makeRelaySession(window: window, name: name, workspaceID: workspaceID)
        case .renameSession(let window, let name):
            if let id = windowToSession[window] { store.renameSession(id, to: name) }
        case .removeSession(let window):
            windowToSocket.removeValue(forKey: window)?.close()
            if let id = windowToSession.removeValue(forKey: window) { store.closeSession(id) }
            pendingLeadingPane[window] = nil
            windowsAwaitingCapture.remove(window)
            heldOutput[window] = nil
            heldInput[window] = nil
        case .routeOutput(let window, let bytes):
            if windowsAwaitingCapture.contains(window) {
                holdOutput(window, bytes)   // buffer until the capture paints, so the clear can't clobber it
            } else {
                windowToSocket[window]?.send(.data(bytes))
            }
        case .tearDown:
            teardownWorkspace()
        case .diagnostic(let message):
            Self.log.info("\(message, privacy: .public)")
        }
    }

    /// Create the per-window relay socket + an ordinary command-session running `agtermctl tmux-pipe`.
    /// The eager deck builds a STOCK exec surface for it (no headless engine). Returns silently if the
    /// bundled `agtermctl` can't be resolved (the feature disables gracefully).
    private func makeRelaySession(window: TmuxWindowID, name: String, workspaceID: UUID) {
        guard let socket = RelaySocket(onFrame: { [weak self] frame in
            DispatchQueue.main.async { self?.handleFrame(frame, from: window) }
        }) else { return }
        guard let command = pipeCommand(socketPath: socket.path) else {
            Self.log.error("no bundled agtermctl — cannot start tmux-pipe relay child")
            socket.close(); return
        }
        Self.log.debug("window \(window.raw, privacy: .public) relay: \(command, privacy: .public)")
        // The relay child (`tmux-pipe`) ignores cwd, but a stock exec surface DOES chdir into
        // working_directory, so pass a real dir (home) rather than "" which ghostty can't chdir to.
        // Select ONLY a window this client just asked for (`newWindow()`); a remote `%window-add`
        // (and each window of the initial attach batch, selected once via `focus()` instead) adds
        // without moving the user's selection or clearing their focused-workspace filter.
        let select = pendingLocalWindowSelect
        pendingLocalWindowSelect = false
        guard let session = store.addSession(toWorkspace: workspaceID, cwd: Self.homeDir,
                                             command: command, name: name.isEmpty ? "tmux" : name,
                                             allowEphemeral: true, select: select) else {
            socket.close(); return
        }
        windowToSession[window] = session.id
        windowToSocket[window] = socket
        session.tmuxBinding = TmuxBinding(connectionID: workspaceID, window: window)
    }

    /// Route an inbound relay frame (off a window's surface) to tmux: keystrokes → `send-keys` on the
    /// window's leading pane; a resize → `refresh-client -C`.
    private func handleFrame(_ frame: RelayFrame, from window: TmuxWindowID) {
        switch frame {
        case .data(let bytes):
            guard let pane = pendingLeadingPane[window] else {
                // A fresh window's pane id only lands with its first `%layout-change`; hold input typed
                // in that gap and flush it then (the `apply` layoutChange arm), instead of dropping it.
                var held = heldInput[window] ?? []
                guard held.count + bytes.count <= Self.maxHeldInput else {
                    Self.log.error("input dropped: no leading pane for window \(window.raw, privacy: .public)")
                    return
                }
                held.append(contentsOf: bytes)
                heldInput[window] = held
                return
            }
            sendCommand(.sendKeys(pane: pane, bytes: bytes))
        case .resize(let cols, let rows):
            guard cols > 0, rows > 0 else { return }   // a 0-size winsize would break tmux's client size
            scheduleResize(cols: Int(cols), rows: Int(rows))
        }
    }

    /// Debounce the client resize: keep the LATEST size and send one `refresh-client -C` after the drag
    /// goes quiet (~90 ms), so a drag storm collapses to a single tmux redraw.
    private func scheduleResize(cols: Int, rows: Int) {
        latestSize = (cols, rows)
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let size = self.latestSize else { return }
            self.sendCommand(.resizeClient(cols: size.cols, rows: size.rows))
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    // MARK: - Local → tmux (reverse rename/kill/new)

    private func window(forSession sessionID: UUID) -> TmuxWindowID? {
        windowToSession.first(where: { $0.value == sessionID })?.key
    }

    func owns(session sessionID: UUID) -> Bool { window(forSession: sessionID) != nil }

    /// True when this connection mirrors into `store` — the store of the window that hosts it. Used to
    /// tear the connection down when that window (and its store) closes, so a window close can't orphan
    /// the gateway + relay sockets. (`AppStore` is a reference type; identity is the binding.)
    func hosts(in store: AppStore) -> Bool { self.store === store }

    /// Resolve a `tmux:` control-target payload — `"%N"` (a window's LEADING pane) or `"@N"` (a window)
    /// — to the mirrored session. Non-leading panes of a split window are not mirrored (the relay shows
    /// the leading pane only), so they do not resolve.
    func session(forTmuxTarget raw: String) -> UUID? {
        if raw.hasPrefix("@") { return windowToSession[TmuxWindowID(raw)] }
        if raw.hasPrefix("%"),
           let window = pendingLeadingPane.first(where: { $0.value.raw == raw })?.key {
            return windowToSession[window]
        }
        return nil
    }

    /// The tmux identity of a mirrored session — its window id and leading pane id (pane nil until the
    /// first layout arrives). The read side surfaced on the `tree` nodes.
    func tmuxIdentity(forSession id: UUID) -> (window: String, pane: String?)? {
        guard let window = window(forSession: id) else { return nil }
        return (window.raw, pendingLeadingPane[window]?.raw)
    }

    @discardableResult func renameWindow(session sessionID: UUID, to name: String) -> Bool {
        guard let w = window(forSession: sessionID) else { return false }
        sendCommand(.renameWindow(w, name: name)); return true
    }

    @discardableResult func killWindow(session sessionID: UUID) -> Bool {
        guard let w = window(forSession: sessionID) else { return false }
        sendCommand(.killWindow(w)); return true
    }

    @discardableResult func newWindow() -> Bool {
        guard gateway != nil else { return false }
        pendingLocalWindowSelect = true   // the echo of OUR new-window should focus, like GUI ⌘T
        // The latch is consumed by the next `%window-add`. If the command FAILS (an `%error` reply,
        // e.g. tmux's window limit) that echo never comes and the stale latch would hand the select to
        // the next REMOTE window add — the exact focus steal it exists to prevent. A timeout clears it;
        // the generation guard keeps a rapid second ⌘T's fresh latch alive past the first timer.
        localSelectGeneration += 1
        let generation = localSelectGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.localSelectGeneration == generation else { return }
            self.pendingLocalWindowSelect = false
        }
        sendCommand(.newWindow(name: nil))
        return true
    }

    /// The relay child of a mirrored window exited on its OWN (crash, external kill) — the stock exec
    /// `onExit` is closing the local session, so drop the window's mirror state (mapping, socket, holds)
    /// to keep `tmux.list` and `tmux:` addressing truthful instead of pointing at a dead session. The
    /// remote tmux window is left alive (a child crash is not a user kill; reattach re-mirrors it); its
    /// later `%output`/`%window-close` no-op against the cleared maps. No-op for a controller-driven
    /// close, whose `.removeSession` effect already cleared the mapping before the child died.
    func relayChildExited(session sessionID: UUID) {
        guard let window = window(forSession: sessionID) else { return }
        Self.log.error("tmux relay child exited for window \(window.raw, privacy: .public); window unmirrored")
        windowToSocket.removeValue(forKey: window)?.close()
        windowToSession.removeValue(forKey: window)
        pendingLeadingPane[window] = nil
        windowsAwaitingCapture.remove(window)
        heldOutput[window] = nil
        heldInput[window] = nil
        // The session usually dies with the child (closePrimaryPane), but a LOCAL split promotes and
        // survives — clear the now-stale binding so the survivor stops self-identifying as tmux-backed
        // (a stale binding makes newSession() skip the local-add path yet find no owning controller,
        // dead-ending ⌘T in the mirror workspace).
        store.session(withID: sessionID)?.tmuxBinding = nil
    }

    // MARK: - Bootstrap (ssh auth)

    /// On the FIRST bootstrap bytes, create one visible "connecting…" command-session whose relay
    /// forwards keystrokes raw via `writeBootstrap`; render each ssh-prompt chunk into it.
    private func applyBootstrap(_ data: Data) {
        guard let workspaceID else { return }
        if bootstrapSessionID == nil {
            guard let socket = RelaySocket(onFrame: { [weak self] frame in
                DispatchQueue.main.async {
                    if case .data(let bytes) = frame { self?.gateway?.writeBootstrap(Data(bytes)) }
                }
            }) else { return }
            guard let command = pipeCommand(socketPath: socket.path),
                  let session = store.addSession(toWorkspace: workspaceID, cwd: Self.homeDir,
                                                 command: command, name: "connecting…",
                                                 allowEphemeral: true) else {
                socket.close(); return
            }
            bootstrapSessionID = session.id
            bootstrapSocket = socket
            store.selectSession(session.id)
        }
        bootstrapSocket?.send(.data(Array(data)))
    }

    /// tmux entered control mode: close the bootstrap session and request the current window list.
    private func onHandshake() {
        closeBootstrap()
        sendCommand(.listWindows)
        awaitingWindowList = true   // set AFTER the send so list-windows itself is not counted as a gap command
    }

    private func closeBootstrap() {
        bootstrapSocket?.close(); bootstrapSocket = nil
        if let id = bootstrapSessionID { store.closeSession(id); bootstrapSessionID = nil }
    }

    // MARK: - Teardown

    private func onExit() { teardownWorkspace() }

    private func teardownWorkspace() {
        guard gateway != nil || workspaceID != nil || bootstrapSessionID != nil else { return }
        resizeWork?.cancel(); resizeWork = nil; latestSize = nil
        closeBootstrap()
        for socket in windowToSocket.values { socket.close() }
        windowToSocket.removeAll()
        if let workspaceID { store.removeWorkspace(workspaceID) }
        workspaceID = nil
        windowToSession.removeAll()
        pendingLeadingPane.removeAll()
        windowsAwaitingCapture.removeAll()
        heldOutput.removeAll()
        heldInput.removeAll()
        blockLines.removeAll()
        pendingCaptureWindows.removeAll()
        awaitingWindowList = false
        preCaptureReplies = 0
        pendingLocalWindowSelect = false
        initializedWindows = false
        model = TmuxSessionModel()
        gateway?.stop()
        gateway = nil
        onClose?()
    }

    // MARK: - Helpers

    private func pipeCommand(socketPath: String) -> String? {
        guard let ctl = Self.agtermctlPath else { return nil }
        return "\(Self.shquote(ctl)) tmux-pipe --socket \(Self.shquote(socketPath))"
    }

    /// POSIX single-quote for the shell command line ghostty runs for the session.
    private static func shquote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
