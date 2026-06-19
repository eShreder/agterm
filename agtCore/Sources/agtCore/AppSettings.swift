import Foundation

/// User-facing appearance settings, persisted independently of the workspace tree.
///
/// Every field is optional: nil means "use the ghostty default", and a settings file written
/// before a field existed still decodes — that optionality IS the forward-compat mechanism, so
/// there is no version field (a version bump would only add a discard-on-mismatch path that wipes
/// the user's settings).
public struct AppSettings: Codable, Equatable, Sendable {
    /// Terminal font family name (e.g. `SF Mono`), or nil for the ghostty default.
    public var fontFamily: String?
    /// Default terminal font size in points, or nil for the ghostty default.
    public var fontSize: Double?
    /// ghostty theme name (e.g. `Adwaita Dark`), or nil for the ghostty default.
    public var theme: String?
    /// Window background opacity in 0...1 (1 = fully opaque), or nil for opaque. Composited at the
    /// AppKit window level, NOT by the ghostty renderer: when < 1, `ghosttyConfigLines()` pins the
    /// renderer fully transparent so the window's tinted background is the single translucent layer
    /// (otherwise the surface and the window would stack two tints).
    public var backgroundOpacity: Double?
    /// Background blur radius (private CGS window blur, 0...100), or nil for no blur. Only has a
    /// visible effect when `backgroundOpacity` < 1. Applied in the app target, NOT a ghostty key.
    public var backgroundBlur: Int?
    /// Whether to post macOS notification banners for terminal desktop notifications. nil means the
    /// default (on). Only gates the OS banner — the sidebar unseen-count badge tracks notifications
    /// either way.
    public var notificationsEnabled: Bool?

    public init(fontFamily: String? = nil, fontSize: Double? = nil, theme: String? = nil,
                backgroundOpacity: Double? = nil, backgroundBlur: Int? = nil, notificationsEnabled: Bool? = nil) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.notificationsEnabled = notificationsEnabled
    }

    /// The ghostty config lines for the set fields, one `key = value` per line, suitable for a
    /// file loaded via `ghostty_config_load_file`. Unset (or blank) fields are omitted. Values are
    /// written raw — ghostty takes the whole line remainder as the value, so names with spaces
    /// (`3024 Night`, `SF Mono`) are NOT quoted (quoting would become part of the value).
    public func ghosttyConfigLines() -> [String] {
        var lines: [String] = []
        if let fontFamily, !fontFamily.isEmpty { lines.append("font-family = \(fontFamily)") }
        if let fontSize { lines.append("font-size = \(Self.format(fontSize))") }
        if let theme, !theme.isEmpty { lines.append("theme = \(theme)") }
        // a translucent window composites its tint at the AppKit level, so the renderer must draw a
        // fully transparent terminal — else the surface and the window stack two tints. At full
        // opacity (or unset) ghostty paints its own background as usual and these are omitted.
        if let backgroundOpacity, backgroundOpacity < 1 {
            lines.append("background-opacity = 0")
            lines.append("background-blur = 0")
        }
        return lines
    }

    /// Integer sizes render without a trailing `.0` (`14`, not `14.0`); fractional sizes keep it.
    private static func format(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(size)
    }
}
