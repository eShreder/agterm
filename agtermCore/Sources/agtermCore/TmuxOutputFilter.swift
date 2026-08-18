/// Strips terminal QUERIES and keyboard-protocol switches out of a tmux `%output` stream, so a mirrored
/// surface renders but never answers.
///
/// In `-CC` mode tmux is the terminal of record for pane programs: it answers DA/DSR/OSC-color queries
/// itself, host-side and instantly. The same bytes travel on to the mirrored surface, which is an honest
/// terminal and answers too — one ssh round-trip later, after the asking program consumed tmux's reply and
/// moved on, so the late answer lands on whatever reads the pane now (usually the shell prompt: the
/// `62;22;52c` tail after quitting nvim). A keyboard-protocol switch is worse than late: it leaves the
/// surface encoding keys in a protocol the remote never enabled and whose disable never arrives, which is
/// the stuck `65;2u` capitals that only `reset` clears.
///
/// A program whose query tmux does not answer simply times out — the unsupported-capability path every TUI
/// already handles. The trade-off is no Ctrl+Shift disambiguation and no XTGETTCAP probing inside tmux
/// windows.
///
/// Sequences straddle `%output` chunks, so this is a streaming machine per pane rather than a per-chunk
/// match: an ambiguous tail is held back and resolved by the next chunk. `%output` interleaves panes, so
/// state is keyed by pane even though only a window's leading pane is bound today.
public struct TmuxOutputFilter: Sendable {
    public struct Result: Sendable, Equatable {
        public var bytes: [UInt8]
        /// One label per dropped sequence, escaped for the log.
        public var dropped: [String]
    }

    private var streams: [TmuxPaneID: Stream] = [:]

    public init() {}

    public mutating func filter(pane: TmuxPaneID, _ bytes: [UInt8]) -> Result {
        streams[pane, default: Stream()].feed(bytes)
    }

    public mutating func forget(pane: TmuxPaneID) { streams[pane] = nil }

    /// One pane's machine. `held` is the candidate withheld from output; it is either flushed verbatim or
    /// dropped whole, so a sequence this filter does not recognize costs nothing but latency.
    private struct Stream: Sendable {
        private enum State { case ground, escape, csi, osc, dcs, dcsDiscard }

        private static let esc: UInt8 = 0x1B
        private static let bel: UInt8 = 0x07
        /// Every candidate is short; the bound only stops a corrupt stream from buffering without end.
        private static let maxHeld = 4096

        private var state: State = .ground
        private var held: [UInt8] = []
        /// In `osc`/`dcsDiscard`: the previous byte was ESC, so this one may complete an ST terminator.
        private var sawEscape = false

        mutating func feed(_ bytes: [UInt8]) -> Result {
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count)
            var dropped: [String] = []
            for byte in bytes { step(byte, &out, &dropped) }
            return Result(bytes: out, dropped: dropped)
        }

        private mutating func step(_ byte: UInt8, _ out: inout [UInt8], _ dropped: inout [String]) {
            switch state {
            case .ground:
                if byte == Self.esc { held = [byte]; state = .escape } else { out.append(byte) }
            case .escape:
                switch byte {
                case 0x5B: held.append(byte); state = .csi           // [
                case 0x5D: held.append(byte); state = .osc           // ]
                case 0x50: held.append(byte); state = .dcs           // P
                case Self.esc: out += held; held = [byte]            // stray ESC; this one may still open
                default: held.append(byte); flush(&out)
                }
            case .csi: stepCSI(byte, &out, &dropped)
            case .osc: stepOSC(byte, &out, &dropped)
            case .dcs: stepDCS(byte, &out, &dropped)
            case .dcsDiscard: stepDCSDiscard(byte)
            }
        }

