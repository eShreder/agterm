import agtCore
import AppKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.umputun.agt", category: "NotificationManager")

/// Owns the macOS notification surface for terminal desktop notifications (OSC 9 / 777).
///
/// `@MainActor` and the `UNUserNotificationCenterDelegate`. `@preconcurrency` on the
/// conformance lets the delegate methods stay main-actor isolated against the pre-concurrency
/// UserNotifications API (matches macterm).
@MainActor
final class NotificationManager: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// The action hub used to navigate to a session/pane on a notification click. Set at launch by
    /// `agtApp`; weak since `AppActions` outlives the manager only by app lifetime.
    weak var actions: AppActions?

    /// Whether to post macOS banners (the General settings toggle, default on). When off, banners are
    /// suppressed but the sidebar badge still tracks unseen notifications. Set by `SettingsModel`.
    var bannersEnabled = true

    /// Register as the notification delegate and request alert authorization. Idempotent; the
    /// scene `.task` may re-run. Best-effort: a denial just means no banners.
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { granted, error in
            if !granted { logger.notice("notification authorization denied: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Handle a terminal desktop notification fired by `surface` (OSC 9 / 777). Resolves the owning
    /// session + pane, suppresses when that pane is focused and agt is active, otherwise posts a
    /// banner (coalescing by session/pane) and bumps the session's unseen badge. Title falls back to
    /// the session name when the program sent an empty title (OSC 9 carries only a body).
    func notify(surface: GhosttySurfaceView, title: String, body: String) {
        guard let session = surface.session else { return }
        let pane = paneRole(of: surface, in: session)

        // strict first-responder check: suppress only when you are actually typing in this pane.
        let firingIsFocused = surface === (NSApp.keyWindow?.firstResponder as? GhosttySurfaceView)
        guard TerminalNotification.shouldDeliver(firingIsFocused: firingIsFocused, appActive: NSApp.isActive) else { return }

        // the badge always tracks the unseen notification; the macOS banner is gated by the toggle.
        session.unseenCount += 1
        guard bannersEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? session.displayName : title
        content.body = body
        // the request identifier is the identity (`<sessionID>:<pane>`): it both coalesces repeats
        // from the same pane and carries the target a click decodes via `TerminalNotification`.
        let identity = TerminalNotification.identity(sessionID: session.id, pane: pane)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identity, content: content, trigger: nil)) { error in
            if let error { logger.error("add failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Remove any delivered banners for a session from Notification Center — called when you focus
    /// the session, so a notification you've navigated to doesn't linger. Covers all of the session's
    /// panes by removing each possible `<sessionID>:<paneRole>` identifier.
    func clearDelivered(sessionID: UUID) {
        let identifiers = PaneRole.allCases.map { TerminalNotification.identity(sessionID: sessionID, pane: $0) }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Which of the session's surfaces fired, by identity against its three slots.
    private func paneRole(of view: GhosttySurfaceView, in session: Session) -> PaneRole {
        if view === (session.splitSurface as? GhosttySurfaceView) { return .split }
        if view === (session.overlaySurface as? GhosttySurfaceView) { return .overlay }
        return .main
    }

    /// Present banners even while agt is the active app (the focused-pane case is dropped before
    /// delivery, so anything reaching here should show).
    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    /// A banner was clicked: bring agt forward and navigate to the firing session/pane (decoded from
    /// the request identifier). A malformed identifier or closed session just leaves the app active.
    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        NSApp.activate(ignoringOtherApps: true)
        guard let target = TerminalNotification.parseIdentity(response.notification.request.identifier) else { return }
        actions?.reveal(sessionID: target.sessionID, pane: target.pane)
    }
}
