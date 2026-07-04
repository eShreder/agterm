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

    // Nested containers — an outer horizontal split whose right side is a vertical stack. Real tmux
    // layouts nest arbitrarily; the flatten-and-scan walk must skip the container cell (39x24,41,0 —
    // three fields, no pane id) and keep document order, so the LEADING pane (keystroke routing) is %1.
    @Test func nestedContainerLayout() {
        let r = TmuxLayout.panes(in: "9f58,80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}")
        #expect(r.panes == [TmuxPaneID("%1"), TmuxPaneID("%2"), TmuxPaneID("%3")])
        #expect(r.hasSplit == true)
    }

    // Empty / garbage layout strings yield no panes and no split — the model's
    // `guard let leading = parsed.panes.first` path relies on this, so it must not trap.
    @Test func emptyAndMalformedLayouts() {
        let empty = TmuxLayout.panes(in: "")
        #expect(empty.panes.isEmpty)
        #expect(empty.hasSplit == false)
        let garbage = TmuxLayout.panes(in: "not-a-layout")
        #expect(garbage.panes.isEmpty)
        #expect(garbage.hasSplit == false)
    }
}
