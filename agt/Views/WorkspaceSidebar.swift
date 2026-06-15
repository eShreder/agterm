import agtCore
import AppKit
import SwiftUI

/// Custom pasteboard type carrying a dragged session's UUID string. Local-only
/// drags (within the outline) use this to identify the session being moved.
private let sessionPasteboardType = NSPasteboard.PasteboardType("com.umputun.agt.session")

/// A stable reference-type node fed to `NSOutlineView`. NSOutlineView keys item
/// identity and expansion state by object identity (`===`), so the nodes must be
/// the SAME instances across reloads — never freshly-allocated structs. The
/// coordinator caches one node per workspace/session id and reuses it, rebuilding
/// only the child lists from the store on each reload.
private final class SidebarNode {
    enum Kind { case workspace, session }

    let kind: Kind
    let id: UUID
    /// Workspace child nodes, repopulated from the store on each rebuild. Empty
    /// for session nodes.
    var children: [SidebarNode] = []

    init(kind: Kind, id: UUID) {
        self.kind = kind
        self.id = id
    }
}

/// AppKit `NSOutlineView` sidebar (source-list style) hosted in SwiftUI via
/// `NSViewRepresentable`. Replaces the SwiftUI `List` sidebar so cross-workspace
/// drag-and-drop works natively: a session row can be dragged onto a different
/// workspace and the model moves it (same `Session` instance preserved).
///
/// Two-level tree: workspaces (expandable parents, bold) → sessions (children).
/// Only session rows are selectable detail targets. Inline rename via double-click
/// or the "Rename" context menu. Context menus per row drive the store API.
struct WorkspaceSidebar: NSViewRepresentable {
    @Bindable var store: AppStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 14
        outline.autosaveExpandedItems = false
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        if #available(macOS 11.0, *) { outline.style = .sourceList }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        // native drag-and-drop: session rows are draggable; drops accepted onto a
        // different workspace (the workspace row or among its children).
        outline.registerForDraggedTypes([sessionPasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)

        context.coordinator.outlineView = outline
        context.coordinator.rebuildAndReload()
        context.coordinator.expandAll()
        context.coordinator.syncSelection()

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // touching the observed store properties here registers this representable
        // as an observer, so SwiftUI re-invokes updateNSView when the tree or
        // selection changes (add/rename/move/close/select).
        _ = store.workspaces.map { ($0.id, $0.name, $0.sessions.map(\.id)) }
        _ = store.selectedSessionID
        context.coordinator.rebuildAndReload()
        context.coordinator.syncSelection()
    }

    /// Backs the outline as both data source and delegate. `@MainActor` so the
    /// AppKit delegate callbacks (all main-thread) satisfy the store's main-actor
    /// isolation under strict concurrency.
    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
        private let store: AppStore
        weak var outlineView: NSOutlineView?

        /// Root workspace nodes in store order. Rebuilt (in place, reusing cached
        /// node instances) from the store on each reload.
        private var roots: [SidebarNode] = []
        /// Cache of node instances keyed by id, so identity is stable across reloads.
        private var nodeCache: [UUID: SidebarNode] = [:]
        /// Set while an end-editing notification is being processed, to ignore the
        /// re-entrant end-editing the cancel/commit path can trigger.
        private var committing = false
        /// Guards `syncSelection` against the selection-change delegate callback it
        /// itself triggers (which would otherwise re-enter the store).
        private var applyingSelection = false

        init(store: AppStore) {
            self.store = store
        }

        // MARK: - Model rebuild

        /// Rebuilds `roots` from the store, reusing cached node instances by id so
        /// NSOutlineView item identity and expansion state stay stable, then reloads
        /// the outline preserving expansion.
        func rebuildAndReload() {
            guard let outline = outlineView else { return }

            var seen = Set<UUID>()
            var newRoots: [SidebarNode] = []
            for workspace in store.workspaces {
                let wsNode = node(for: workspace.id, kind: .workspace)
                seen.insert(workspace.id)
                wsNode.children = workspace.sessions.map { session in
                    seen.insert(session.id)
                    return node(for: session.id, kind: .session)
                }
                newRoots.append(wsNode)
            }
            // drop cached nodes for ids no longer present
            nodeCache = nodeCache.filter { seen.contains($0.key) }
            roots = newRoots

            // preserve which workspaces are expanded across the reload
            let expanded = roots.filter { outline.isItemExpanded($0) }
            outline.reloadData()
            for node in expanded { outline.expandItem(node) }
        }

        /// Expands every workspace row (new workspaces start open).
        func expandAll() {
            guard let outline = outlineView else { return }
            for node in roots { outline.expandItem(node) }
        }

