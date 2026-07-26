import agtermCore
import AppKit
import SwiftUI

extension AppActions {
    /// Close one or more sidebar-selected sessions in a window-local store, honoring the same confirmation
    /// and undo-grace settings as the single-session Close command.
    func closeSessions(_ ids: [UUID], in store: AppStore) {
        let sessions = ids.compactMap { store.session(withID: $0) }
        guard !sessions.isEmpty else { return }
        if sessions.count == 1 {
            closeSession(sessions[0].id, in: store)
            return
        }
        guard confirmCloseSessions(sessions) else { return }
        // Backend-aware, like the single-session path this delegates to above: a tmux-backed member routes
        // to `kill-window` and is torn down by the `%window-close` echo, so it must NOT also close locally.
        // It also cannot join the grace-undo group — undo would restore a mirror session whose remote
        // window is already gone and whose relay socket is closed, so only the local members get a grace
        // record. Without this split a batch close left every mirrored window running on the remote while
        // a single close killed it: the same command, two outcomes, decided by the selection size.
        var local: [Session] = []
        for session in sessions where !closeTmuxSession(session.id) { local.append(session) }
        withAnimation(.easeInOut(duration: 0.16)) {
            if closeGraceUndoEnabled {
                if !local.isEmpty { _ = store.softCloseSessions(local.map(\.id)) }
            } else {
                for session in local {
                    store.closeSession(session.id)
                }
            }
        }
        focusActiveSession()
    }

    private func confirmCloseSessions(_ sessions: [Session]) -> Bool {
        guard settingsModel?.settings.confirmCloseSession == true,
              !ContentView.shouldBypassCloseConfirmation else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close \(sessions.count) Sessions?"
        alert.informativeText = closeGraceUndoEnabled
            ? "The sessions will close after a short undo window."
            : "The sessions will close immediately and can be reopened from File > Open Recent."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// sidebar context menus pass their own store so a background window never routes through the
    /// frontmost store by accident.
    func toggleFlags(_ sessionIDs: [UUID], in store: AppStore) {
        let sessions = sessionIDs.compactMap { store.session(withID: $0) }
        guard !sessions.isEmpty else { return }
        let allFlagged = sessions.allSatisfy(\.flagged)
        store.setFlag(!allFlagged, forSessions: sessions.map(\.id))
    }
}
