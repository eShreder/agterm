import agtCore
import AppKit
import SwiftUI

/// Top-level layout: the workspace/session sidebar on the left, the active
/// session's terminal surface on the right. The detail pane swaps surfaces via
/// `.id(session.id)` — each session gets its own `TerminalView` identity, so the
/// session-owned surfaces survive switching.
///
/// The sidebar is an AppKit `NSOutlineView` (`WorkspaceSidebar`) so cross-workspace
/// drag-and-drop works natively. The bottom bar holds two add affordances: a
/// workspace button and a session menu (New Session / Open Directory…).
struct ContentView: View {
    let library: WindowLibrary
    let makeSurface: (Session, AppStore) -> GhosttySurfaceView
    let makeSplitSurface: (Session, AppStore) -> GhosttySurfaceView
    let makeOverlaySurface: (Session, AppStore) -> GhosttySurfaceView
    /// The `AGT_*` environment a window's quick terminal exposes (ENABLED + WINDOW_ID + SOCKET),
    /// resolved per window id. Threaded down so `WindowContentView` can bind its quick terminal's
    /// `envProvider` with its own window id.
    let quickTerminalEnv: (WindowInfo.ID) -> [String: String]
    let actions: AppActions
    let palette: PaletteController
    let sessionSwitcher: SessionSwitcher

    /// The resolved per-window store (lazy-loaded / created on appear). `nil` until resolved, or for
    /// a stray restored id with no library entry.
    @State private var store: AppStore?
    /// The id this window settled on (created for a nil `windowID`), used for frontmost/close
    /// reporting and the frame autosave name.
    @State private var resolvedID: WindowInfo.ID?

    /// Set when this window is a SwiftUI-restored stray with no library id to claim. The stray branch
    /// then closes the NSWindow via AppKit — SwiftUI's `@Environment(\.dismiss)` is unreliable for
    /// restored WindowGroup windows (they linger on screen as empty windows).
    @State private var isStray = false

    /// True only when running an isolated UI test that requested a forced-visible sidebar
    /// (`AGT_STATE_DIR` set AND the `AGT_UITEST_FORCE_SIDEBAR_VISIBLE` launch arg present). The
    /// sidebar collapse lives in the bundle's global NSSplitView autosave, which leaks past
    /// `AGT_STATE_DIR`; this gate lets the tests pin it visible without changing production.
    static var forceSidebarVisibleForUITests: Bool {
        let process = ProcessInfo.processInfo
        // the sentinel rides launch ENVIRONMENT, not launch arguments: a process-launched SwiftUI
        // WindowGroup app fails to present its window under some launch-arg patterns on macOS 15+
        // (FB11763863). Env sidesteps that.
        return process.environment["AGT_STATE_DIR"] != nil
            && process.environment["AGT_UITEST_FORCE_SIDEBAR_VISIBLE"] != nil
    }

    var body: some View {
        Group {
            if let store, let resolvedID {
                WindowContentView(
                    windowID: resolvedID,
                    store: store,
                    library: library,
                    makeSurface: { makeSurface($0, store) },
                    makeSplitSurface: { makeSplitSurface($0, store) },
                    makeOverlaySurface: { makeOverlaySurface($0, store) },
                    quickTerminalEnv: quickTerminalEnv,
                    actions: actions,
                    palette: palette,
                    sessionSwitcher: sessionSwitcher
                )
            } else if isStray {
                // a SwiftUI-restored stray beyond the app's open set: close its NSWindow via AppKit.
                Color.clear.background(StrayWindowCloser())
            } else {
                // transient: resolveStore hasn't run yet (or is still resolving).
                Color.clear
            }
        }
        .onAppear(perform: resolveStore)
    }

    /// Resolves the window's store once on appear by claiming the next open window id from the
    /// library's queue (the scene is a plain `WindowGroup`, so a window has no presented id). The
    /// launch window claims the launch id, additional `openWindow()`-opened windows claim the rest in
    /// order. A window beyond the open set — a SwiftUI-restored extra (Task 0 dedup-by-id) — gets no
    /// id and dismisses itself, so stale restoration state can't pile up windows. Idempotent —
    /// re-running with an already-resolved store is a no-op.
    private func resolveStore() {
        guard store == nil, !isStray else { return }
        guard let id = claimWindowID(),
              let resolved = library.store(for: id) ?? library.loadStore(for: id) else {
            isStray = true
            return
        }
        store = resolved
        resolvedID = id
    }

