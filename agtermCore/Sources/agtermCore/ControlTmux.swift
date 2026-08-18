/// One live tmux `-CC` connection in the `tmux.list` result: its workspace uuid (the id used to
/// address `tmux.detach`/`tmux.kill`), the target host (`local` for a local attach), the tmux
/// SESSION name (with `host` it forms the connection's identity, so two connections to the same
/// host stay distinguishable), and the display names of its mirrored windows.
public struct ControlTmuxNode: Codable, Sendable, Equatable {
    public var id: String
    public var host: String
    public var session: String?
    public var windows: [String]
    public init(id: String, host: String, session: String? = nil, windows: [String]) {
        self.id = id
        self.host = host
        self.session = session
        self.windows = windows
    }
}
