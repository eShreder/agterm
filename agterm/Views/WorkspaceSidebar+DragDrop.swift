import agtermCore
import AppKit

/// `WorkspaceSidebar.Coordinator` native drag-and-drop — the pasteboard writer plus validate/accept and
/// the resolve helpers that glue AppKit's proposed drop to the host-free `SidebarDrop` index math. Split
/// out of `WorkspaceSidebar.swift` to keep that file under the swiftlint size limit. `workspaceNode(forID:)`
/// stays in the main file (it reads the private `roots` cache); the pasteboard type constants are file-level.
extension WorkspaceSidebar.Coordinator {
    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        // the flat flagged view is a derived projection, not a reorderable tree — no drag source there.
        guard store.sidebarMode == .tree, let node = item as? SidebarNode else { return nil }
        let pbItem = NSPasteboardItem()
        switch node.kind {
        case .session:
            pbItem.setString(node.id.uuidString, forType: sessionPasteboardType)
        case .workspace:
            pbItem.setString(node.id.uuidString, forType: workspacePasteboardType)
        }
        return pbItem
    }

    func outlineView(_ outlineView: NSOutlineView,
                     validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        if draggedWorkspaceID(from: info) != nil {
            guard let move = resolveWorkspaceMove(from: info, in: outlineView) else { return [] }
            // workspace reorder lives at the top level: highlight a between-rows slot under the root.
            outlineView.setDropItem(nil, dropChildIndex: move.dropChildIndex)
            return .move
        }
        guard let move = resolveSessionMove(from: info, item: item, childIndex: index) else { return [] }
        // redraw the drop highlight on the target workspace row at the resolved insert slot.
        outlineView.setDropItem(workspaceNode(forID: move.workspace), dropChildIndex: move.dropChildIndex)
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView,
                     acceptDrop info: NSDraggingInfo,
                     item: Any?,
                     childIndex index: Int) -> Bool {
        if draggedWorkspaceID(from: info) != nil {
            guard let move = resolveWorkspaceMove(from: info, in: outlineView) else { return false }
            store.moveWorkspace(move.workspaceID, at: move.destination)
            return true
        }
        guard let move = resolveSessionMove(from: info, item: item, childIndex: index) else { return false }
        store.moveSession(move.sessionID, toWorkspace: move.workspace, at: move.destination)
        return true
    }

    /// The resolved session drop. `dropChildIndex` is the PRE-removal slot to highlight; `destination`
    /// is the POST-removal index `moveSession` expects.
    private struct SessionMove {
        let sessionID: UUID
        let workspace: UUID
        let dropChildIndex: Int
        let destination: Int
    }

    /// Resolves a proposed session drop into the move it would perform, or nil when the drop is
    /// invalid or a no-op (so both `validateDrop` and `acceptDrop` agree exactly). Reads the pasteboard
    /// + store to map the dragged session and drop-target row to indices, then defers the index
    /// arithmetic (drop-on-row redirect, post-removal off-by-one, no-op detection) to the host-free
    /// `SidebarDrop.resolveSession`.
    private func resolveSessionMove(from info: NSDraggingInfo, item: Any?, childIndex index: Int) -> SessionMove? {
        guard let sessionID = draggedSessionID(from: info), let node = item as? SidebarNode,
              let source = store.sessionLocation(ofSession: sessionID) else { return nil }

        let target: SidebarDrop.SessionDropTarget
        let targetWorkspace: UUID
        switch node.kind {
        case .workspace:
            let count = store.workspaces.first(where: { $0.id == node.id })?.sessions.count ?? 0
            target = .workspaceRow(id: node.id, sessionCount: count)
            targetWorkspace = node.id
        case .session:
            guard let drop = store.sessionLocation(ofSession: node.id) else { return nil }
            target = .sessionRow(workspace: drop.workspace, sessionIndex: drop.index, sessionCount: drop.count)
            targetWorkspace = drop.workspace
        }

        // A tmux mirror (ephemeral workspace) hosts ONLY its controller's tmux-backed sessions, so a
        // CROSS-mirror move is refused at the store (`moveSession` returns false) and hidden from the
        // context menu + palette; decline it here too, else `validateDrop` shows a green drop highlight
        // and `acceptDrop` silently no-ops (the refused Bool is discarded). A same-workspace reorder
        // inside a mirror is exempt, matching the store's boundary check.
        if source.workspace != targetWorkspace,
           store.workspaces.first(where: { $0.id == source.workspace })?.ephemeral == true
            || store.workspaces.first(where: { $0.id == targetWorkspace })?.ephemeral == true {
            return nil
        }

        guard let move = SidebarDrop.resolveSession(sourceWorkspace: source.workspace, sourceIndex: source.index,
                                                    target: target, childIndex: index) else { return nil }
        return SessionMove(sessionID: sessionID, workspace: move.workspace,
                           dropChildIndex: move.dropChildIndex, destination: move.destination)
    }

    /// Resolves a workspace drop into the top-level reorder it would perform, or nil when it is a no-op
    /// (so `validateDrop` and `acceptDrop` agree exactly). A workspace reorder is a TOP-LEVEL move, but
    /// with workspaces expanded their sessions fill the gaps between workspace rows, so `NSOutlineView`
    /// only ever proposes drops INTO a workspace's children (`item != nil`) — never the clean root
    /// between-rows slot — making the reorder impossible from the proposed `item`/`childIndex` alone.
    /// Derive the insert slot from the cursor Y against the workspace ROWS' midpoints instead (sessions
    /// ignored): the slot is the count of workspace rows whose midpoint sits above the cursor, so the
    /// top half of a row drops before it and the bottom half after it. The index arithmetic (post-removal
    /// off-by-one, no-op detection) defers to the host-free `SidebarDrop.resolveWorkspace`.
    private func resolveWorkspaceMove(from info: NSDraggingInfo, in outlineView: NSOutlineView)
        -> (workspaceID: UUID, dropChildIndex: Int, destination: Int)? {
        guard let workspaceID = draggedWorkspaceID(from: info),
              let sourceIndex = store.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        let point = outlineView.convert(info.draggingLocation, from: nil)
        var insertIndex = 0
        for (i, workspace) in store.workspaces.enumerated() {
            guard let node = workspaceNode(forID: workspace.id) else { continue }
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { continue }
            // the outline is flipped (y increases downward): a cursor below a row's midpoint lands after it.
            if point.y > outlineView.rect(ofRow: row).midY { insertIndex = i + 1 }
        }
        guard let move = SidebarDrop.resolveWorkspace(sourceIndex: sourceIndex, count: store.workspaces.count,
                                                      childIndex: insertIndex) else { return nil }
        return (workspaceID, move.dropChildIndex, move.destination)
    }

    /// Reads the dragged workspace id from the pasteboard.
    private func draggedWorkspaceID(from info: NSDraggingInfo) -> UUID? {
        guard let string = info.draggingPasteboard.string(forType: workspacePasteboardType) else { return nil }
        return UUID(uuidString: string)
    }

    /// Reads the dragged session id from the pasteboard.
    private func draggedSessionID(from info: NSDraggingInfo) -> UUID? {
        guard let string = info.draggingPasteboard.string(forType: sessionPasteboardType) else { return nil }
        return UUID(uuidString: string)
    }
}
