import SwiftUI

/// The Settings window (Cmd+,): three tabs — General (notifications), Appearance (font/theme +
/// window translucency), and Key Mapping (a placeholder for a later phase).
struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView(model: model)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            PlaceholderSettings(message: "Key mapping coming soon.")
                .tabItem { Label("Key Mapping", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 420)
    }
}

/// General tab: the macOS notification-banner toggle (default on). The sidebar unseen-count badge
/// is independent of this — it tracks notifications whether or not banners are shown.
private struct GeneralSettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Show notification banners", isOn: notificationsEnabled)
                    .accessibilityIdentifier("settings-notifications")
                Text("Terminal desktop notifications (OSC 9 / 777) appear in macOS Notification Center. The sidebar badge tracks them either way.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// 1:1 with the toggle; nil (the default) reads as on, so settings.json stays minimal until the
    /// user turns banners off.
    private var notificationsEnabled: Binding<Bool> {
        Binding(get: { model.settings.notificationsEnabled ?? true },
                set: { model.setNotificationsEnabled($0 ? nil : false) })
    }
}

/// Appearance tab: a Terminal section (font family, default font size, theme) and a Window section
/// (background opacity + blur). Each control persists and live-applies through `SettingsModel`.
private struct AppearanceSettingsView: View {
    let model: SettingsModel
    private let themes = SettingsCatalog.themeNames()
    private let fonts = SettingsCatalog.monospacedFontFamilies()

    var body: some View {
        Form {
            Section("Terminal") {
                Picker("Font", selection: fontFamily) {
                    Text("Default").tag(String?.none)
                    ForEach(fonts, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .accessibilityIdentifier("settings-font-family")

                Stepper(value: fontSize, in: 8 ... 32, step: 1) {
                    Text("Default font size: \(Int(model.settings.fontSize ?? 13))")
                }
                .accessibilityIdentifier("settings-font-size")

                Picker("Theme", selection: theme) {
                    Text("Default").tag(String?.none)
                    ForEach(themes, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .accessibilityIdentifier("settings-theme")
            }

            Section("Window") {
                HStack {
                    Text("Background Opacity")
                    Slider(value: backgroundOpacity, in: 0 ... 1)
                        .accessibilityIdentifier("settings-bg-opacity")
                    Text("\(Int(((model.settings.backgroundOpacity ?? 1) * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }

                HStack {
                    Text("Background Blur")
                    Slider(value: backgroundBlur, in: 0 ... 100)
                        .accessibilityIdentifier("settings-bg-blur")
                    Text("\(model.settings.backgroundBlur ?? 0)")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .disabled((model.settings.backgroundOpacity ?? 1) >= 1)

                Text("Blur only takes effect when opacity is below 100%.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var fontFamily: Binding<String?> {
        Binding(get: { model.settings.fontFamily }, set: { model.setFontFamily($0) })
    }

    private var fontSize: Binding<Double> {
        Binding(get: { model.settings.fontSize ?? 13 }, set: { model.setFontSize($0) })
    }

    private var theme: Binding<String?> {
        Binding(get: { model.settings.theme }, set: { model.setTheme($0) })
    }

    /// 1.0 maps to nil (the opaque default) so settings.json stays minimal and the "unset = default"
    /// convention matches the font/theme controls.
    private var backgroundOpacity: Binding<Double> {
        Binding(get: { model.settings.backgroundOpacity ?? 1 },
                set: { model.setBackgroundOpacity($0 >= 1 ? nil : $0) })
    }

    private var backgroundBlur: Binding<Double> {
        Binding(get: { Double(model.settings.backgroundBlur ?? 0) },
                set: { model.setBackgroundBlur($0 <= 0 ? nil : Int($0.rounded())) })
    }
}

private struct PlaceholderSettings: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
