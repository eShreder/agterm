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

    /// Whether relocating `sessionIDs` into `targetID` would cross an ephemeral (tmux mirror) boundary —
    /// the batch form of the check `moveSession` applies to a single session.
    ///
    /// A mirror hosts ONLY its controller's tmux-backed sessions: a local session moved IN dies when
    /// detach tears the mirror down, and a tmux session moved OUT is stranded with its relay socket
    /// closed — and, worse, it then PERSISTS, because `snapshot()` filters by WORKSPACE, so the relocated
    /// session lands in `workspaces.json` carrying a relay command aimed at a socket that will not exist
    /// on the next launch. A same-workspace reorder is exempt (it crosses nothing).
    ///
    /// Host-free so both the store guard and the control arms' error message resolve it identically; the
    /// sidebar's drag path answers the same question from its own drop state.
    public func moveCrossesEphemeralBoundary(_ sessionIDs: [UUID], toWorkspace targetID: UUID) -> Bool {
        let targetEphemeral = workspaces.first(where: { $0.id == targetID })?.ephemeral == true
        return sessionIDs.contains { id in
            guard let source = workspace(forSession: id), source.id != targetID else { return false }
            return targetEphemeral || source.ephemeral
        }
    }

    /// Removes a workspace and every session in it, tearing down their surfaces and pruning the recency
    /// stack. No-ops unless more than one PERSISTENT workspace exists (the last is kept), an ephemeral
    /// mirror being exempt. If the active session lived there, `workspaceRemovalTarget(at:)` reselects the
    /// most recent still VISIBLE session, falling back to the positional walk only when nothing is visible,
    /// nil when none remain.
    public func removeWorkspace(_ workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        // Keep at least one PERSISTENT workspace; an ephemeral tmux mirror is always removable — its
        // controller's teardown drives the removal and must succeed even when it is the sole workspace.
        guard workspaces[index].ephemeral || canRemoveWorkspace else { return }
        let workspace = workspaces[index]
        let removingActive = selectedSessionID.map { id in workspace.sessions.contains { $0.id == id } } ?? false
        // An ephemeral tmux mirror is never persisted or restorable, so don't record it as recently-closed.
        // The membership goes into the record BEFORE `dropFocusMember` below prunes it, so Reopen Closed
        // Item can mark the workspace again.
        if !workspace.ephemeral {
            recordRecentClosedWorkspace(workspace, selectedSessionID: removingActive ? selectedSessionID : nil,
                                        focusMember: focusedWorkspaceIDs.contains(workspaceID))
        }
        for session in workspace.sessions { emitSessionClosed(session, workspace: workspace.id) }
        if workspace.sessions.isEmpty { scheduleTreeChanged() }
        for session in workspace.sessions {
            session.surface?.teardown()
            session.splitSurface?.teardown()
            session.overlaySurface?.teardown()
            session.teardownPaneOverlays()
            session.scratchSurface?.teardown()
            session.discardHudBody() // a HUD whose surface never realized has no teardown to delete its body file
            WatermarkStorage.removeRenderedText(sessionID: session.id) // drop any rendered .text PNG; the session is gone
            removeFromRecency(session.id)
        }
        dropFocusMember(workspaceID) // a marked root is gone; the filter goes with the last member
        workspaces.remove(at: index)
        forgetFreshWorkspace(workspaceID)
        if removingActive {
            // `workspaceRemovalTarget` handles the emptied tree (removing the SOLE ephemeral mirror) by
            // returning nil, so the index math can't subscript a `workspaces.count - 1 == -1`.
            selectedSessionID = workspaceRemovalTarget(at: index)
            replaceSidebarSelection(with: selectedSessionID)
            disableFocusIfSelectionOutsideSet(selectedSessionID) // the reselected session may live outside the marked set
            recordRecency()
        } else {
            pruneSidebarSelection()
        }
        save()
    }
}
