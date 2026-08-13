public enum TmuxModelEffect: Equatable, Sendable {
    case createSession(window: TmuxWindowID, name: String)
    case removeSession(window: TmuxWindowID)
    case renameSession(window: TmuxWindowID, name: String)
    case routeOutput(window: TmuxWindowID, bytes: [UInt8])
    case tearDown
    case diagnostic(String)
    /// Debug-level only: what `TmuxOutputFilter` muted, which is per query and far too frequent for
    /// `diagnostic`.
    case trace(String)
}

public struct TmuxSessionModel: Sendable {
    private var windows: Set<TmuxWindowID> = []          // windows we've mapped to sessions
    private var paneToWindow: [TmuxPaneID: TmuxWindowID] = [:]
    private var filter = TmuxOutputFilter()

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
            for pane in paneToWindow.filter({ $0.value == w }).keys { filter.forget(pane: pane) }
            paneToWindow = paneToWindow.filter { $0.value != w }
            return [.removeSession(window: w)]
        case .layoutChange(let w, let layout):
            guard windows.contains(w) else { return [] }
            let parsed = TmuxLayout.panes(in: layout)
            guard let leading = parsed.panes.first else { return [] }
            // Re-map: drop this window's old pane bindings, bind only the leading pane.
            for pane in paneToWindow.filter({ $0.value == w }).keys where pane != leading {
                filter.forget(pane: pane)
            }
            paneToWindow = paneToWindow.filter { $0.value != w }
            paneToWindow[leading] = w
            if parsed.hasSplit {
                return [.diagnostic("window \(w.raw) has a split; showing leading pane \(leading.raw)")]
            }
            return []
        case .output(let pane, let bytes):
            guard let w = paneToWindow[pane] else { return [] }
            let kept = filter.filter(pane: pane, bytes)
            var effects = kept.dropped.map { TmuxModelEffect.trace("\(pane.raw) muted: \($0)") }
            // A chunk that was ALL query, or that ends mid-sequence, routes nothing rather than an empty
            // frame the relay would still hand to the surface.
            if !kept.bytes.isEmpty { effects.append(.routeOutput(window: w, bytes: kept.bytes)) }
            return effects
        case .exit:
            return [.tearDown]
        default:
            return []
        }
    }
}
