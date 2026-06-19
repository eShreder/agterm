import agtCore
import Foundation

/// The observable settings state for the Settings window. Loads `AppSettings` from `SettingsStore`
/// at init; each mutation persists AND applies live to the running terminals.
///
/// Applying writes the ghostty settings file, rebuilds + broadcasts the config to every live
/// surface, and clears per-session font-size overrides (the shared `update_config` resets all
/// surfaces to the new default, so the persisted overrides are cleared to match).
@Observable
@MainActor
final class SettingsModel {
    private let store: AppStore
    private let settingsStore: SettingsStore
    private(set) var settings: AppSettings

    init(store: AppStore, settingsStore: SettingsStore) {
        self.store = store
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
        // mirror the persisted window translucency + notification toggle into their shared channels
        // at launch, before any settings change fires.
        applyWindowTranslucency()
        applyNotificationsEnabled()
    }

    func setFontFamily(_ value: String?) { settings.fontFamily = value; persistAndApply() }
    func setFontSize(_ value: Double?) { settings.fontSize = value; persistAndApply() }
    func setTheme(_ value: String?) { settings.theme = value; persistAndApply() }
    func setBackgroundOpacity(_ value: Double?) { settings.backgroundOpacity = value; persistAndApply() }
    func setBackgroundBlur(_ value: Int?) { settings.backgroundBlur = value; persistAndApply() }
    func setNotificationsEnabled(_ value: Bool?) { settings.notificationsEnabled = value; persistAndApply() }

    private func persistAndApply() {
        try? settingsStore.save(settings)
        // only rebuild + rebroadcast the ghostty config (which resets every surface to the default
        // font size) when the generated config TEXT actually changed. A window-opacity drag within
        // the translucent range, or a blur change, leaves the config identical — re-syncing the
        // window alone is enough and avoids hammering surface rebuilds on every slider tick.
        if writeGhosttyConfig() {
            GhosttyApp.shared.reloadConfig(surfaces: liveSurfaces())
            store.resetSessionFontSizes()
        }
        applyWindowTranslucency()
        applyNotificationsEnabled()
        // refresh the app chrome (status bar + title bar + sidebar) with the new terminal color and
        // window translucency immediately, rather than only when the window next re-keys.
        NotificationCenter.default.post(name: .agtAppearanceChanged, object: nil)
    }

    private func applyWindowTranslucency() {
        GhosttyApp.shared.setWindowTranslucency(opacity: settings.backgroundOpacity ?? 1,
                                                blurRadius: settings.backgroundBlur ?? 0)
    }

    private func applyNotificationsEnabled() {
        NotificationManager.shared.bannersEnabled = settings.notificationsEnabled ?? true
    }

    /// Write the ghostty config lines (font/size/theme + the translucency pins) to the file
    /// `GhosttyApp.loadConfig` reads. Returns true if the file content changed, so the caller can
    /// skip the expensive reload when it didn't.
    private func writeGhosttyConfig() -> Bool {
        let url = GhosttyApp.settingsConfigURL
        let text = settings.ghosttyConfigLines().joined(separator: "\n") + "\n"
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// All live ghostty surfaces: each session's primary + split surface, plus the quick terminal.
    private func liveSurfaces() -> [GhosttySurfaceView] {
        var views = store.workspaces
            .flatMap(\.sessions)
            .flatMap { [$0.surface, $0.splitSurface] }
            .compactMap { $0 as? GhosttySurfaceView }
        if let quick = QuickTerminalController.shared.currentSurface() { views.append(quick) }
        return views
    }
}
