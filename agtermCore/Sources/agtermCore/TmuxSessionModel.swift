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
    private var windowLeadingPane: [TmuxWindowID: TmuxPaneID] = [:]

    public init() {}

    public mutating func handle(_ event: TmuxEvent) -> [TmuxModelEffect] {
        switch event {
        case .windowAdd(let w):
            windows.insert(w)
            return [.createSession(window: w, name: "")]
        case .windowRenamed(let w, let name):
            guard windows.contains(w) else { return [] }
            return [.renameSession(window: w, name: name)]
        case .windowClose(let w, _):
            guard windows.contains(w) else { return [] }
            windows.remove(w)
            paneToWindow = paneToWindow.filter { $0.value != w }
            windowLeadingPane[w] = nil
            return [.removeSession(window: w)]
        default:
            return []                                     // output/layout/exit handled in Task 7
        }
    }
}