    /// The window id this view adopts: normally the next id in the library's claim queue. If the
    /// queue is empty before the launch reopen-all has seeded it (the scene `.task` may not have run
    /// `consumeReopen()` when this `.onAppear` fires), adopt the launch id rather than dismissing the
    /// launch window — `adoptLaunchWindowID()` records it so the later `consumeReopen()` excludes it
    /// from the seeded queue (no second window claims it). Once the queue has been seeded
    /// (`hasReopened`), an empty queue genuinely means this is a SwiftUI-restored stray, so return nil
    /// and let the caller dismiss it.
    private func claimWindowID() -> WindowInfo.ID? {
        if let id = library.claimNextWindowID() { return id }
        return library.hasReopened ? nil : library.adoptLaunchWindowID()
    }
}

/// Closes a SwiftUI-restored stray `WindowGroup` window via AppKit. SwiftUI's `@Environment(\.dismiss)`
/// is unreliable for restored windows — they linger on screen as empty windows — so this reaches the
/// backing `NSWindow` and `close()`s it directly. It also clears `isRestorable` so SwiftUI stops
/// persisting + re-restoring this stray on the next launch.
private struct StrayWindowCloser: NSViewRepresentable {
    func makeNSView(context _: Context) -> ClosingView { ClosingView() }
    func updateNSView(_ view: ClosingView, context _: Context) { view.closeIfNeeded() }

    final class ClosingView: NSView {
        private weak var closingWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            closeIfNeeded()
        }

        func closeIfNeeded() {
            guard let window, closingWindow !== window else { return }
            closingWindow = window
            window.isRestorable = false
            window.restorationClass = nil
            window.disableSnapshotRestoration()
            window.invalidateRestorableState()
            // defer past the current presentation/attach pass so the close lands cleanly.
            DispatchQueue.main.async { [weak window] in
                window?.close()
                DispatchQueue.main.async { [weak window] in
                    window?.orderOut(nil)
                    window?.close()
                }
            }
        }
    }
}

/// The actual per-window UI: the workspace/session sidebar + the active session's terminal, plus
/// the quick-terminal / palette / switcher overlays. Holds the resolved non-optional `AppStore` so
/// the binding-based wiring is unchanged from the single-window version; `ContentView` resolves the
/// store and hands it in.
private struct WindowContentView: View {
    let windowID: WindowInfo.ID
    @Bindable var store: AppStore
    let library: WindowLibrary
    let makeSurface: (Session) -> GhosttySurfaceView
    let makeSplitSurface: (Session) -> GhosttySurfaceView
    let makeOverlaySurface: (Session) -> GhosttySurfaceView
    let quickTerminalEnv: (WindowInfo.ID) -> [String: String]
    let actions: AppActions
    let palette: PaletteController
    let sessionSwitcher: SessionSwitcher
    /// This window's own quick terminal, owned here (one per window). Registered in
    /// `QuickTerminalRegistry` on appear so the frontmost-window call sites can reach it, and its
    /// `cwdProvider` binds to this window's active session.
    @State private var quickTerminal = QuickTerminalController()
    /// The terminal background color, mirrored from the (non-observable) `GhosttyApp` into view
    /// state and used as the quick terminal's opaque backing, so a settings theme change (posting
    /// `.agtAppearanceChanged`) re-renders it live.
    @State private var terminalColor: Color = WindowContentView.resolvedTerminalColor()
    /// Mirror of `GhosttyApp.compactToolbar`: when true the cwd subtitle is dropped so the title bar
    /// collapses to a single line. Refreshed on `.agtAppearanceChanged`, like `terminalColor`.
    @State private var compactToolbar: Bool = WindowContentView.resolvedCompactToolbar()
    /// Sidebar column visibility — only consulted on the isolated-UI-test path (see `splitRoot`),
    /// where it is pinned to `.doubleColumn`. Production never binds it, so its persisted collapse is
    /// untouched.
    @State private var columnVisibility: NavigationSplitViewVisibility =
        ContentView.forceSidebarVisibleForUITests ? .doubleColumn : .automatic

