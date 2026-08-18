import Foundation

/// A user-named group of sessions (e.g. "work", "personal"). A value type with
/// a stable UUID identity; its `sessions` array holds `Session` references.
@MainActor
public struct Workspace: Identifiable {
    public let id: UUID
    public var name: String
    public var sessions: [Session]
    /// Whether the sidebar row is expanded (its session rows shown). Defaults true so a freshly created
    /// workspace opens; persisted per workspace so the collapse state survives a relaunch.
    public var isExpanded: Bool
    /// Whether this workspace is an ephemeral mirror (e.g. a tmux `-CC` host workspace) that must
    /// never land in `workspaces.json`. `AppStore.snapshot()` filters these out before persisting.
    public var ephemeral: Bool = false

    public init(name: String, sessions: [Session] = [], isExpanded: Bool = true, ephemeral: Bool = false) {
        id = UUID()
        self.name = name
        self.sessions = sessions
        self.isExpanded = isExpanded
        self.ephemeral = ephemeral
    }

    public init(id: UUID, name: String, sessions: [Session] = [], isExpanded: Bool = true, ephemeral: Bool = false) {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.isExpanded = isExpanded
        self.ephemeral = ephemeral
    }

    /// Total unseen-notification count across this workspace's sessions, for the badge on a
    /// collapsed workspace row (when its session rows are hidden).
    public var unseenCount: Int { sessions.reduce(0) { $0 + $1.unseenCount } }
}
