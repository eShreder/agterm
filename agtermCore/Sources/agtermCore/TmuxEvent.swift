public enum TmuxEvent: Equatable, Sendable {
    case output(pane: TmuxPaneID, bytes: [UInt8])
    case windowAdd(TmuxWindowID)
    case windowClose(TmuxWindowID, unlinked: Bool)
    case windowRenamed(TmuxWindowID, name: String)
    case windowPaneChanged(window: TmuxWindowID, pane: TmuxPaneID)
    case layoutChange(window: TmuxWindowID, layout: String)
    case sessionChanged(TmuxSessionID, name: String)
    case sessionWindowChanged(TmuxSessionID, window: TmuxWindowID)
    case sessionsChanged
    case blockBegin(num: Int)
    case blockLine(num: Int, text: String)
    case blockEnd(num: Int, error: Bool)
    case exit(reason: String?)
    case unknown(String)
}