        private func node(for id: UUID, kind: SidebarNode.Kind) -> SidebarNode {
            if let existing = nodeCache[id] { return existing }
            let node = SidebarNode(kind: kind, id: id)
            nodeCache[id] = node
            return node
        }

        // MARK: - Selection

        /// Reflects `store.selectedSessionID` into the outline selection without
        /// re-entering the store. Workspace rows are never auto-selected.
        func syncSelection() {
            guard let outline = outlineView else { return }
            applyingSelection = true
            defer { applyingSelection = false }
            guard let selectedID = store.selectedSessionID, let node = nodeCache[selectedID], node.kind == .session else {
                outline.deselectAll(nil)
                return
            }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            if outline.selectedRow != row {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let outline = outlineView else { return }
            let row = outline.selectedRow
            guard row >= 0, let node = outline.item(atRow: row) as? SidebarNode, node.kind == .session else {
                return
            }
            store.selectSession(node.id)
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? SidebarNode else { return roots.count }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? SidebarNode else { return roots[index] }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            return node.kind == .workspace
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? SidebarNode else { return false }
            return node.kind == .session
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? SidebarNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier(node.kind == .workspace ? "workspace-cell" : "session-cell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier)

            let field = cell.textField!
            field.delegate = self
            // a reused cell may carry editing state from a prior rename; reset to label
            field.isEditable = false
            field.isBordered = false
            field.drawsBackground = false
            switch node.kind {
            case .workspace:
                let name = store.workspaces.first(where: { $0.id == node.id })?.name ?? ""
                field.stringValue = name
                field.font = .preferredFont(forTextStyle: .headline)
                field.setAccessibilityIdentifier("workspace-row")
                // expose the workspace name so app.staticTexts["workspace 1"] resolves
                field.setAccessibilityLabel(name)
            case .session:
                field.stringValue = displayName(forSession: node.id)
                field.font = .preferredFont(forTextStyle: .body)
                field.setAccessibilityIdentifier("session-row")
                field.setAccessibilityLabel(nil)
            }
            return cell
        }

        /// Builds a view-based outline cell: an `NSTableCellView` with a single
        /// non-editable `NSTextField`. Editing is enabled on demand by `beginEditing`.
        private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            field.isEditable = false
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            cell.addSubview(field)
            cell.textField = field

            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func displayName(forSession id: UUID) -> String {
            for workspace in store.workspaces {
                if let session = workspace.sessions.first(where: { $0.id == id }) { return session.displayName }
            }
            return ""
        }

        // MARK: - Inline rename

        /// Puts the row's text field into editing mode and focuses it. Called from
        /// the "Rename" menu item and from double-click.
        private func beginEditing(node: SidebarNode) {
            guard let outline = outlineView else { return }
            let row = outline.row(forItem: node)
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let field = cell.textField else { return }
            field.isEditable = true
            field.isBordered = true
            field.drawsBackground = true
            field.setAccessibilityIdentifier("edit-field")
            field.window?.makeFirstResponder(field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard !committing, let field = notification.object as? NSTextField, let outline = outlineView else { return }
            committing = true
            defer { committing = false }

            // resolve which node this field belongs to via the row of its cell view
            let row = outline.row(for: field)
            let node = row >= 0 ? outline.item(atRow: row) as? SidebarNode : nil

            // Escape cancels: AppKit reports it via the text-movement key in userInfo.
            let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
            let cancelled = movement == NSTextMovement.cancel.rawValue

            let newValue = field.stringValue
            restore(field: field, kind: node?.kind)
            guard let node, !cancelled else { return }

            switch node.kind {
            case .session: store.renameSession(node.id, to: newValue)
            case .workspace: store.renameWorkspace(node.id, to: newValue)
            }
        }

        /// Returns a renamed/edited field to its non-editable label state and resets
        /// its accessibility identifier to the row identifier for its kind.
        private func restore(field: NSTextField, kind: SidebarNode.Kind?) {
            field.isEditable = false
            field.isBordered = false
            field.drawsBackground = false
            field.setAccessibilityIdentifier(kind == .workspace ? "workspace-row" : "session-row")
        }

        // MARK: - Context menu

        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard row >= 0, let node = sender.item(atRow: row) as? SidebarNode else { return }
            beginEditing(node: node)
        }

        /// Builds the per-row context menu. Resolves the clicked row lazily so the
        /// same menu serves every row.
        func menu(forRow row: Int) -> NSMenu? {
            guard let outline = outlineView, row >= 0, let node = outline.item(atRow: row) as? SidebarNode else { return nil }
            let menu = NSMenu()

            let rename = NSMenuItem(title: "Rename", action: #selector(menuRename(_:)), keyEquivalent: "")
            rename.target = self
            rename.representedObject = node
            menu.addItem(rename)

            switch node.kind {
            case .session:
                let targets = store.workspaces.filter { $0.id != ownerWorkspaceID(ofSession: node.id) }
                if !targets.isEmpty {
                    let moveTo = NSMenuItem(title: "Move to", action: nil, keyEquivalent: "")
                    let submenu = NSMenu()
                    for target in targets {
                        let item = NSMenuItem(title: target.name, action: #selector(menuMove(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = MoveRequest(sessionID: node.id, targetID: target.id)
                        submenu.addItem(item)
                    }
                    moveTo.submenu = submenu
                    menu.addItem(moveTo)
                }
                let close = NSMenuItem(title: "Close Session", action: #selector(menuClose(_:)), keyEquivalent: "")
                close.target = self
                close.representedObject = node
                menu.addItem(close)
            case .workspace:
                let newSession = NSMenuItem(title: "New Session", action: #selector(menuNewSession(_:)), keyEquivalent: "")
                newSession.target = self
                newSession.representedObject = node
                menu.addItem(newSession)
            }
            return menu
        }

        private func ownerWorkspaceID(ofSession id: UUID) -> UUID? {
            store.workspaces.first(where: { ws in ws.sessions.contains(where: { $0.id == id }) })?.id
        }

        /// Wraps a move command so a `Move to ▸ <ws>` item can carry both ids.
        private final class MoveRequest {
            let sessionID: UUID
            let targetID: UUID
            init(sessionID: UUID, targetID: UUID) {
                self.sessionID = sessionID
                self.targetID = targetID
            }
        }

        @objc private func menuRename(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarNode else { return }
            beginEditing(node: node)
        }

        @objc private func menuMove(_ sender: NSMenuItem) {
            guard let request = sender.representedObject as? MoveRequest else { return }
            store.moveSession(request.sessionID, toWorkspace: request.targetID)
        }

        @objc private func menuClose(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarNode else { return }
            store.closeSession(node.id)
        }

        @objc private func menuNewSession(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? SidebarNode else { return }
            store.addSession(toWorkspace: node.id, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
        }

        // MARK: - Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? SidebarNode, node.kind == .session else { return nil }
            let pbItem = NSPasteboardItem()
            pbItem.setString(node.id.uuidString, forType: sessionPasteboardType)
            return pbItem
        }

        func outlineView(_ outlineView: NSOutlineView,
                         validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?,
                         proposedChildIndex index: Int) -> NSDragOperation {
            guard let sessionID = draggedSessionID(from: info), let target = targetWorkspace(forDropOn: item) else {
                return []
            }
            // only a move ONTO a different workspace counts
            guard ownerWorkspaceID(ofSession: sessionID) != target else { return [] }
            // retarget the drop to the whole workspace row (no in-between insertion)
            outlineView.setDropItem(workspaceNode(forID: target), dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView,
                         acceptDrop info: NSDraggingInfo,
                         item: Any?,
                         childIndex index: Int) -> Bool {
            guard let sessionID = draggedSessionID(from: info), let target = targetWorkspace(forDropOn: item) else {
                return false
            }
            guard ownerWorkspaceID(ofSession: sessionID) != target else { return false }
            store.moveSession(sessionID, toWorkspace: target)
            return true
        }

        /// Reads the dragged session id from the pasteboard.
        private func draggedSessionID(from info: NSDraggingInfo) -> UUID? {
            guard let string = info.draggingPasteboard.string(forType: sessionPasteboardType) else { return nil }
            return UUID(uuidString: string)
        }

        /// The destination workspace id for a drop on `item`: a workspace row maps
        /// to itself; a session row maps to its owning workspace; a nil item (drop
        /// in empty space) has no workspace target.
        private func targetWorkspace(forDropOn item: Any?) -> UUID? {
            guard let node = item as? SidebarNode else { return nil }
            switch node.kind {
            case .workspace: return node.id
            case .session: return ownerWorkspaceID(ofSession: node.id)
            }
        }

        private func workspaceNode(forID id: UUID) -> SidebarNode? {
            roots.first(where: { $0.id == id })
        }
    }
}

/// An `NSOutlineView` subclass that serves a per-row context menu and starts
/// inline rename on double-click, both routed to the coordinator.
final class SidebarOutlineView: NSOutlineView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // select the right-clicked row so the menu's context matches
        if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return (delegate as? WorkspaceSidebar.Coordinator)?.menu(forRow: row)
    }
}
