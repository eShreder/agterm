import agtermCore
import AppKit

/// Owns the sidebar's inline-rename interaction: it is the `NSTextFieldDelegate` for the outline's
/// editable name fields and holds the rename reentrancy flags. The `WorkspaceSidebar.Coordinator`
/// creates one, points it at the outline, and starts an edit via `beginEditing(node:)`; it reads
/// `isEditing`/`isCommitting` to gate its own row reloads and focus hand-back, and supplies
/// `onRenameEnded` to return keyboard focus to the terminal once an edit finishes.
@MainActor
final class SidebarRenameController: NSObject, NSTextFieldDelegate {
    private let store: AppStore
    /// The shared action seam: an inline session rename routes through it so a tmux-backed session's
    /// rename reaches `rename-window` (backend-aware) instead of only relabeling the local mirror.
    private let actions: AppActions
    weak var outlineView: NSOutlineView?

    /// Called after an inline rename ends (commit or cancel), so the Coordinator can hand keyboard
    /// focus back to the active terminal. Invoked asynchronously from `controlTextDidEndEditing` so the
    /// field editor's resign settles first.
    var onRenameEnded: (() -> Void)?

    /// Set while an end-editing notification is being processed, to ignore the
    /// re-entrant end-editing the cancel/commit path can trigger.
    private var committing = false
    /// Set while a rename field is the active first responder (between
    /// `beginEditing` and `restore`), so a badge tick can't reload the row out
    /// from under the in-progress edit. `committing` covers only the end-editing
    /// instant; this covers the whole typing window.
    private var editing = false
    /// Set by the Esc handler (`doCommandBy` cancelOperation) so the end-editing that the
    /// manual resign triggers is treated as a cancel — the typed value is discarded.
    private var cancellingRename = false
    /// The row's pre-edit label, captured in `beginEditing` so an Esc-cancel can restore the
    /// displayed text (a manual resign keeps the edited stringValue, and a cancel makes no model
    /// change so no reload refreshes the row).
    private var renameOriginalValue: String?

    /// Whether a rename field is currently being edited (first responder between `beginEditing` and
    /// `restore`). Read by the Coordinator to skip row reloads and focus hand-back mid-edit.
    var isEditing: Bool { editing }
    /// Whether an end-editing notification is currently being processed. Read by the Coordinator to
    /// skip a row reload during the commit instant.
    var isCommitting: Bool { committing }

    init(store: AppStore, actions: AppActions) {
        self.store = store
        self.actions = actions
        super.init()
    }

    /// Puts the row's text field into editing mode and focuses it. Called from
    /// the "Rename" menu item and from double-click.
    func beginEditing(node: SidebarNode) {
        guard let outline = outlineView else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        renameOriginalValue = field.stringValue
        field.isEditable = true
        field.isBordered = true
        field.drawsBackground = true
        // the editable field draws its own background, and the label color was set to the row's
        // (often dark) selection-foreground — leaving those makes the edit text unreadable (dark-on-
        // dark) on every theme. paint the field with the terminal theme's foreground-on-background so
        // it reads everywhere; setColors restores the row's color when it reloads after the commit.
        let theme = GhosttyApp.shared
        field.textColor = theme.terminalForegroundColor ?? .labelColor
        field.backgroundColor = theme.terminalBackgroundColor ?? .textBackgroundColor
        field.setAccessibilityIdentifier("edit-field")
        field.window?.makeFirstResponder(field)
        // pause auto-follow while the rename field owns first responder: an armed idle jump would move the
        // outline selection off this row and yank focus into the followed terminal, silently committing the
        // rename mid-edit. balanced by the single resume in `restore` when editing ends — so take the
        // suppression only on the FIRST begin of an edit session. a re-entrant beginEditing on the
        // already-active field (e.g. the Rename Session shortcut pressed again mid-edit) must not stack a
        // second suppress that `restore`'s lone resume can't balance, which would wedge the counted gate
        // and leave auto-follow off for the window until relaunch. (switching to ANOTHER row is fine:
        // makeFirstResponder above ended the prior edit → `restore` already resumed and cleared `editing`.)
        if !editing { store.suppressAutoFollow() }
        editing = true
    }

    /// Intercepts Esc during an inline rename. The field is focused via `makeFirstResponder`
    /// (not the outline's edit session), so AppKit never delivers the cancel text-movement for
    /// Esc — `cancelOperation:` would otherwise do nothing and leave the field stuck in edit
    /// mode. Flag the cancel, resign so `controlTextDidEndEditing` fires, and consume the
    /// command so the default (no-op) handling doesn't run.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard editing, commandSelector == #selector(NSResponder.cancelOperation(_:)),
              let field = control as? NSTextField else { return false }
        cancellingRename = true
        field.window?.makeFirstResponder(outlineView)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !committing, let field = notification.object as? NSTextField, let outline = outlineView else { return }
        committing = true
        defer { committing = false }

        // resolve which node this field belongs to via the row of its cell view
        let row = outline.row(for: field)
        let node = row >= 0 ? outline.item(atRow: row) as? SidebarNode : nil

        // Escape cancels: via AppKit's cancel text-movement, or via our Esc handler's flag (the
        // manual-resign path the rename field needs, since it never gets the cancel movement).
        let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
        let cancelled = movement == NSTextMovement.cancel.rawValue || cancellingRename
        cancellingRename = false

        let newValue = field.stringValue
        // a manual-resign cancel keeps the edited stringValue and makes no model change (no row
        // reload), so restore the pre-edit label before flipping the field back to a plain label.
        if cancelled, let original = renameOriginalValue { field.stringValue = original }
        restore(field: field, kind: node?.kind)
        // a rename ends with focus on the field editor; hand it back to the active terminal so the
        // sidebar never keeps keyboard focus (the design contract). deferred so the editor's resign
        // settles first — focusActiveTerminal bails while an NSText field editor is first responder.
        DispatchQueue.main.async { [weak self] in self?.onRenameEnded?() }
        guard let node, !cancelled else { return }

        switch node.kind {
        // backend-aware: a tmux-backed session routes to rename-window (the name follows via the
        // %window-renamed echo); a normal session renames locally. The local half uses THIS window's
        // store, not actions.renameSession's frontmost fallback — the commit fires on focus loss, which
        // may be a click INTO another window that already became key (same store-explicit pattern as
        // the session.rename control arm).
        case .session:
            if !actions.renameTmuxSession(node.id, to: newValue) { store.renameSession(node.id, to: newValue) }
        case .workspace: store.renameWorkspace(node.id, to: newValue)
        }
    }

    /// Returns a renamed/edited field to its non-editable label state and resets
    /// its accessibility identifier to the row identifier for its kind.
    private func restore(field: NSTextField, kind: SidebarNode.Kind?) {
        editing = false
        // rename ended (commit or cancel) — lift the suppression `beginEditing` took so auto-follow resumes.
        store.resumeAutoFollow()
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.setAccessibilityIdentifier(kind == .workspace ? "workspace-row" : "session-row")
        // beginEditing painted the field with the theme fg-on-bg for the edit box; restore the row's
        // selection-aware themed color so a commit that didn't change the name (no reload) doesn't
        // leave the edit color stuck on the row.
        if let outline = outlineView, let cell = field.superview as? SidebarCellView {
            let row = outline.row(for: field)
            cell.setColors(selected: row >= 0 && outline.selectedRowIndexes.contains(row))
        }
    }
}
