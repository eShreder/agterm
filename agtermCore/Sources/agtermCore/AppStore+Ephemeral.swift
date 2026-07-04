import Foundation

/// Ephemeral (tmux-mirror) workspace removal gates. An ephemeral workspace is never persisted and can
/// vanish on detach, so the keep-at-least-one invariant must count only PERSISTENT workspaces and a mirror
/// must stay removable even when it is the sole workspace.
extension AppStore {
    /// The number of persistent (non-ephemeral) workspaces. The keep-at-least-one invariant counts only
    /// these — an ephemeral tmux mirror is never persisted and can vanish on detach, so it must not stand
    /// in for a real workspace (else deleting the last normal workspace would save an empty tree).
    private var persistentWorkspaceCount: Int {
        workspaces.reduce(0) { $0 + ($1.ephemeral ? 0 : 1) }
    }

    /// Whether a normal workspace may be removed: one persistent workspace is always kept, so removal is
    /// allowed only when more than one persistent workspace exists. An ephemeral tmux mirror is torn down
    /// via its controller's teardown, which bypasses this gate in `removeWorkspace`.
    public var canRemoveWorkspace: Bool { persistentWorkspaceCount > 1 }

    /// Whether a SPECIFIC workspace may be removed. An ephemeral tmux mirror is ALWAYS removable — its
    /// removal keeps the persistent count intact and its controller's teardown drives the removal — while
    /// a normal workspace obeys the keep-at-least-one-persistent gate. Mirrors the `ephemeral || …`
    /// exemption in `removeWorkspace` so the delete AFFORDANCES (the `deleteWorkspace` action, the sidebar
    /// row's Delete item, the `workspace.delete` control arm) don't block deleting a mirror in the common
    /// "one normal workspace + one mirror" case, where the global `canRemoveWorkspace` is false. Unknown
    /// id → false.
    public func canRemoveWorkspace(_ workspaceID: UUID) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return false }
        return workspace.ephemeral || canRemoveWorkspace
    }

    /// The `canRemoveWorkspace(_:)` check applied to `currentWorkspaceID` — the delete target of the menu
    /// bar and action palette, which act on the active workspace (via `deleteActiveWorkspace`) rather than
    /// a clicked row, so their enable/visibility gate must also honor the ephemeral exemption.
    public var canRemoveActiveWorkspace: Bool {
        guard let id = currentWorkspaceID else { return false }
        return canRemoveWorkspace(id)
    }

    /// Removes a workspace and every session in it, tearing down each session's surfaces
    /// and pruning them from the recency stack. No-ops unless more than one workspace
    /// exists (the last one is kept). If the active session lived in the removed
    /// workspace, reselects the first session of a remaining workspace (the one that
    /// shifted into the removed slot, else the first non-empty workspace), or nil when
    /// no sessions remain.
    public func removeWorkspace(_ workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        // Keep at least one PERSISTENT workspace; an ephemeral tmux mirror is always removable — its
        // controller's teardown drives the removal and must succeed even when it is the sole workspace.
        guard workspaces[index].ephemeral || canRemoveWorkspace else { return }
        let workspace = workspaces[index]
        let removingActive = selectedSessionID.map { id in workspace.sessions.contains { $0.id == id } } ?? false
        // An ephemeral tmux mirror is never persisted or restorable, so don't record it as recently-closed.
        if !workspace.ephemeral {
            recordRecentClosedWorkspace(workspace, selectedSessionID: removingActive ? selectedSessionID : nil)
        }
        for session in workspace.sessions {
            session.surface?.teardown()
            session.splitSurface?.teardown()
            session.overlaySurface?.teardown()
            session.scratchSurface?.teardown()
            WatermarkStorage.removeRenderedText(sessionID: session.id) // drop any rendered .text PNG; the session is gone
            removeFromRecency(session.id)
        }
        if focusedWorkspaceID == workspaceID { focusedWorkspaceID = nil } // the focused root is gone
        workspaces.remove(at: index)
        if removingActive {
            // removing the SOLE (ephemeral) workspace empties the tree — guard the index math so
            // `workspaces.count - 1 == -1` can't subscript-crash; nothing is left to reselect.
            if workspaces.isEmpty {
                selectedSessionID = nil
            } else {
                let fallbackIndex = min(index, workspaces.count - 1)
                selectedSessionID = workspaces[fallbackIndex].sessions.first?.id
                    ?? workspaces.first(where: { !$0.sessions.isEmpty })?.sessions.first?.id
            }
            replaceSidebarSelection(with: selectedSessionID)
            autoUnfocusIfOutsideFocus(selectedSessionID) // the reselected session may live outside the focused workspace
            recordRecency()
        } else {
            pruneSidebarSelection()
        }
        save()
    }
}
