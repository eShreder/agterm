public struct TmuxControlParser: Sendable {
    private var buffer: [UInt8] = []
    private var strippedDcsIntro = false

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [TmuxEvent] {
        buffer += bytes
        var events: [TmuxEvent] = []
        while let nl = buffer.firstIndex(of: 0x0A) {          // 0x0A == \n
            var line = Array(buffer[..<nl])
            buffer.removeSubrange(...nl)
            if line.last == 0x0D { line.removeLast() }        // strip \r
            if let event = classify(line) { events.append(event) }
        }
        return events
    }

    private mutating func classify(_ rawLine: [UInt8]) -> TmuxEvent? {
        var line = rawLine
        if !strippedDcsIntro {
            let dcs = Array("\u{1b}P1000p".utf8)
            if line.starts(with: dcs) { line.removeFirst(dcs.count) }
            strippedDcsIntro = true
        }
        // Drop a trailing DCS terminator (\u{1b}\\) if a line is exactly that.
        if line == Array("\u{1b}\\".utf8) { return nil }
        guard line.first == 0x25 else { return nil }          // 0x25 == '%'; block-body handling comes in Task 3
        let text = String(decoding: line, as: UTF8.self)
        return classifyNotification(text, rawLine: line)
    }

    private func classifyNotification(_ text: String, rawLine: [UInt8]) -> TmuxEvent? {
        // "%output %<pane> <data>" — data must be taken from RAW bytes (it can contain
        // non-UTF8 after decode), not the decoded String.
        if text.hasPrefix("%output ") {
            // rawLine = "%output %<pane> <data...>"; split on the first two spaces.
            guard let sp1 = rawLine.firstIndex(of: 0x20) else { return .unknown(text) }
            let afterCmd = rawLine[(sp1 + 1)...]
            guard let sp2rel = afterCmd.firstIndex(of: 0x20) else { return .unknown(text) }
            let paneBytes = Array(afterCmd[..<sp2rel])
            let dataBytes = Array(afterCmd[(sp2rel + 1)...])
            let pane = TmuxPaneID(String(decoding: paneBytes, as: UTF8.self))
            return .output(pane: pane, bytes: Self.decodeOutput(dataBytes))
        }
        return .unknown(text)                                  // more cases in Task 2b/3
    }

    static func decodeOutput(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        func isOctal(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }   // '0'..'7'
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x5C, i + 3 < bytes.count, isOctal(bytes[i+1]), isOctal(bytes[i+2]), isOctal(bytes[i+3]) {
                let v = (bytes[i+1] - 0x30) * 64 + (bytes[i+2] - 0x30) * 8 + (bytes[i+3] - 0x30)
                out.append(v); i += 4
            } else {
                out.append(b); i += 1
            }
        }
        return out
    }
}
