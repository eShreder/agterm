import Testing
@testable import agtermCore

// The parser consumes `list-windows -F '#{window_id} #{window_layout} #{window_name}'` output:
// space-free id + layout first, free-form name last.
struct TmuxWindowListTests {
    @Test func parsesTwoWindowsWithNamesAndIds() {
        let rows = [
            "@0 b25d,80x24,0,0,0 zsh",
            "@1 b25e,80x24,0,0,1 second",
        ]
        let result = TmuxWindowList.parse(rows)
        #expect(result.count == 2)
        #expect(result[0].id == TmuxWindowID("@0"))
        #expect(result[0].name == "zsh")
        #expect(result[0].layout == "b25d,80x24,0,0,0")
        #expect(result[1].id == TmuxWindowID("@1"))
        #expect(result[1].name == "second")
        #expect(result[1].layout == "b25e,80x24,0,0,1")
    }

    @Test func ignoresRowsWithoutAWindowId() {
        #expect(TmuxWindowList.parse(["garbage line", ""]).isEmpty)
    }

    @Test func handlesMultiDigitId() {
        let rows = ["@7 abcd,80x24,0,0,5 api"]
        let r = TmuxWindowList.parse(rows)
        #expect(r.count == 1)
        #expect(r[0].id == TmuxWindowID("@7"))
        #expect(r[0].name == "api")
        #expect(r[0].layout == "abcd,80x24,0,0,5")
    }

    // tmux window names legitimately contain spaces; the name is the last field, so a multi-word name
    // must survive intact rather than truncating at the first space.
    @Test func preservesWindowNameWithSpaces() {
        let rows = ["@0 b25d,80x24,0,0,0 my project"]
        let r = TmuxWindowList.parse(rows)
        #expect(r.count == 1)
        #expect(r[0].name == "my project")
        #expect(r[0].layout == "b25d,80x24,0,0,0")
    }

    // A name containing " (" — which the old human-display parser truncated — must round-trip whole.
    @Test func preservesWindowNameWithParentheses() {
        let rows = ["@0 b25d,80x24,0,0,0 api (prod)"]
        let r = TmuxWindowList.parse(rows)
        #expect(r.count == 1)
        #expect(r[0].name == "api (prod)")
    }

    // A name ending in `*` or `-` — which the old flag-stripping parser mangled — must stay intact.
    @Test func keepsTrailingFlagLikeChars() {
        let rows = [
            "@0 b25d,80x24,0,0,0 build-",
            "@1 b25e,80x24,0,0,1 star*",
        ]
        let r = TmuxWindowList.parse(rows)
        #expect(r.count == 2)
        #expect(r[0].name == "build-")
        #expect(r[1].name == "star*")
    }

    // An empty window name yields a trailing space after the layout; the id/layout still parse.
    @Test func handlesEmptyName() {
        let rows = ["@0 b25d,80x24,0,0,0 "]
        let r = TmuxWindowList.parse(rows)
        #expect(r.count == 1)
        #expect(r[0].id == TmuxWindowID("@0"))
        #expect(r[0].name == "")
        #expect(r[0].layout == "b25d,80x24,0,0,0")
    }
}