        private mutating func stepCSI(_ byte: UInt8, _ out: inout [UInt8], _ dropped: inout [String]) {
            if byte == Self.esc { restart(byte, &out); return }
            held.append(byte)
            if (0x20...0x3F).contains(byte) { boundHeld(&out); return }   // parameter / intermediate
            guard (0x40...0x7E).contains(byte) else { flush(&out); return }
            if let kind = TmuxOutputFilter.csiKind(held) {
                dropped.append("\(kind) \(TmuxOutputFilter.escaped(held))")
                discard()
            } else {
                flush(&out)
            }
        }

        private mutating func stepOSC(_ byte: UInt8, _ out: inout [UInt8], _ dropped: inout [String]) {
            if sawEscape {
                held.append(byte)
                sawEscape = byte == Self.esc
                if byte == 0x5C { finishOSC(&out, &dropped) } else { boundHeld(&out) }   // ESC \ is ST
                return
            }
            held.append(byte)
            if byte == Self.esc { sawEscape = true; boundHeld(&out); return }
            if byte == Self.bel { finishOSC(&out, &dropped); return }
            // Bail out the moment the payload can no longer become a color query, so a title or a
            // clipboard write is not held back for its whole length.
            guard TmuxOutputFilter.oscCouldBeQuery(Array(held.dropFirst(2))) else { flush(&out); return }
            boundHeld(&out)
        }

        private mutating func finishOSC(_ out: inout [UInt8], _ dropped: inout [String]) {
            let terminator = held.last == Self.bel ? 1 : 2
            guard held.count >= 2 + terminator else { flush(&out); return }
            let payload = Array(held[2..<(held.count - terminator)])
            guard let kind = TmuxOutputFilter.oscQueryKind(payload) else { flush(&out); return }
            dropped.append("\(kind) \(TmuxOutputFilter.escaped(held))")
            discard()
        }

        private mutating func stepDCS(_ byte: UInt8, _ out: inout [UInt8], _ dropped: inout [String]) {
            if byte == Self.esc { restart(byte, &out); return }
            held.append(byte)
            if (0x20...0x3F).contains(byte) { boundHeld(&out); return }
            guard (0x40...0x7E).contains(byte) else { flush(&out); return }
            let intro = held.dropFirst(2)
            // `+q` is XTGETTCAP and `$q` DECRQSS; a sixel intro also ends in `q` but carries neither.
            guard byte == 0x71, intro.contains(0x2B) || intro.contains(0x24) else { flush(&out); return }
            dropped.append("\(intro.contains(0x2B) ? "XTGETTCAP" : "DECRQSS") \(TmuxOutputFilter.escaped(held))…")
            discard()
            state = .dcsDiscard   // identified: swallow the body streamingly, no buffer needed
        }

        private mutating func stepDCSDiscard(_ byte: UInt8) {
            if sawEscape {
                sawEscape = byte == Self.esc
                if byte == 0x5C { state = .ground }
                return
            }
            if byte == Self.esc { sawEscape = true; return }
            if byte == Self.bel { state = .ground }
        }

        /// An ESC where the current candidate cannot contain one: emit the candidate and open a new one.
        private mutating func restart(_ byte: UInt8, _ out: inout [UInt8]) {
            out += held
            held = [byte]
            state = .escape
            sawEscape = false
        }

        private mutating func boundHeld(_ out: inout [UInt8]) {
            if held.count > Self.maxHeld { flush(&out) }
        }

        private mutating func flush(_ out: inout [UInt8]) {
            out += held
            discard()
        }

