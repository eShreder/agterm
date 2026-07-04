import Foundation

/// Marks a `Session` as the mirror of a live tmux window under `-CC` control mode: which
/// connection owns it and which tmux window it mirrors. Presence of a non-nil `Session.tmuxBinding`
/// is the recognizability marker for "this session is tmux-backed" everywhere else in the model.
public struct TmuxBinding: Equatable, Sendable {
    public let connectionID: UUID
    public let window: TmuxWindowID

    public init(connectionID: UUID, window: TmuxWindowID) {
        self.connectionID = connectionID
        self.window = window
    }
}
