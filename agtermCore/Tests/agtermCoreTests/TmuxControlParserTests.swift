import Testing
@testable import agtermCore

struct TmuxControlParserTests {
    // Bytes are only emitted once a full line (\n) arrives; \r is stripped; the
    // leading DCS intro \u{1b}P1000p is dropped.
    @Test func framesLinesAcrossChunksAndStripsDcsIntro() {
        var p = TmuxControlParser()
        // Split the first line mid-token across two feeds.
        let first = Array("\u{1b}P1000p%output %0 hi".utf8)
        #expect(p.feed(first).isEmpty)                 // no newline yet
        let rest = Array("\r\n".utf8)
        let events = p.feed(rest)
        #expect(events == [.output(pane: TmuxPaneID("%0"), bytes: Array("hi".utf8))])
    }

    // Real captured %output line: escaped control bytes decode to their byte values.
    @Test func decodesOctalEscapedOutput() {
        var p = TmuxControlParser()
        let line = Array("%output %0 e\\010echocc\\033[?2004l\\015\\015\\012\r\n".utf8)
        let events = p.feed(line)
        let expected: [UInt8] = Array("e".utf8) + [0x08] + Array("echocc".utf8)
            + [0x1B] + Array("[?2004l".utf8) + [0x0D, 0x0D, 0x0A]
        #expect(events == [.output(pane: TmuxPaneID("%0"), bytes: expected)])
    }

    // A literal backslash is octal-escaped as \134, not \\.
    @Test func decodesEscapedBackslash() {
        var p = TmuxControlParser()
        let events = p.feed(Array("%output %0 \\134\\134\r\n".utf8))
        #expect(events == [.output(pane: TmuxPaneID("%0"), bytes: [0x5C, 0x5C])])
    }

    // Raw high/UTF-8 bytes pass through unescaped.
    @Test func passesRawHighBytesThrough() {
        var p = TmuxControlParser()
        var line = Array("%output %0 ".utf8); line += [0xC3, 0xA9]; line += Array("\r\n".utf8) // "é"
        let events = p.feed(line)
        #expect(events == [.output(pane: TmuxPaneID("%0"), bytes: [0xC3, 0xA9])])
    }

    @Test func classifiesStructuralNotifications() {
        var p = TmuxControlParser()
        let feed = Array("""
        %session-changed $0 cap\r
        %window-add @2\r
        %window-renamed @0 renamed0\r
        %window-pane-changed @0 %2\r
        %session-window-changed $0 @0\r
        %unlinked-window-close @1\r
        %sessions-changed\r
        %exit\r

        """.utf8)   // trailing blank line ensures the final \n
        let e = p.feed(feed)
        #expect(e == [
            .sessionChanged(TmuxSessionID("$0"), name: "cap"),
            .windowAdd(TmuxWindowID("@2")),
            .windowRenamed(TmuxWindowID("@0"), name: "renamed0"),
            .windowPaneChanged(window: TmuxWindowID("@0"), pane: TmuxPaneID("%2")),
            .sessionWindowChanged(TmuxSessionID("$0"), window: TmuxWindowID("@0")),
            .windowClose(TmuxWindowID("@1"), unlinked: true),
            .sessionsChanged,
            .exit(reason: nil),
        ])
    }

    @Test func parsesLayoutChangeKeepingLayoutString() {
        var p = TmuxControlParser()
        let line = Array("%layout-change @0 0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2} 0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2} -\r\n".utf8)
        #expect(p.feed(line) == [.layoutChange(window: TmuxWindowID("@0"),
                                               layout: "0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2}")])
    }

    @Test func tracksBeginEndBlockBodyLines() {
        var p = TmuxControlParser()
        let feed = Array("""
        %begin 1782913918 294 1\r
        0: zsh- (1 panes) [80x24] [layout b25d,80x24,0,0,0] @0\r
        1: second* (1 panes) [80x24] [layout b25e,80x24,0,0,1] @1 (active)\r
        %end 1782913918 294 1\r

        """.utf8)
        #expect(p.feed(feed) == [
            .blockBegin(num: 294),
            .blockLine(num: 294, text: "0: zsh- (1 panes) [80x24] [layout b25d,80x24,0,0,0] @0"),
            .blockLine(num: 294, text: "1: second* (1 panes) [80x24] [layout b25e,80x24,0,0,1] @1 (active)"),
            .blockEnd(num: 294, error: false),
        ])
    }

    @Test func unknownPercentLineIsIgnoredGracefully() {
        var p = TmuxControlParser()
        #expect(p.feed(Array("%some-future-thing x y\r\n".utf8)) == [.unknown("%some-future-thing x y")])
    }
}
