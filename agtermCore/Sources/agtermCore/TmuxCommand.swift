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
    /// Dump a pane's CURRENT visible content (with colors) — tmux sends no content for existing
    /// windows on attach, only future `%output`, so the controller captures each window's leading
    /// pane once to paint it. The reply arrives as a `%begin`/`%end` block of grid rows.
    case capturePane(TmuxPaneID)
}

public enum TmuxCommandEncoder {
    /// Single-quote a tmux command argument so a name with spaces (or other characters the tmux
    /// command parser treats as significant) is passed as ONE argument. tmux control-mode command
    /// parsing is shell-like, so a bare `rename-window -t @0 my project` would parse as extra
    /// arguments; `'my project'` is a single argument. Internal single quotes are escaped the shell
    /// way (`'\''`).
    static func quote(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func encode(_ command: TmuxCommand) -> String {
        switch command {
        case .newWindow(let name):
            return name.map { "new-window -n \(quote($0))" } ?? "new-window"
        case .killWindow(let w):
            return "kill-window -t \(w.raw)"
        case .renameWindow(let w, let name):
            return "rename-window -t \(w.raw) \(quote(name))"
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
        case .capturePane(let pane):
            // -p prints to the control block, -e keeps SGR/colors so the paint matches the pane.
            return "capture-pane -p -e -t \(pane.raw)"
        }
    }
}
