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
    ///
    /// CR/LF are STRIPPED first: the `-CC` control stream is line-delimited (`send` appends `\n`), so a
    /// raw newline embedded in a name would terminate the command line and let the tail parse as a
    /// SEPARATE tmux command — a command injection that single-quoting does NOT prevent (the line break
    /// breaks out of the quotes entirely). A tmux argument fundamentally cannot carry a raw newline, so
    /// removing them yields a valid single-line argument.
    static func quote(_ arg: String) -> String {
        let oneLine = arg.filter { $0 != "\n" && $0 != "\r" }
        return "'" + oneLine.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
            // Comma form on purpose: tmux ≤3.1 parses ONLY `-C W,H`; ≥3.2 accepts both `W,H` and `WxH`.
            // The `WxH` form silently no-ops (an `%error` block) on older servers — the client size then
            // never applies and every pane stays at the 80x24 default (apps never see a SIGWINCH).
            return "refresh-client -C \(cols),\(rows)"
        case .detachClient:
            return "detach-client"
        case .listWindows:
            // Explicit `-F` fields, NOT the human display: the two space-free fields (id, layout) come
            // FIRST and the free-form name LAST, so `TmuxWindowList.parse` recovers a name containing
            // spaces, parentheses, or a trailing `*`/`-` verbatim. Parsing tmux's default display
            // (`name (N panes) … [layout …]`) is ambiguous — `api (prod)` truncates and `build-` loses
            // its dash. The `-CC` control stream is line-delimited, so a per-window line is safe.
            return "list-windows -F '#{window_id} #{window_layout} #{window_name}'"
        case .killSession:
            return "kill-session"
        case .capturePane(let pane):
            // -p prints to the control block, -e keeps SGR/colors so the paint matches the pane.
            return "capture-pane -p -e -t \(pane.raw)"
        }
    }
}