    var body: some View {
        splitRoot
        // native two-line titlebar title (session name bold + working-directory subtitle),
        // driven through SwiftUI so it isn't clobbered by NavigationSplitView.
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .toolbar {
            // .sharedBackgroundVisibility(.hidden) drops the macOS 26 toolbar-item glass capsule
            // (synthesized around adjacent items) so the icons sit flush on the dark title bar.
            // Gated: the deployment target is macOS 14, where the API doesn't exist (older systems
            // keep the default chrome).
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .primaryAction) { splitButton }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { quickTerminalButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .primaryAction) { splitButton }
                ToolbarItem(placement: .primaryAction) { quickTerminalButton }
            }
        }
        // the quick terminal: an in-app overlay above the whole split view (sidebar + terminal),
        // so it covers everything but the title bar (the toolbar button stays reachable to toggle).
        .overlay { quickTerminalOverlay }
        // the command palettes (actions / sessions): a top-centered overlay above everything.
        .overlay { commandPaletteOverlay }
        // the Ctrl-Tab most-recently-used session switcher.
        .overlay { sessionSwitcherOverlay }
        // when the quick terminal hides, return focus to the active session's terminal.
        .onChange(of: quickTerminal.isVisible) { _, visible in
            if !visible { actions.focusActiveSession() }
        }
        // when a palette closes, return focus to the active session's terminal.
        .onChange(of: palette.mode == nil) { _, closed in
            if closed { actions.focusActiveSession() }
        }
        // a settings appearance change isn't observable through GhosttyApp, so re-render on the
        // notification to pick up the new terminal color in the quick terminal backing.
        .onReceive(NotificationCenter.default.publisher(for: .agtAppearanceChanged)) { _ in
            terminalColor = WindowContentView.resolvedTerminalColor()
            compactToolbar = WindowContentView.resolvedCompactToolbar()
        }
        // blend the title bar with the terminal; report frontmost/close to the library; surface the
        // window un-minimized on launch. the title token makes updateNSView re-run the blend on a
        // session switch.
        .background(WindowAccessor(titleToken: windowTitle, windowID: windowID, library: library, store: store))
        // own a per-window quick terminal: register it so the frontmost-window call sites resolve it,
        // and spawn its shell in THIS window's active session's directory.
        .onAppear {
            quickTerminal.cwdProvider = { [store] in
                store.activeSession?.effectiveCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            }
            // the quick terminal's shell sees this window's AGT_* env (scratch: ENABLED + WINDOW_ID + SOCKET).
            quickTerminal.envProvider = { [quickTerminalEnv, windowID] in quickTerminalEnv(windowID) }
            QuickTerminalRegistry.shared.register(windowID, controller: quickTerminal)
        }
        .onDisappear { QuickTerminalRegistry.shared.unregister(windowID) }
    }

    /// The split view. Production uses the plain unbound `NavigationSplitView` (so its sidebar
    /// collapse persists via AppKit's autosave, untouched). An isolated UI test instead binds
    /// `columnVisibility` and pins it `.doubleColumn`, so the test asks SwiftUI for the two-column
    /// layout before the AppKit split-view fixup below enforces the real divider state regardless of the
    /// host's persisted collapse (which leaks past `AGT_STATE_DIR` via the global autosave).
    @ViewBuilder private var splitRoot: some View {
        if ContentView.forceSidebarVisibleForUITests {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn
            } detail: {
                detailColumn
            }
            // `.doubleColumn` shows the sidebar + detail in a two-column split (`.all` is the
            // three-column value and doesn't reveal the sidebar here).
            .onAppear { columnVisibility = .doubleColumn }
            .onChange(of: columnVisibility) { _, visibility in
                if visibility != .doubleColumn { columnVisibility = .doubleColumn }
            }
        } else {
            NavigationSplitView {
                sidebarColumn
            } detail: {
                detailColumn
            }
        }
    }

    private var sidebarColumn: some View {
        WorkspaceSidebar(store: store, actions: actions)
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .safeAreaInset(edge: .bottom) { bottomBar }
    }

    @ViewBuilder private var detailColumn: some View {
        VStack(spacing: 0) {
            // a subtle hairline between the title bar and the terminal; lives in the
            // detail pane so it starts at the sidebar's right edge, not the full width.
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The active session's terminal, or a placeholder when nothing is selected. When the
    /// session is split, the primary and split surfaces sit side by side in an `HSplitView`
    /// (a draggable vertical divider). Hiding the split removes the second `TerminalView`;
    /// its surface survives (owned by the session), so the shell isn't destroyed.
    @ViewBuilder private var detailPane: some View {
        if let active = store.activeSession {
            ZStack {
                if active.isSplit {
                    HSplitView {
                        TerminalView(session: active, surfaceKeyPath: \.surface, makeSurface: makeSurface)
                            .overlay { paneDim(active.splitFocused) }
                            .id(active.id)
                        TerminalView(session: active, surfaceKeyPath: \.splitSurface, makeSurface: makeSplitSurface)
                            .overlay { paneDim(!active.splitFocused) }
                            .id("\(active.id.uuidString)-split")
                    }
                } else {
                    TerminalView(session: active, surfaceKeyPath: \.surface, makeSurface: makeSurface)
                        .id(active.id)
                }
                // an ephemeral overlay terminal on top, at full single-pane size, hiding the
                // single/split content underneath while its one program runs.
                if active.overlayActive {
                    TerminalView(session: active, surfaceKeyPath: \.overlaySurface, makeSurface: makeOverlaySurface)
                        .id("\(active.id.uuidString)-overlay")
                }
            }
        } else {
            Text("No session selected")
                .foregroundStyle(.secondary)
        }
    }

    /// A translucent dim over the inactive split pane so the active one stands out. Clicks
    /// pass through (`allowsHitTesting(false)`) so the dimmed pane can still be focused;
    /// `dimmed == false` renders nothing.
    @ViewBuilder private func paneDim(_ dimmed: Bool) -> some View {
        if dimmed {
            Color.black.opacity(0.12).allowsHitTesting(false)
        }
    }

    /// The terminal background color from the ghostty config (a dark fallback if libghostty hasn't
    /// reported one), used as the quick terminal's opaque backing. Read into the `terminalColor`
    /// view state so it re-renders when the theme changes.
    private static func resolvedTerminalColor() -> Color {
        Color(nsColor: GhosttyApp.shared.terminalBackgroundColor
            ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1))
    }

    /// The compact-toolbar flag from the (non-observable) `GhosttyApp`, mirrored into view state so a
    /// settings change (posting `.agtAppearanceChanged`) drops/restores the cwd subtitle live.
    private static func resolvedCompactToolbar() -> Bool {
        GhosttyApp.shared.compactToolbar
    }

    /// The titlebar title (first line): the active session's display name, suffixed with the window
    /// name as "session — window" when the window has a custom (user-set) name, so a renamed window
    /// is identifiable at a glance. Auto "window N" names are omitted. "agt" when nothing is selected.
    private var windowTitle: String {
        let session = store.activeSession?.displayName ?? "agt"
        guard let info = library.windows.first(where: { $0.id == windowID }), info.hasCustomName else {
            return session
        }
        return "\(session) — \(info.name)"
    }

    /// The titlebar subtitle (second line): the active session's working directory. Dropped in
    /// compact mode so the title bar is a single short row.
    private var windowSubtitle: String {
        compactToolbar ? "" : (store.activeSession?.effectiveCwd ?? "")
    }

    /// Toolbar button (right of the title bar) that toggles the active session's one-level
    /// vertical split: first press shows the second pane, the next hides it.
    private var splitButton: some View {
        let isSplit = store.activeSession?.isSplit ?? false
        return Button {
            actions.toggleSplit()
        } label: {
            // a Label (icon + title) so the toolbar's "Icon and Text" mode has text to show;
            // the title is hidden in the default icon-only mode.
            Label("Split", systemImage: "rectangle.split.2x1")
        }
        .help(isSplit ? "Hide split" : "Split right")
        .disabled(store.activeSession == nil)
        .accessibilityIdentifier("split-toggle")
    }

    /// Toolbar button (next to the split toggle) that toggles the quick terminal: a single
    /// scratch terminal overlaid at 90% of the window, on top of the sidebar and terminal.
    /// Click the button again or the surrounding margin to hide; the shell stays alive until quit.
    private var quickTerminalButton: some View {
        Button {
            quickTerminal.toggle()
        } label: {
            Label("Quick Terminal", systemImage: "terminal")
        }
        .help("Quick Terminal")
        .accessibilityIdentifier("quick-terminal-toggle")
    }

    /// The quick-terminal overlay: the scratch terminal centered at 90% of the window, framed by a
    /// hairline border and shadow so it reads as a distinct floating window over the (undimmed)
    /// content. libghostty renders only the terminal content, so the frame is drawn here. The margin
    /// is a transparent tap-catcher that dismisses on click — no darkening, because the overlay
    /// can't cover the AppKit title bar, so a dim would shade the body but not the chrome. Rendered
    /// only while visible; the surface it hosts is owned by the controller, so hiding keeps the
    /// shell alive.
    @ViewBuilder private var quickTerminalOverlay: some View {
        if quickTerminal.isVisible {
            GeometryReader { geo in
                ZStack {
                    // the transparent tap-catcher also carries the `quick-terminal` accessibility id:
                    // a SwiftUI view is exposed in the accessibility tree (the Metal-backed
                    // `QuickTerminalPane` is not), so this is the element control-API tests query for.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { quickTerminal.hide() }
                        .accessibilityElement()
                        .accessibilityIdentifier("quick-terminal")
                    QuickTerminalPane(controller: quickTerminal)
                        .frame(width: geo.size.width * 0.9, height: geo.size.height * 0.9)
                        // solid backing so the quick terminal stays opaque even when the main window
                        // is translucent (its ghostty surface draws transparent under background-opacity=0).
                        .background(terminalColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(radius: 24)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    /// True only for the frontmost window. The palette and session switcher are app-global single
    /// instances (they act on the frontmost store), so only the frontmost window mounts their
    /// overlays — otherwise every open window would render a duplicate overlay, contending for focus
    /// and showing the wrong window's candidates. Uses `activeWindowID` (frontmost-or-first-open, the
    /// same accessor the palette/actions resolve through), so exactly one window matches even before
    /// the first `didBecomeKey` sets `frontmostWindowID`. Reactive: `frontmostWindowID` is observed.
    private var isFrontmost: Bool { library.activeWindowID == windowID }

    /// The command-palette overlay, mounted only while a palette is open in the frontmost window. Its
    /// content (search field + result list) is rebuilt from `palette.mode`.
    @ViewBuilder private var commandPaletteOverlay: some View {
        if isFrontmost, palette.mode != nil {
            CommandPalette(controller: palette, actions: actions)
        }
    }

    /// The Ctrl-Tab session switcher overlay, mounted only while cycling in the frontmost window.
    @ViewBuilder private var sessionSwitcherOverlay: some View {
        if isFrontmost, sessionSwitcher.isActive {
            SessionSwitcherOverlay(switcher: sessionSwitcher, store: store)
        }
    }

    /// Two distinct add controls, source-list style: add a workspace, and a menu
    /// to add a session to the current workspace (default cwd) or a picked directory.
    private var bottomBar: some View {
        HStack(spacing: 2) {
            Button {
                actions.newWorkspace()
            } label: {
                Image(systemName: "rectangle.stack.badge.plus")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New Workspace")
            .accessibilityLabel("New Workspace")

            Menu {
                Button("New Session") { actions.newSession() }
                Button("Open Directory…") { actions.openDirectory() }
            } label: {
                Image(systemName: "plus.rectangle")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Session")
            .accessibilityLabel("Add session")
            .accessibilityIdentifier("add-session")

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        // no explicit background: the sidebar is transparent (the window's terminal color shows
        // through), so a `.bar` material here would paint a mismatched darker strip.
    }

}

/// Blends the window title bar with the terminal (the title text itself is set by
/// SwiftUI's `.navigationTitle`/`.navigationSubtitle`). The probe's `window` is nil at
/// make time, so the blend is applied from `viewDidMoveToWindow` (window attachment) and
/// re-applied on every `titleToken` change (session switch) and on the window key/
/// fullscreen transitions where AppKit rebuilds the titlebar subviews.
///
/// It also carries the per-window plumbing: it sets the frame autosave name, reports
/// frontmost (key/main) and close (`willClose`) to the `WindowLibrary`, and registers the
/// `NSWindow` in `WindowRegistry` for dedup/raise.
private struct WindowAccessor: NSViewRepresentable {
    /// Changes when the active session changes, so `updateNSView` re-runs the blend.
    let titleToken: String
    let windowID: WindowInfo.ID
    let library: WindowLibrary
    let store: AppStore

    func makeNSView(context _: Context) -> TitleProbeView {
        TitleProbeView(windowID: windowID, library: library, store: store)
    }

    func updateNSView(_ nsView: TitleProbeView, context _: Context) {
        _ = titleToken
        nsView.reapplyBlend()
    }

    final class TitleProbeView: NSView {
        private let windowID: WindowInfo.ID
        private let library: WindowLibrary
        private let store: AppStore

        /// Observer tokens for window key/fullscreen transitions, after which AppKit
        /// rebuilds the titlebar subviews and the blend must be re-applied.
        nonisolated(unsafe) private var titlebarObservers: [NSObjectProtocol] = []

        /// One-shot guard so the saved frame is applied exactly once per window attach.
        private var frameRestored = false

        /// The confirm-before-close delegate proxy, owned here (NSWindow.delegate is weak).
        private var closeProxy: WindowCloseDelegateProxy?

        init(windowID: WindowInfo.ID, library: WindowLibrary, store: AppStore) {
            self.windowID = windowID
            self.library = library
            self.store = store
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Re-apply the blend (called from `updateNSView` on a session switch).
        func reapplyBlend() {
            if let window { applyTitlebarBlend(window) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            titlebarObservers.forEach(NotificationCenter.default.removeObserver)
            titlebarObservers.removeAll()
            guard let window else { return }
            // the app owns its window set (WindowLibrary + windows.json reopen-all); SwiftUI's own
            // WindowGroup restoration only fights that by re-creating empty stray windows from the
            // remembered window count (shared by bundle id, not isolated). Opt every real window fully
            // out of AppKit/SwiftUI restoration so that remembered set never grows.
            window.isRestorable = false
            window.restorationClass = nil
            window.disableSnapshotRestoration()
            window.invalidateRestorableState()
            frameRestored = false
            // per-window geometry keyed by OUR window id. SwiftUI's WindowGroup autosaves frames under
            // its own index-based name ("terminal-AppWindow-N") and OVERRIDES any setFrameAutosaveName
            // we set — and that index doesn't track a window's identity across an in-session
            // close/reopen, so the reopened window lands on the wrong/default slot. Instead we persist
            // the frame ourselves on close (keyed by the stable window UUID, in UserDefaults) and
            // re-apply it here AFTER SwiftUI's initial .defaultSize pass — on window-key plus a short
            // delayed fallback — one-shot via `frameRestored`.
            let frameKeyToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                DispatchQueue.main.async {
                    guard let self, let window, self.window === window else { return }
                    self.restoreSavedFrame(window)
                }
            }
            titlebarObservers.append(frameKeyToken)
            // fallback on the next run-loop tick (not a fixed delay) so the saved frame snaps in as soon
            // as SwiftUI's initial sizing pass is done, minimizing the visible default-then-resize.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                self.restoreSavedFrame(window)
            }
            // register the NSWindow so the app can raise an already-open window for this id (dedup)
            // instead of spawning a second; install the confirm-before-close delegate proxy.
            WindowRegistry.shared.register(windowID, window: window)
            ensureCloseProxy(on: window)
            applyTitlebarBlend(window)
            // the private titlebar subviews may not exist yet / get rebuilt after layout — re-apply the
            // blend and re-assert the close proxy (SwiftUI may re-own the delegate after attach).
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.ensureCloseProxy(on: window)
                self.applyTitlebarBlend(window)
            }
            // AppKit rebuilds the titlebar subviews and re-renders the sidebar Liquid Glass on
            // key/main/fullscreen transitions (becomeKey fires right at launch), undoing the cleared
            // titlebar layer and the glass tint — re-apply on every transition, including resign so a
            // background window keeps the terminal tint instead of the lighter default glass. Only
            // becomeKey/becomeMain mean this window became frontmost; resign/fullscreen do not.
            let frontmostNames: Set<NSNotification.Name> = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification]
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                         NSWindow.didResignKeyNotification, NSWindow.didResignMainNotification,
                         NSWindow.didExitFullScreenNotification] {
                // the observer block is @Sendable, so it must not touch main-actor state
                // directly; hop through DispatchQueue.main like the re-applies above.
                let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [windowID] notification in
                    let becameFrontmost = frontmostNames.contains(notification.name)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let window = self.window else { return }
                        self.applyTitlebarBlend(window)
                        if becameFrontmost { self.reportFrontmost(windowID) }
                    }
                }
                titlebarObservers.append(token)
            }
            // report close: tear down this window's surfaces, then mark it closed in the library.
            // capture library/store/id directly (NOT through `self`) — the view is being deallocated
            // as the window closes, so a `[weak self]` hop would no-op and the index would never update.
            let closeToken = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [library, store, windowID, weak window] _ in
                MainActor.assumeIsolated {
                    // persist this window's final frame (keyed by its id) so an in-session reopen — or
                    // a restart — restores its size/position. SwiftUI's own index-based autosave can't.
                    if let window {
                        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: TitleProbeView.frameKey(windowID))
                    }
                    WindowRegistry.shared.unregister(windowID)
                    // flush cwd drift since the last structural mutation before dropping the store —
                    // AppStore doesn't save on a live `cd`, so a closed-then-reopened window would
                    // otherwise load a stale snapshot. Skip it when the window is no longer open in the
                    // library (a delete already dropped the store + removed the per-window file, so a
                    // save here would resurrect an orphan file).
                    if library.isOpen(windowID) { store.save() }
                    for session in store.workspaces.flatMap(\.sessions) {
                        session.surface?.teardown()
                        session.splitSurface?.teardown()
                        session.overlaySurface?.teardown()
                    }
                    library.closeWindow(windowID)
                }
            }
            titlebarObservers.append(closeToken)
            // a settings theme change updates GhosttyApp.terminalBackgroundColor; re-apply the
            // blend so the title bar and the (transparent) sidebar pick up the new window color
            // live, not just when the window next re-keys.
            let appearanceToken = NotificationCenter.default.addObserver(forName: .agtAppearanceChanged, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    self.applyTitlebarBlend(window)
                }
            }
            titlebarObservers.append(appearanceToken)
            // a window restored in a miniaturized state isn't on-screen, so a fresh
            // launch shows nothing and UI-test automation has nothing to hit. bring it
            // forward un-minimized; re-assert next tick because state restoration can
            // re-apply the miniaturized state right after the view attaches.
            bringForward(window)
            DispatchQueue.main.async { [weak self] in self?.bringForward(window) }
            applyUITestSidebarFixups(window)
        }

        deinit {
            titlebarObservers.forEach(NotificationCenter.default.removeObserver)
        }

        /// Record this window as the frontmost in the library and persist the index. A no-op when this
        /// window is already frontmost, so the paired `didBecomeKey`/`didBecomeMain` (and a re-key of
        /// the same window) collapse to a single write instead of a per-focus-change write-storm.
        @MainActor private func reportFrontmost(_ id: WindowInfo.ID) {
            guard library.frontmostWindowID != id else { return }
            library.frontmostWindowID = id
            library.saveIndex()
        }

        private func bringForward(_ window: NSWindow) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }

        /// UserDefaults key for this window's saved frame, keyed by the stable window UUID (NOT
        /// SwiftUI's index-based autosave name, which it overrides and which doesn't track identity).
        static func frameKey(_ id: WindowInfo.ID) -> String { "agt-frame-\(id.uuidString)" }

        /// Applies the saved frame for this window id, once. Deferred (window-key / next tick) so
        /// SwiftUI's initial `.defaultSize` pass has run and won't clobber the restored geometry.
        private func restoreSavedFrame(_ window: NSWindow) {
            guard !frameRestored else { return }
            frameRestored = true
            guard let saved = UserDefaults.standard.string(forKey: Self.frameKey(windowID)) else { return }
            let frame = NSRectFromString(saved)
            guard frame.width > 0, frame.height > 0 else { return }
            window.setFrame(frame, display: true)
        }

        /// Installs (or re-asserts) the confirm-before-close proxy as the window's delegate, chaining to
        /// whatever delegate SwiftUI set. No-op when it's already the delegate.
        private func ensureCloseProxy(on window: NSWindow) {
            if closeProxy == nil {
                closeProxy = WindowCloseDelegateProxy(windowID: windowID, library: library, store: store)
            }
            guard let closeProxy else { return }
            if (window.delegate as AnyObject?) !== closeProxy {
                closeProxy.forwardingDelegate = window.delegate
                window.delegate = closeProxy
            }
        }


        private func applyUITestSidebarFixups(_ window: NSWindow) {
            guard ContentView.forceSidebarVisibleForUITests else { return }
            let delays: [TimeInterval] = [0, 0.05, 0.15, 0.35, 0.7, 0.95]
            for delay in delays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                    guard let self, let window, self.window === window else { return }
                    self.bringForwardForUITests(window)
                    UITestWindowFixups.expandSidebar(in: window)
                }
            }
        }

        private func bringForwardForUITests(_ window: NSWindow) {
            NSApp.unhide(nil)
            NSApp.activate()
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }

        private func applyTitlebarBlend(_ window: NSWindow) {
            let background = GhosttyApp.shared.terminalBackgroundColor
                ?? NSColor(srgbRed: 0.157, green: 0.173, blue: 0.204, alpha: 1)
            WindowAppearance.sync(window: window, background: background,
                                  chrome: .init(opacity: GhosttyApp.shared.windowOpacity,
                                                blurRadius: GhosttyApp.shared.windowBlurRadius,
                                                compactToolbar: GhosttyApp.shared.compactToolbar))
        }
    }
}

