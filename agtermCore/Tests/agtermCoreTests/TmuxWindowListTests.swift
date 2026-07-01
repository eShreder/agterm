import Testing
@testable import agtermCore

struct TmuxWindowListTests {
    @Test func parsesTwoWindowsWithNamesAndIds() {
        let rows = [
            "0: zsh- (1 panes) [80x24] [layout b25d,80x24,0,0,0] @0",
            "1: second* (1 panes) [80x24] [layout b25e,80x24,0,0,1] @1 (active)",
        ]
        let result = TmuxWindowList.parse(rows)
        #expect(result.count == 2)
        #expect(result[0].id == TmuxWindowID("@0"))
        #expect(result[0].name == "zsh")
        #expect(result[1].id == TmuxWindowID("@1"))
        #expect(result[1].name == "second")
    }

    @Test func ignoresRowsWithoutAWindowId() {
        #expect(TmuxWindowList.parse(["garbage line", ""]).isEmpty)
    }

    @Test func handlesMultiDigitIndexAndPlainName() {
        let rows = ["12: api (1 panes) [80x24] [layout abcd,80x24,0,0,5] @7"]
        let r = TmuxWindowList.parse(rows)
        #expect(r.count == 1)
        #expect(r[0].id == TmuxWindowID("@7"))
        #expect(r[0].name == "api")
    }
}