        private mutating func discard() {
            held.removeAll(keepingCapacity: true)
            state = .ground
            sawEscape = false
        }
    }

    /// The query or keyboard-switch this complete CSI is, or nil to pass it through. Splits the body into
    /// private prefix, parameters and intermediates so `CSI ? … m` (XTQMODKEYS) is told apart from plain
    /// SGR, and `CSI < u` (kitty pop) from `CSI u` (SCORC).
    static func csiKind(_ sequence: [UInt8]) -> String? {
        let body = Array(sequence.dropFirst(2))
        guard let final = body.last else { return nil }
        var i = 0
        var prefix: UInt8 = 0
        if let first = body.first, (0x3C...0x3F).contains(first) { prefix = first; i = 1 }
        let paramsStart = i
        while i < body.count - 1, (0x30...0x3B).contains(body[i]) { i += 1 }
        let params = String(decoding: body[paramsStart..<i], as: UTF8.self)
        let intermediateStart = i
        while i < body.count - 1, (0x20...0x2F).contains(body[i]) { i += 1 }
        let intermediates = String(decoding: body[intermediateStart..<i], as: UTF8.self)
        guard i == body.count - 1 else { return nil }
        let bare = params.isEmpty || params == "0"
        switch (prefix, intermediates, final) {
        case (0x00, "", 0x63): return bare ? "DA1" : nil
        case (0x3E, "", 0x63): return bare ? "DA2" : nil
        case (0x3D, "", 0x63): return bare ? "DA3" : nil
        case (0x00, "", 0x6E): return params == "5" || params == "6" ? "DSR" : nil
        case (0x3F, "", 0x6E): return "DEC-DSR"
        case (0x00, "$", 0x70), (0x3F, "$", 0x70): return "DECRQM"
        case (0x3E, "", 0x71): return bare ? "XTVERSION" : nil
        case (0x3F, "", 0x75): return params.isEmpty ? "kitty-query" : nil
        case (0x3F, "", 0x6D): return "XTQMODKEYS"
        case (0x3E, "", 0x75): return "kitty-push"
        case (0x3C, "", 0x75): return "kitty-pop"
        case (0x3D, "", 0x75): return "kitty-set"
        case (0x3E, "", 0x6D): return "XTMODKEYS"
        default: return nil
        }
    }

    /// Whether an OSC payload so far is still a prefix of a color QUERY (`4;<n>;?`, `10|11|12;?`).
    /// False sends it through untouched, which is where every set form and every other OSC leaves.
    static func oscCouldBeQuery(_ payload: [UInt8]) -> Bool {
        var i = 0
        while i < payload.count, (0x30...0x39).contains(payload[i]) { i += 1 }
        guard i > 0, i <= 2 else { return false }
        if i == payload.count { return true }
        guard payload[i] == 0x3B else { return false }
        let number = String(decoding: payload[..<i], as: UTF8.self)
        i += 1
        switch number {
        case "10", "11", "12":
            guard i < payload.count else { return true }
            return payload[i] == 0x3F && i + 1 == payload.count
        case "4":
            var j = i
            while j < payload.count, (0x30...0x39).contains(payload[j]) { j += 1 }
            guard j > i else { return j == payload.count }
            guard j < payload.count else { return true }
            guard payload[j] == 0x3B else { return false }
            j += 1
            guard j < payload.count else { return true }
            return payload[j] == 0x3F && j + 1 == payload.count
        default:
            return false
        }
    }

    /// The color query a complete OSC payload is, or nil to pass it through.
    static func oscQueryKind(_ payload: [UInt8]) -> String? {
        let text = String(decoding: payload, as: UTF8.self)
        switch text {
        case "10;?": return "OSC10-query"
        case "11;?": return "OSC11-query"
        case "12;?": return "OSC12-query"
        default: break
        }
        guard text.hasPrefix("4;"), text.hasSuffix(";?") else { return nil }
        let index = text.dropFirst(2).dropLast(2)
        guard !index.isEmpty, index.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return "OSC4-query"
    }

    private static let hexDigits = Array("0123456789abcdef")

    static func escaped(_ bytes: [UInt8]) -> String {
        var text = ""
        for byte in bytes {
            switch byte {
            case 0x1B: text += "^["
            case 0x07: text += "^G"
            case 0x20...0x7E: text.append(Character(UnicodeScalar(byte)))
            default: text += "\\x\(hexDigits[Int(byte >> 4)])\(hexDigits[Int(byte & 0x0F)])"
            }
        }
        return text
    }
}
