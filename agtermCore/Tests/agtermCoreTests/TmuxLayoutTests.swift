import Testing
@testable import agtermCore

struct TmuxLayoutTests {
    // Single pane: "b25d,80x24,0,0,0" — the trailing ,0 is pane id 0 → %0. No split.
    @Test func singlePaneLayout() {
        let r = TmuxLayout.panes(in: "b25d,80x24,0,0,0")
        #expect(r.panes == [TmuxPaneID("%0")])
        #expect(r.hasSplit == false)
    }

    // Horizontal split: "{...}" with two pane cells → %0 and %2, hasSplit true.
    @Test func horizontalSplitLayout() {
        let r = TmuxLayout.panes(in: "0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2}")
        #expect(r.panes == [TmuxPaneID("%0"), TmuxPaneID("%2")])
        #expect(r.hasSplit == true)
    }

    // Vertical split uses "[...]".
    @Test func verticalSplitLayout() {
        let r = TmuxLayout.panes(in: "abcd,80x24,0,0[80x12,0,0,3,80x11,0,13,4]")
        #expect(r.panes == [TmuxPaneID("%3"), TmuxPaneID("%4")])
        #expect(r.hasSplit == true)
    }
}
