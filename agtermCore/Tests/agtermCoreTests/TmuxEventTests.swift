import Testing
@testable import agtermCore

struct TmuxEventTests {
    @Test func eventsAreEquatable() {
        #expect(TmuxEvent.windowAdd(TmuxWindowID("@0")) == .windowAdd(TmuxWindowID("@0")))
        #expect(TmuxEvent.windowAdd(TmuxWindowID("@0")) != .windowAdd(TmuxWindowID("@1")))
        #expect(TmuxEvent.output(pane: TmuxPaneID("%0"), bytes: [0x68, 0x69])
                == .output(pane: TmuxPaneID("%0"), bytes: [0x68, 0x69]))
    }
}
