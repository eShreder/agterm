public struct TmuxControlParser: Sendable {
    private var buffer: [UInt8] = []
    private var strippedDcsIntro = false
    private var block: Int?

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
        let text = String(decoding: line, as: UTF8.self)

        // Inside a %begin block, everything that is not the MATCHING %end/%error is body. Close ONLY on
        // the terminator whose command number equals this block's %begin number (field 2 of
        // `%end <ts> <num> <flags>`), as real -CC clients do — a `capture-pane` body line is arbitrary
        // pane content and can itself start with "%end "/"%error " (or "%window-close", "%exit"). Matching
        // the number stops such a line from terminating the block early and spilling the captured tail
        // back to the top level, where a "%window-close @0"/"%exit" body line would be misclassified as a
        // real notification and spuriously close a session / tear the connection down. A malformed %begin
        // (num < 0, unparseable) falls back to closing on ANY terminator so a corrupt stream can't wedge.
        if let num = block {
            if text.hasPrefix("%end ") || text.hasPrefix("%error ") {
                let matches = Self.field(text, 2).flatMap { Int($0) } == num
                if matches || num < 0 {
                    block = nil
                    return .blockEnd(num: num, error: text.hasPrefix("%error "))
                }
            }
            return .blockLine(num: num, text: text)
        }
        guard line.first == 0x25 else { return nil }           // non-% outside a block: ignore
        if text.hasPrefix("%begin ") {
            let num = Self.field(text, 2).flatMap { Int($0) } ?? -1
            block = num
            return .blockBegin(num: num)
        }
        return classifyNotification(text, rawLine: line)
    }

    /// The 0-based whitespace-separated field `n` of a control line.
    static func field(_ text: String, _ n: Int) -> String? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        return n < parts.count ? String(parts[n]) : nil
    }

    /// Everything from field `n` onward, space-joined — for names that may contain spaces.
    static func rest(_ text: String, from n: Int) -> String {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        return n < parts.count ? parts[n...].joined(separator: " ") : ""
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
        if text.hasPrefix("%window-add ") { return .windowAdd(TmuxWindowID(Self.field(text, 1) ?? "")) }
        if text.hasPrefix("%window-close ") { return .windowClose(TmuxWindowID(Self.field(text, 1) ?? ""), unlinked: false) }
        if text.hasPrefix("%unlinked-window-close ") { return .windowClose(TmuxWindowID(Self.field(text, 1) ?? ""), unlinked: true) }
        if text.hasPrefix("%window-renamed ") {
            let id = TmuxWindowID(Self.field(text, 1) ?? "")
            let name = Self.rest(text, from: 2)
            return .windowRenamed(id, name: name)
        }
        if text.hasPrefix("%window-pane-changed ") {
            return .windowPaneChanged(window: TmuxWindowID(Self.field(text, 1) ?? ""),
                                      pane: TmuxPaneID(Self.field(text, 2) ?? ""))
        }
        if text.hasPrefix("%layout-change ") {
            return .layoutChange(window: TmuxWindowID(Self.field(text, 1) ?? ""),
                                 layout: Self.field(text, 2) ?? "")
        }
        if text.hasPrefix("%session-changed ") {
            return .sessionChanged(TmuxSessionID(Self.field(text, 1) ?? ""), name: Self.rest(text, from: 2))
        }
        if text.hasPrefix("%session-window-changed ") {
            return .sessionWindowChanged(TmuxSessionID(Self.field(text, 1) ?? ""),
                                         window: TmuxWindowID(Self.field(text, 2) ?? ""))
        }
        if text == "%sessions-changed" { return .sessionsChanged }
        if text.hasPrefix("%exit") {
            let reason = Self.rest(text, from: 1)
            return .exit(reason: reason.isEmpty ? nil : reason)
        }
        return .unknown(text)
    }

    static func decodeOutput(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        func isOctal(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }   // '0'..'7'
        while i < bytes.count {
            let b = bytes[i]
            // A valid tmux octal escape is `\` + 3 octal digits with value <= 0o377 (255),
            // so the first digit is 0-3. Requiring that (and computing in Int) keeps a
            // malformed `\4xx` from a corrupt/non-tmux stream from overflowing UInt8 and
            // trapping — it falls through to a literal backslash instead.
            if b == 0x5C, i + 3 < bytes.count,
               bytes[i+1] >= 0x30, bytes[i+1] <= 0x33, isOctal(bytes[i+2]), isOctal(bytes[i+3]) {
                let v = Int(bytes[i+1] - 0x30) * 64 + Int(bytes[i+2] - 0x30) * 8 + Int(bytes[i+3] - 0x30)
                out.append(UInt8(v)); i += 4
            } else {
                out.append(b); i += 1
            }
        }
        return out
    }
}