/// App-side bridge mapping a `WindowInfo.ID` to its live `NSWindow`. `WindowLibrary` is host-free
/// (no AppKit), so the NSWindow handles live here. `TitleProbeView` registers/unregisters on window
/// attach/close; `raise(_:)` brings an already-open window forward (the dedup-by-id raise path) and
/// `close(_:)` runs `performClose` (the `window.close` teardown path).
@MainActor
final class WindowRegistry {
    static let shared = WindowRegistry()
    private var windows: [WindowInfo.ID: NSWindow] = [:]

    private init() {}

    var registeredCount: Int { windows.count }

    func register(_ id: WindowInfo.ID, window: NSWindow) {
        windows[id] = window
    }

    func unregister(_ id: WindowInfo.ID) {
        windows[id] = nil
    }

    func contains(_ window: NSWindow) -> Bool {
        windows.values.contains { $0 === window }
    }

    /// Brings the window for `id` to the front if one is live. Returns whether a window was raised.
    @discardableResult
    func raise(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Closes the on-screen window for `id` if one is live. Uses `window.close()` (NOT `performClose`)
    /// so it bypasses the confirm-before-close proxy — this is the programmatic path (Delete Window,
    /// which already confirms, and the control socket, which must stay headless). `close()` still runs
    /// the `willClose` teardown + library mark-closed. Returns whether a window was closed.
    @discardableResult
    func close(_ id: WindowInfo.ID) -> Bool {
        guard let window = windows[id] else { return false }
        window.close()
        return true
    }
}

/// Forwarding `NSWindowDelegate` that adds a confirm-before-close for a window with running sessions,
/// forwarding every other delegate call to whatever delegate SwiftUI installed. Owned strongly by
/// `TitleProbeView` (`NSWindow.delegate` is weak). Intercepts USER-driven closes (red button, File ▸
/// Close); the programmatic `WindowRegistry.close` uses `window.close()` and skips `windowShouldClose`,
/// so Delete Window / agtctl don't double-prompt.
@MainActor
private final class WindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    nonisolated(unsafe) weak var forwardingDelegate: NSObjectProtocol?
    private let windowID: WindowInfo.ID
    private let library: WindowLibrary
    private let store: AppStore
    private var sheetOpen = false

