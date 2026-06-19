import Foundation
import Testing
@testable import agtCore

struct NotificationsTests {
    @Test func identityRoundTripsForEveryPane() {
        let id = UUID()
        for pane in PaneRole.allCases {
            let identity = TerminalNotification.identity(sessionID: id, pane: pane)
            let parsed = TerminalNotification.parseIdentity(identity)
            #expect(parsed?.sessionID == id)
            #expect(parsed?.pane == pane)
        }
    }

    @Test func identityFormatIsSessionColonRole() {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        #expect(TerminalNotification.identity(sessionID: id, pane: .split) == "11111111-1111-1111-1111-111111111111:split")
    }

    @Test func parseRejectsMalformed() {
        #expect(TerminalNotification.parseIdentity("not-a-uuid:main") == nil)
        #expect(TerminalNotification.parseIdentity("\(UUID().uuidString):bogus") == nil)
        #expect(TerminalNotification.parseIdentity("no-colon") == nil)
        #expect(TerminalNotification.parseIdentity("") == nil)
    }

    @Test func shouldDeliverSuppressesOnlyTheFocusedActivePane() {
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: true, appActive: true) == false)
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: true, appActive: false) == true)
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: false, appActive: true) == true)
        #expect(TerminalNotification.shouldDeliver(firingIsFocused: false, appActive: false) == true)
    }
}
