import Foundation

/// Which surface within a session fired a terminal notification. Encoded into the notification's
/// identity so a click can focus the exact pane, not just the session.
public enum PaneRole: String, Codable, Sendable, CaseIterable {
    case main
    case split
    case overlay
}

/// Pure helpers for terminal desktop notifications (OSC 9 / 777): the coalescing identity that ties
/// a system notification back to a session/pane, and the suppression rule. Host-free and unit-tested;
/// the app target's `NotificationManager` builds the actual `UNNotificationRequest` from these.
public enum TerminalNotification {
    /// The notification's identity, `"<sessionID>:<paneRole>"`. Repeated notifications from the same
    /// pane share it, so the OS replaces the prior banner instead of stacking duplicates.
    public static func identity(sessionID: UUID, pane: PaneRole) -> String {
        "\(sessionID.uuidString):\(pane.rawValue)"
    }

    /// Parses an `identity(sessionID:pane:)` string back into its parts, or nil if malformed. Splits
    /// on the LAST colon: a UUID string contains none, so the suffix is always the role.
    public static func parseIdentity(_ identity: String) -> (sessionID: UUID, pane: PaneRole)? {
        guard let separator = identity.lastIndex(of: ":") else { return nil }
        let idPart = String(identity[..<separator])
        let rolePart = String(identity[identity.index(after: separator)...])
        guard let sessionID = UUID(uuidString: idPart), let pane = PaneRole(rawValue: rolePart) else { return nil }
        return (sessionID, pane)
    }

    /// Whether a notification should be delivered (banner + badge). Suppressed only when the firing
    /// pane is currently focused AND agt is the active app — you are already looking at it.
    public static func shouldDeliver(firingIsFocused: Bool, appActive: Bool) -> Bool {
        !(firingIsFocused && appActive)
    }
}
