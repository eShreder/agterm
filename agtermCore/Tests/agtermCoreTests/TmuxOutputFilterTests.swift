import Testing
@testable import agtermCore

struct TmuxOutputFilterTests {
    private static let pane = TmuxPaneID("%0")

    private func filtered(_ chunks: [String]) -> [UInt8] {
        var f = TmuxOutputFilter()
        var out: [UInt8] = []
        for chunk in chunks { out += f.filter(pane: Self.pane, Array(chunk.utf8)).bytes }
        return out
    }

    private func filtered(_ text: String) -> [UInt8] { filtered([text]) }

    @Test(arguments: [
        "\u{1b}[c", "\u{1b}[0c",                                  // DA1
        "\u{1b}[>c", "\u{1b}[>0c",                                // DA2
        "\u{1b}[=c",                                              // DA3
        "\u{1b}[5n", "\u{1b}[6n",                                 // DSR / CPR
        "\u{1b}[?6n", "\u{1b}[?15n",                              // DEC DSR
        "\u{1b}[2$p", "\u{1b}[?2026$p",                           // DECRQM
        "\u{1b}[>q", "\u{1b}[>0q",                                // XTVERSION
        "\u{1b}[?u",                                              // kitty keyboard query
        "\u{1b}[?4m",                                             // XTQMODKEYS
        "\u{1b}P+q544e\u{1b}\\",                                  // XTGETTCAP
        "\u{1b}P$qm\u{1b}\\",                                     // DECRQSS
        "\u{1b}]4;1;?\u{7}",                                      // palette query
        "\u{1b}]10;?\u{7}", "\u{1b}]11;?\u{1b}\\", "\u{1b}]12;?\u{7}",
    ])
    func dropsQueriesKeepingSurroundingBytes(_ query: String) {
        #expect(filtered("A" + query + "B") == Array("AB".utf8))
    }

    @Test(arguments: [
        "\u{1b}[>u", "\u{1b}[>1u",                                // kitty push
        "\u{1b}[<u", "\u{1b}[<1u",                                // kitty pop
        "\u{1b}[=1;1u",                                           // kitty set
        "\u{1b}[>4m", "\u{1b}[>4;2m",                             // XTMODKEYS
    ])
    func dropsKeyboardProtocolSwitches(_ sequence: String) {
        #expect(filtered("A" + sequence + "B") == Array("AB".utf8))
    }

    @Test(arguments: [
        "\u{1b}[u", "\u{1b}[s",                                   // SCORC / SCOSC, not kitty
        "\u{1b}[0m", "\u{1b}[1;2m", "\u{1b}[38;5;196m",           // SGR
        "\u{1b}[?2004h", "\u{1b}[?1049h", "\u{1b}[?1006h", "\u{1b}[?2026h", "\u{1b}[?1004l",
        "\u{1b}[0n", "\u{1b}[?1;2;4c",                            // replies, not queries
        "\u{1b}]11;rgb:1e1e/1e1e/1e1e\u{7}",                      // OSC 11 set form
        "\u{1b}]0;title\u{7}", "\u{1b}]2;title\u{1b}\\",
        "\u{1b}]52;c;YWJj\u{7}", "\u{1b}]133;A\u{7}", "\u{1b}]8;;https://x\u{7}",
    ])
    func preservesEverythingElseByteForByte(_ sequence: String) {
        #expect(filtered("A" + sequence + "B") == Array(("A" + sequence + "B").utf8))
    }

    @Test func filtersSequencesSplitAtEveryChunkBoundary() {
        let sequences = ["\u{1b}[c", "\u{1b}[>0c", "\u{1b}[?6n", "\u{1b}[?2026$p",
                         "\u{1b}[>1u", "\u{1b}]11;?\u{1b}\\", "\u{1b}P+q544e\u{1b}\\"]
        for sequence in sequences {
            let bytes = Array(("A" + sequence + "B").utf8)
            for split in 0...bytes.count {
                var f = TmuxOutputFilter()
                var out = f.filter(pane: Self.pane, Array(bytes[..<split])).bytes
                out += f.filter(pane: Self.pane, Array(bytes[split...])).bytes
                #expect(out == Array("AB".utf8), "split \(split) of \(sequence.debugDescription)")
            }
        }
    }

    @Test func panesFilterIndependently() {
        var f = TmuxOutputFilter()
        let first = TmuxPaneID("%0"), second = TmuxPaneID("%1")
        var outFirst = f.filter(pane: first, Array("x\u{1b}[".utf8)).bytes
        var outSecond = f.filter(pane: second, Array("y\u{1b}[?20".utf8)).bytes
        outFirst += f.filter(pane: first, Array("cz".utf8)).bytes
        outSecond += f.filter(pane: second, Array("04h".utf8)).bytes
        #expect(outFirst == Array("xz".utf8))
        #expect(outSecond == Array("y\u{1b}[?2004h".utf8))
    }

    @Test func swallowsXtgettcapSpanningThreeChunks() {
        #expect(filtered(["A\u{1b}P+q", "544e;726762", "\u{1b}\\B"]) == Array("AB".utf8))
    }

    @Test func reportsEachDroppedSequenceForLogging() {
        var f = TmuxOutputFilter()
        let result = f.filter(pane: Self.pane, Array("a\u{1b}[cb\u{1b}[>1u".utf8))
        #expect(result.bytes == Array("ab".utf8))
        #expect(result.dropped == ["DA1 ^[[c", "kitty-push ^[[>1u"])
    }

    @Test func flushesAnOverlongCandidateUnchanged() {
        let overlong = "\u{1b}[" + String(repeating: "1;", count: 4096) + "m"
        #expect(filtered(overlong) == Array(overlong.utf8))
    }

    @Test func holdsAnIncompleteCandidateUntilTheNextChunk() {
        var f = TmuxOutputFilter()
        #expect(f.filter(pane: Self.pane, Array("hi\u{1b}[".utf8)).bytes == Array("hi".utf8))
        #expect(f.filter(pane: Self.pane, Array("2J".utf8)).bytes == Array("\u{1b}[2J".utf8))
    }

    @Test func passesAStrayEscapeAndStillFiltersTheNextSequence() {
        #expect(filtered("\u{1b}\u{1b}[cX") == Array("\u{1b}X".utf8))
    }

    @Test func forgettingAPaneDropsItsHeldPrefix() {
        var f = TmuxOutputFilter()
        _ = f.filter(pane: Self.pane, Array("a\u{1b}[".utf8))
        f.forget(pane: Self.pane)
        #expect(f.filter(pane: Self.pane, Array("c".utf8)).bytes == Array("c".utf8))
    }
}
