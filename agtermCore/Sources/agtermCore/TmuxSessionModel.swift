public enum TmuxModelEffect: Equatable, Sendable {
    case createSession(window: TmuxWindowID, name: String)
    case removeSession(window: TmuxWindowID)
    case renameSession(window: TmuxWindowID, name: String)
    case routeOutput(window: TmuxWindowID, bytes: [UInt8])
    case tearDown
    case diagnostic(String)
}

public struct TmuxSessionModel: Sendable {
    private var windows: Set<TmuxWindowID> = []          // windows we've mapped to sessions
    private var paneToWindow: [TmuxPaneID: TmuxWindowID] = [:]

    public init() {}

    public mutating func handle(_ event: TmuxEvent) -> [TmuxModelEffect] {
        switch event {
        case .windowAdd(let w):
            guard !windows.contains(w) else { return [] }
            windows.insert(w)
            return [.createSession(window: w, name: "")]
        case .windowRenamed(let w, let name):
            guard windows.contains(w) else { return [] }
            return [.renameSession(window: w, name: name)]
        case .windowClose(let w, _):
            guard windows.contains(w) else { return [] }
            windows.remove(w)
            paneToWindow = paneToWindow.filter { $0.value != w }
            return [.removeSession(window: w)]
        case .layoutChange(let w, let layout):
            guard windows.contains(w) else { return [] }
            let parsed = TmuxLayout.panes(in: layout)
            guard let leading = parsed.panes.first else { return [] }
            // Re-map: drop this window's old pane bindings, bind only the leading pane.
            paneToWindow = paneToWindow.filter { $0.value != w }
            paneToWindow[leading] = w
            if parsed.hasSplit {
                return [.diagnostic("window \(w.raw) has a split; showing leading pane \(leading.raw)")]
            }
            return []
        case .output(let pane, let bytes):
            guard let w = paneToWindow[pane] else { return [] }
            return [.routeOutput(window: w, bytes: bytes)]
        case .exit:
            return [.tearDown]
        default:
            return []
        }
    }
}
