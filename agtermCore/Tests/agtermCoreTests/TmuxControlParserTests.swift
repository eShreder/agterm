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
}
