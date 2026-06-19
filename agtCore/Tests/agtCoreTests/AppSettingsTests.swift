import Foundation
import Testing
@testable import agtCore

struct AppSettingsTests {
    @Test func jsonRoundTrips() throws {
        let original = AppSettings(fontFamily: "SF Mono", fontSize: 14, theme: "Adwaita Dark")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func fileMissingAFieldStillDecodes() throws {
        // a settings.json written before `theme` existed: only font-size present.
        let json = #"{ "fontSize": 16 }"#
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(decoded.fontSize == 16)
        #expect(decoded.fontFamily == nil)
        #expect(decoded.theme == nil)
    }

    @Test func emptySettingsProduceNoConfigLines() {
        #expect(AppSettings().ghosttyConfigLines().isEmpty)
    }

    @Test func configLinesCoverSetFieldsRawNoQuoting() {
        let settings = AppSettings(fontFamily: "SF Mono", fontSize: 14, theme: "3024 Night")
        let lines = settings.ghosttyConfigLines()
        // raw values — names with spaces are NOT quoted (ghostty takes the line remainder).
        #expect(lines.contains("font-family = SF Mono"))
        #expect(lines.contains("theme = 3024 Night"))
        #expect(lines.contains("font-size = 14")) // integer renders without ".0"
    }

    @Test func configLinesOmitUnsetFields() {
        let lines = AppSettings(theme: "Alabaster").ghosttyConfigLines()
        #expect(lines == ["theme = Alabaster"])
    }

    @Test func fractionalFontSizeKeepsDecimal() {
        let lines = AppSettings(fontSize: 13.5).ghosttyConfigLines()
        #expect(lines == ["font-size = 13.5"])
    }

    @Test func backgroundFieldsRoundTrip() throws {
        let original = AppSettings(backgroundOpacity: 0.63, backgroundBlur: 20)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func translucentOpacityPinsRendererTransparent() {
        let lines = AppSettings(backgroundOpacity: 0.63).ghosttyConfigLines()
        #expect(lines.contains("background-opacity = 0"))
        #expect(lines.contains("background-blur = 0"))
    }

    @Test func opaqueOrUnsetOpacityEmitsNoBackgroundPins() {
        // full opacity, unset opacity, and a blur with no translucency all render normally:
        // ghostty paints its own background (blur needs opacity < 1 to be visible).
        #expect(AppSettings(backgroundOpacity: 1).ghosttyConfigLines().isEmpty)
        #expect(AppSettings().ghosttyConfigLines().isEmpty)
        #expect(AppSettings(backgroundBlur: 40).ghosttyConfigLines().isEmpty)
    }

    @Test func notificationsEnabledRoundTripsAndIsNotAConfigLine() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(AppSettings(notificationsEnabled: false)))
        #expect(decoded.notificationsEnabled == false)
        // it's an app-level toggle, never a ghostty config key
        #expect(AppSettings(notificationsEnabled: false).ghosttyConfigLines().isEmpty)
    }
}
