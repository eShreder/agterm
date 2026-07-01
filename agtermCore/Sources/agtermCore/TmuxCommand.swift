import Foundation

public enum TmuxCommand: Equatable, Sendable {
    case newWindow(name: String?)
    case killWindow(TmuxWindowID)
    case renameWindow(TmuxWindowID, name: String)
    case sendKeys(pane: TmuxPaneID, bytes: [UInt8])
    case resizeClient(cols: Int, rows: Int)
    case detachClient
    case listWindows
    case killSession
}

public enum TmuxCommandEncoder {
    public static func encode(_ command: TmuxCommand) -> String {
        switch command {
        case .newWindow(let name):
            return name.map { "new-window -n \($0)" } ?? "new-window"
        case .killWindow(let w):
            return "kill-window -t \(w.raw)"
        case .renameWindow(let w, let name):
            return "rename-window -t \(w.raw) \(name)"
        case .sendKeys(let pane, let bytes):
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            return "send-keys -t \(pane.raw) -H \(hex)"
        case .resizeClient(let cols, let rows):
            return "refresh-client -C \(cols)x\(rows)"
        case .detachClient:
            return "detach-client"
        case .listWindows:
            return "list-windows"
        case .killSession:
            return "kill-session"
        }
    }
}