    init(windowID: WindowInfo.ID, library: WindowLibrary, store: AppStore) {
        self.windowID = windowID
        self.library = library
        self.store = store
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let count = store.workspaces.reduce(0) { $0 + $1.sessions.count }
        guard count > 0 else { return forwardedShouldClose(sender) }
        guard !sheetOpen else { return false }
        sheetOpen = true
        let name = library.windows.first { $0.id == windowID }?.name ?? "window"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \u{201C}\(name)\u{201D}?"
        alert.informativeText = "This ends \(count) running session\(count == 1 ? "" : "s"). The window can be reopened from File ▸ Open Window."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            guard let self, let sender else { return }
            MainActor.assumeIsolated {
                self.sheetOpen = false
                guard response == .alertFirstButtonReturn else { return }
                // force-close: close() doesn't re-enter windowShouldClose (no re-prompt) but still runs
                // the willClose teardown + library mark-closed. The user already confirmed.
                sender.close()
            }
        }
        return false
    }

    private func forwardedShouldClose(_ sender: NSWindow) -> Bool {
        (forwardingDelegate as? NSWindowDelegate)?.windowShouldClose?(sender) ?? true
    }

    // forward every other NSWindowDelegate selector to SwiftUI's delegate so its window bookkeeping
    // (willClose, didResize, …) still runs. Called by the ObjC runtime; reads the weak forward target.
    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (forwardingDelegate?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        forwardingDelegate?.responds(to: selector) == true ? forwardingDelegate : super.forwardingTarget(for: selector)
    }
}
