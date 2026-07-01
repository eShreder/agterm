# tmux `-CC` — Phase 2: host-free control-protocol parser + mapping (implementation plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the host-free tmux control-mode (`-CC`) protocol layer in `agtermCore` — a
`TmuxControlParser` that turns raw control-mode bytes into typed `TmuxEvent`s, a
`TmuxCommandEncoder` for outbound commands, a `TmuxLayout` helper, and a `TmuxSessionModel`
that turns events into agterm model `TmuxModelEffect`s — all fully unit-tested with
`swift test`, no libghostty / AppKit / process involvement. (Design spec:
`docs/superpowers/specs/2026-07-01-tmux-cc-native-design.md`, components 2 & 3.)

**Architecture:** Pure value types. The parser is a `struct` with a `mutating func feed([UInt8]) -> [TmuxEvent]`
that buffers bytes into `\n`-terminated lines and classifies each. The model is a `struct`
with `mutating func handle(TmuxEvent) -> [TmuxModelEffect]` holding the
window↔session and pane↔window↔session maps. Everything is `Sendable`; the app target
(Phase 3) drives the parser from a gateway subprocess and executes the effects.

**Tech Stack:** Swift 6 (strict concurrency `complete`), Swift Testing (`import Testing`,
`@Test`, `#expect`). `swift test` from `agtermCore/`. No dependencies beyond the standard
library.

## Global Constraints

- `agtermCore` must NOT import GhosttyKit, AppKit, Metal, or CoreGraphics. No `CGSize`/`CGPoint`/`CGRect`/`CGFloat`.
  All new types live in `Sources/agtermCore/`, tested in `Tests/agtermCoreTests/`.
- All new public types are `Sendable`. The parser and model are value types (`struct`) with
  `mutating` methods; do NOT make them `@MainActor` or `actor` (they are pure logic driven
  by the app target).
- Test style: Swift Testing — `import Testing` + `@testable import agtermCore`; a `struct XTests`
  with `@Test func name() { #expect(...) }`. One test file per source type. NO XCTest.
- One source file per type under `Sources/agtermCore/`, matching the existing convention
  (e.g. `ShellEscape.swift`, `Keybind.swift`).
- `make lint` (`swiftlint --strict`, zero findings) and `swift test` must pass after every task.
- The v1 scope is **no splits inside a tmux window**: each window maps to one leading pane /
  one surface. A window with a split layout is handled by taking the FIRST pane and emitting
  a diagnostic effect — never by modeling multiple panes.
- Protocol formats below are transcribed from a real tmux **3.7a** `-CC` session; the test
  fixtures are real captured lines. Preserve them byte-for-byte.

## Real protocol reference (tmux 3.7a `-CC`, captured)

Lines are CRLF (`\r\n`)-terminated. The whole session is wrapped in a DCS: it opens with
`\u{1b}P1000p` (immediately followed by the first line's text) and closes with `\u{1b}\\`
(ST) after `%exit`.

```
\u{1b}P1000p%begin 1782913917 289 0
%end 1782913917 289 0
%session-changed $0 cap
%begin 1782913918 294 1
0: zsh- (1 panes) [80x24] [layout b25d,80x24,0,0,0] @0
1: second* (1 panes) [80x24] [layout b25e,80x24,0,0,1] @1 (active)
%end 1782913918 294 1
%output %0 e\010echocc\033[?2004l\015\015\012
%window-add @2
%window-renamed @0 renamed0
%window-pane-changed @0 %2
%layout-change @0 0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2} 0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2} -
%session-window-changed $0 @0
%unlinked-window-close @1
%sessions-changed
%exit
\u{1b}\\
```

- **IDs carry sigils:** window `@N`, pane `%N`, session `$N`. Keep the sigil in the stored token.
- **`%output %<pane> <data>`** — `<data>` escapes bytes as `\` + exactly 3 octal digits
  (`\033`=ESC 0x1B, `\015`=CR, `\012`=LF, `\010`=BS, `\134`=backslash 0x5C). A literal
  backslash is `\134`, NOT `\\`. Bytes ≥ 0x80 (UTF-8) and printable ASCII pass through raw.
  Decode rule: on `\` followed by 3 octal digits, emit that byte; otherwise emit the byte as-is.
- **`%layout-change @<win> <layout> <visible-layout> <flags>`** — the layout string encodes
  panes; a `{...}` (horizontal `-h`) or `[...]` (vertical `-v`) group means MORE THAN ONE pane.
  Single pane: `b25d,80x24,0,0,0` (trailing `,0` is pane id 0 → `%0`). Split:
  `0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2}` (panes `%0` and `%2`).
- **`%begin <ts> <num> <flags>` … `%end <ts> <num> <flags>`** (or `%error <ts> <num> <flags>`):
  the lines between are the command's RESPONSE body (e.g. `list-windows` rows), not
  `%`-notifications. `<num>` correlates the response to the command that produced it.
- **`%window-close @<id>`** and **`%unlinked-window-close @<id>`** both signal a window closed
  (unlinked = the window was not linked to the attached session).

## File Structure

| File | Responsibility |
|---|---|
| `Sources/agtermCore/TmuxIDs.swift` | `TmuxWindowID` / `TmuxPaneID` / `TmuxSessionID` value types (Hashable, Sendable) |
| `Sources/agtermCore/TmuxEvent.swift` | `TmuxEvent` enum (parser output) |
| `Sources/agtermCore/TmuxControlParser.swift` | `TmuxControlParser` struct: byte framing + line classification + octal decode |
| `Sources/agtermCore/TmuxLayout.swift` | `TmuxLayout.panes(in:)` → ordered pane ids + `hasSplit` |
| `Sources/agtermCore/TmuxCommand.swift` | `TmuxCommand` enum + `TmuxCommandEncoder.encode` → control-mode command line |
| `Sources/agtermCore/TmuxSessionModel.swift` | `TmuxModelEffect` enum + `TmuxSessionModel` struct: events → effects + maps |
| Tests: `TmuxControlParserTests`, `TmuxLayoutTests`, `TmuxCommandTests`, `TmuxSessionModelTests` | one per type |

---

### Task 1: `TmuxIDs` + `TmuxEvent` types

Value types for the three sigil'd IDs and the parser's output enum. No logic — the shared
vocabulary the parser and model both use. Deliverable: the types compile and a trivial
equality test passes.

**Files:**
- Create: `Sources/agtermCore/TmuxIDs.swift`
- Create: `Sources/agtermCore/TmuxEvent.swift`
- Test: `Tests/agtermCoreTests/TmuxEventTests.swift`

**Interfaces:**
- Produces:
  - `public struct TmuxWindowID: Hashable, Sendable { public let raw: String; public init(_ raw: String) }` (raw includes the `@`, e.g. `"@0"`)
  - `public struct TmuxPaneID: Hashable, Sendable { public let raw: String; public init(_ raw: String) }` (e.g. `"%2"`)
  - `public struct TmuxSessionID: Hashable, Sendable { public let raw: String; public init(_ raw: String) }` (e.g. `"$0"`)
  - ```swift
    public enum TmuxEvent: Equatable, Sendable {
        case output(pane: TmuxPaneID, bytes: [UInt8])
        case windowAdd(TmuxWindowID)
        case windowClose(TmuxWindowID, unlinked: Bool)
        case windowRenamed(TmuxWindowID, name: String)
        case windowPaneChanged(window: TmuxWindowID, pane: TmuxPaneID)
        case layoutChange(window: TmuxWindowID, layout: String)
        case sessionChanged(TmuxSessionID, name: String)
        case sessionWindowChanged(TmuxSessionID, window: TmuxWindowID)
        case sessionsChanged
        case blockBegin(num: Int)
        case blockLine(num: Int, text: String)
        case blockEnd(num: Int, error: Bool)
        case exit(reason: String?)
        case unknown(String)
    }
    ```

- [ ] **Step 1: Write the types**

`TmuxIDs.swift`:
```swift
public struct TmuxWindowID: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct TmuxPaneID: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct TmuxSessionID: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}
```
`TmuxEvent.swift`: the enum exactly as in **Produces** above.

- [ ] **Step 2: Write the test**

`TmuxEventTests.swift`:
```swift
import Testing
@testable import agtermCore

struct TmuxEventTests {
    @Test func eventsAreEquatable() {
        #expect(TmuxEvent.windowAdd(TmuxWindowID("@0")) == .windowAdd(TmuxWindowID("@0")))
        #expect(TmuxEvent.windowAdd(TmuxWindowID("@0")) != .windowAdd(TmuxWindowID("@1")))
        #expect(TmuxEvent.output(pane: TmuxPaneID("%0"), bytes: [0x68, 0x69])
                == .output(pane: TmuxPaneID("%0"), bytes: [0x68, 0x69]))
    }
}
```

- [ ] **Step 3: Run the test — expect FAIL (types undefined)**

Run: `cd agtermCore && swift test --filter TmuxEventTests`
Expected: compile error / FAIL (types not yet defined) before you add the sources; PASS after.

- [ ] **Step 4: Run the test — expect PASS**

Run: `cd agtermCore && swift test --filter TmuxEventTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermCore/TmuxIDs.swift agtermCore/Sources/agtermCore/TmuxEvent.swift agtermCore/Tests/agtermCoreTests/TmuxEventTests.swift
git commit -m "agtermCore: tmux control-mode id + event value types"
```

---

### Task 2: `TmuxControlParser` — line framing + octal-decoded `%output`

The core data path: buffer bytes into CRLF lines (stripping a leading `\u{1b}P1000p` DCS
intro), and classify `%output` lines into `.output(pane, bytes)` with octal decoding.
Deliverable: chunked feeding reassembles lines, and real `%output` fixtures decode to exact
bytes.

**Files:**
- Create: `Sources/agtermCore/TmuxControlParser.swift`
- Test: `Tests/agtermCoreTests/TmuxControlParserTests.swift`

**Interfaces:**
- Consumes: `TmuxEvent`, `TmuxPaneID` (Task 1).
- Produces:
  - `public struct TmuxControlParser: Sendable { public init(); public mutating func feed(_ bytes: [UInt8]) -> [TmuxEvent] }`
  - `static func decodeOutput(_ bytes: [UInt8]) -> [UInt8]` (internal; octal `\NNN` → byte).

- [ ] **Step 1: Write the failing tests**

`TmuxControlParserTests.swift`:
```swift
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
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter TmuxControlParserTests`
Expected: FAIL (parser undefined).

- [ ] **Step 3: Implement the parser core**

`TmuxControlParser.swift`:
```swift
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
```
Note the bounds check `i + 3 < bytes.count`: when the escape is the last token, `i+3` must be
a valid index, i.e. `i+3 <= count-1`. If the octal test fails, the `\` is emitted literally —
tmux never emits a bare trailing `\`, so this is safe.

- [ ] **Step 4: Run — expect PASS**

Run: `cd agtermCore && swift test --filter TmuxControlParserTests`
Expected: all 4 PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermCore/TmuxControlParser.swift agtermCore/Tests/agtermCoreTests/TmuxControlParserTests.swift
git commit -m "agtermCore: tmux parser line framing + octal-decoded %output"
```

---

### Task 3: Parser — window/session notifications + `%begin`/`%end` blocks

Extend `classifyNotification` for the structural notifications and add `%begin`/`%end`/`%error`
block tracking (body lines between them become `.blockLine`). Deliverable: every notification
in the real transcript maps to the right event, and a `list-windows` block yields
begin/line/line/end.

**Files:**
- Modify: `Sources/agtermCore/TmuxControlParser.swift`
- Modify: `Tests/agtermCoreTests/TmuxControlParserTests.swift`

**Interfaces:**
- Consumes: everything from Task 2.
- Produces: `feed` now also emits `.windowAdd/.windowClose/.windowRenamed/.windowPaneChanged/.layoutChange/.sessionChanged/.sessionWindowChanged/.sessionsChanged/.blockBegin/.blockLine/.blockEnd/.exit`. Block state is internal.

- [ ] **Step 1: Write the failing tests**

Append to `TmuxControlParserTests.swift`:
```swift
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
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter TmuxControlParserTests`
Expected: the new tests FAIL (only `%output`/`%unknown` handled so far).

- [ ] **Step 3: Implement block tracking + notifications**

In `TmuxControlParser`, add block state and expand classification. Add a stored
`private var block: Int?` (the current `%begin` num). Rewrite `classify` so that when inside a
block, non-`%end`/`%error` lines become `.blockLine`:
```swift
    private mutating func classify(_ rawLine: [UInt8]) -> TmuxEvent? {
        var line = rawLine
        if !strippedDcsIntro {
            let dcs = Array("\u{1b}P1000p".utf8)
            if line.starts(with: dcs) { line.removeFirst(dcs.count) }
            strippedDcsIntro = true
        }
        if line == Array("\u{1b}\\".utf8) { return nil }
        let text = String(decoding: line, as: UTF8.self)

        // Inside a %begin block, everything that is not %end/%error is body.
        if let num = block {
            if text.hasPrefix("%end ") { block = nil; return .blockEnd(num: num, error: false) }
            if text.hasPrefix("%error ") { block = nil; return .blockEnd(num: num, error: true) }
            return .blockLine(num: num, text: text)
        }
        guard line.first == 0x25 else { return nil }   // non-% outside a block: ignore
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
```
Extend `classifyNotification` (keep the `%output` arm from Task 2) with:
```swift
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
```
Add the `rest` helper (everything from field `n` onward, space-joined — for names that may
contain spaces):
```swift
    static func rest(_ text: String, from n: Int) -> String {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        return n < parts.count ? parts[n...].joined(separator: " ") : ""
    }
```

- [ ] **Step 4: Run — expect PASS**

Run: `cd agtermCore && swift test --filter TmuxControlParserTests`
Expected: all parser tests PASS (Task 2 + Task 3).

- [ ] **Step 5: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermCore/TmuxControlParser.swift agtermCore/Tests/agtermCoreTests/TmuxControlParserTests.swift
git commit -m "agtermCore: tmux parser structural notifications + begin/end blocks"
```

---

### Task 4: `TmuxLayout` — pane extraction + split detection

Parse a tmux layout string into its ordered pane ids and a `hasSplit` flag, so the model can
apply the no-splits rule (leading pane) and learn pane↔window. Deliverable: single-pane and
split layouts parse to the right pane lists.

**Files:**
- Create: `Sources/agtermCore/TmuxLayout.swift`
- Test: `Tests/agtermCoreTests/TmuxLayoutTests.swift`

**Interfaces:**
- Consumes: `TmuxPaneID` (Task 1).
- Produces: `public enum TmuxLayout { public static func panes(in layout: String) -> (panes: [TmuxPaneID], hasSplit: Bool) }`

- [ ] **Step 1: Write the failing tests**

`TmuxLayoutTests.swift`:
```swift
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
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter TmuxLayoutTests`
Expected: FAIL (`TmuxLayout` undefined).

- [ ] **Step 3: Implement**

The layout body is (after the leading `checksum,`) a comma-separated cell:
`WxH,x,y[,paneId | {children} | [children]]`. A pane cell ends in `,<paneId>`; a container
cell ends in a `{...}` or `[...]` group holding child cells. Pane ids are the integers that
directly follow a `WxH,x,y,` triple (i.e. a number that is NOT followed by `x` and not the
start of a `WxH`). Simplest robust extraction: walk the string, and every time you see the
pattern `,<digits>` where the digits are immediately followed by `,`/`}`/`]`/end AND the token
before this number was an `x,y` pair (not a `WxH`), it is a pane id. Implement by tokenizing on
the split/group boundaries:
```swift
public enum TmuxLayout {
    public static func panes(in layout: String) -> (panes: [TmuxPaneID], hasSplit: Bool) {
        let hasSplit = layout.contains("{") || layout.contains("[")
        var panes: [TmuxPaneID] = []
        // Replace group delimiters with commas so cells become a flat comma list, then
        // walk cells of the form "WxH,x,y,pane". A pane id is the 4th field of each
        // 4-field cell; container cells have only 3 fields (WxH,x,y) before their group.
        let flattened = layout.map { ch -> Character in
            (ch == "{" || ch == "}" || ch == "[" || ch == "]") ? "," : ch
        }
        let fields = String(flattened).split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        // Scan for the "WxH" marker; the pane id (if any) is the 3rd field after it.
        var i = 0
        while i < fields.count {
            if fields[i].contains("x"), i + 3 < fields.count,
               Int(fields[i + 1]) != nil, Int(fields[i + 2]) != nil, Int(fields[i + 3]) != nil,
               !fields[i + 3].contains("x") {
                // WxH , x , y , paneId  — but only when field[i+3] is a pane id, i.e. the
                // NEXT field (i+4) is another WxH or end, not part of this cell.
                let next = i + 4 < fields.count ? fields[i + 4] : ""
                if next.isEmpty || next.contains("x") {
                    panes.append(TmuxPaneID("%\(fields[i + 3])"))
                }
            }
            i += 1
        }
        return (panes, hasSplit)
    }
}
```
Note: the leading `checksum` field (e.g. `b25d`) has no `x`, so it is skipped by the `contains("x")`
guard. Verify the three tests pin the behavior; adjust the scan if a fixture fails (the tests
are the spec).

- [ ] **Step 4: Run — expect PASS**

Run: `cd agtermCore && swift test --filter TmuxLayoutTests`
Expected: all 3 PASS. If the vertical-split fixture reveals an ordering/edge bug, fix the scan
until green — the fixtures are authoritative.

- [ ] **Step 5: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermCore/TmuxLayout.swift agtermCore/Tests/agtermCoreTests/TmuxLayoutTests.swift
git commit -m "agtermCore: tmux layout pane extraction + split detection"
```

---

### Task 5: `TmuxCommand` + encoder (outbound)

Encode the outbound control-mode commands agterm sends on the gateway's stdin. Deliverable:
each command encodes to the exact control-mode line.

**Files:**
- Create: `Sources/agtermCore/TmuxCommand.swift`
- Test: `Tests/agtermCoreTests/TmuxCommandTests.swift`

**Interfaces:**
- Consumes: `TmuxWindowID`, `TmuxPaneID` (Task 1).
- Produces:
  - ```swift
    public enum TmuxCommand: Equatable, Sendable {
        case newWindow(name: String?)
        case killWindow(TmuxWindowID)
        case renameWindow(TmuxWindowID, name: String)
        case sendKeys(pane: TmuxPaneID, bytes: [UInt8])
        case resizeClient(cols: Int, rows: Int)
        case detachClient
    }
    public enum TmuxCommandEncoder { public static func encode(_ command: TmuxCommand) -> String }
    ```
  - `encode` returns the command WITHOUT a trailing newline (the gateway appends `\n`).

- [ ] **Step 1: Write the failing tests**

`TmuxCommandTests.swift`:
```swift
import Testing
@testable import agtermCore

struct TmuxCommandTests {
    @Test func encodesWindowCommands() {
        #expect(TmuxCommandEncoder.encode(.newWindow(name: nil)) == "new-window")
        #expect(TmuxCommandEncoder.encode(.newWindow(name: "logs")) == "new-window -n logs")
        #expect(TmuxCommandEncoder.encode(.killWindow(TmuxWindowID("@1"))) == "kill-window -t @1")
        #expect(TmuxCommandEncoder.encode(.renameWindow(TmuxWindowID("@0"), name: "api")) == "rename-window -t @0 api")
    }

    @Test func encodesResizeAndDetach() {
        #expect(TmuxCommandEncoder.encode(.resizeClient(cols: 80, rows: 24)) == "refresh-client -C 80x24")
        #expect(TmuxCommandEncoder.encode(.detachClient) == "detach-client")
    }

    // send-keys uses -H (hex) so arbitrary bytes (control chars, UTF-8) round-trip safely.
    @Test func encodesSendKeysAsHex() {
        // "ab" + newline (0x0a) -> "61 62 0a"
        let cmd = TmuxCommand.sendKeys(pane: TmuxPaneID("%0"), bytes: [0x61, 0x62, 0x0A])
        #expect(TmuxCommandEncoder.encode(cmd) == "send-keys -t %0 -H 61 62 0a")
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter TmuxCommandTests`
Expected: FAIL.

- [ ] **Step 3: Implement**

`TmuxCommand.swift`:
```swift
public enum TmuxCommand: Equatable, Sendable {
    case newWindow(name: String?)
    case killWindow(TmuxWindowID)
    case renameWindow(TmuxWindowID, name: String)
    case sendKeys(pane: TmuxPaneID, bytes: [UInt8])
    case resizeClient(cols: Int, rows: Int)
    case detachClient
}

public enum TmuxCommandEncoder {
    public static func encode(_ command: TmuxCommand) -> String {
        switch command {
        case .newWindow(let name):
            return name.map { "new-window -n \($0)" } ?? "new-window"
        case .killWindow(let w):
            return "kill-window -t \(w.raw)"
        case .renameWindow(let w, let name):
            return "rename-window -t \(w.raw) \(name)"
        case .sendKeys(let pane, let bytes):
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            return "send-keys -t \(pane.raw) -H \(hex)"
        case .resizeClient(let cols, let rows):
            return "refresh-client -C \(cols)x\(rows)"
        case .detachClient:
            return "detach-client"
        }
    }
}
```
Note: `-H` takes space-separated hex byte values (tmux `send-keys -H`), which safely carries
control bytes and UTF-8 without shell/keyname ambiguity — the reason we avoid `-l` for
arbitrary input.

- [ ] **Step 4: Run — expect PASS**

Run: `cd agtermCore && swift test --filter TmuxCommandTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermCore/TmuxCommand.swift agtermCore/Tests/agtermCoreTests/TmuxCommandTests.swift
git commit -m "agtermCore: tmux outbound command encoder"
```

---

### Task 6: `TmuxSessionModel` — structural events → effects + window↔session map

The mapping model: consume `TmuxEvent`s and emit `TmuxModelEffect` intents for window
lifecycle, holding the `@window ↔ agterm sessionKey` map. Deliverable: add/close/rename event
sequences produce the right effects and maintain the map.

**Files:**
- Create: `Sources/agtermCore/TmuxSessionModel.swift`
- Test: `Tests/agtermCoreTests/TmuxSessionModelTests.swift`

**Interfaces:**
- Consumes: `TmuxEvent`, `TmuxWindowID`, `TmuxPaneID` (Tasks 1, 3).
- Produces:
  - ```swift
    public enum TmuxModelEffect: Equatable, Sendable {
        case createSession(window: TmuxWindowID, name: String)
        case removeSession(window: TmuxWindowID)
        case renameSession(window: TmuxWindowID, name: String)
        case routeOutput(window: TmuxWindowID, bytes: [UInt8])
        case tearDown
        case diagnostic(String)
    }
    public struct TmuxSessionModel: Sendable {
        public init()
        public mutating func handle(_ event: TmuxEvent) -> [TmuxModelEffect]
    }
    ```
  - Effects are keyed by `window` (the app-target `TmuxController` owns the window→agterm-Session
    UUID mapping; the host-free model stays in tmux-id space).

- [ ] **Step 1: Write the failing tests**

`TmuxSessionModelTests.swift`:
```swift
import Testing
@testable import agtermCore

struct TmuxSessionModelTests {
    @Test func windowAddCreatesSession() {
        var m = TmuxSessionModel()
        #expect(m.handle(.windowAdd(TmuxWindowID("@2"))) == [.createSession(window: TmuxWindowID("@2"), name: "")])
    }

    @Test func windowRenamedAfterAddRenamesSession() {
        var m = TmuxSessionModel()
        _ = m.handle(.windowAdd(TmuxWindowID("@2")))
        #expect(m.handle(.windowRenamed(TmuxWindowID("@2"), name: "logs"))
                == [.renameSession(window: TmuxWindowID("@2"), name: "logs")])
    }

    @Test func windowCloseRemovesTrackedSessionOnly() {
        var m = TmuxSessionModel()
        _ = m.handle(.windowAdd(TmuxWindowID("@2")))
        #expect(m.handle(.windowClose(TmuxWindowID("@2"), unlinked: false))
                == [.removeSession(window: TmuxWindowID("@2"))])
        // An unlinked-close for a window we never tracked is ignored (belongs to another session).
        #expect(m.handle(.windowClose(TmuxWindowID("@9"), unlinked: true)) == [])
    }

    @Test func renameOfUntrackedWindowIsIgnored() {
        var m = TmuxSessionModel()
        #expect(m.handle(.windowRenamed(TmuxWindowID("@5"), name: "x")) == [])
    }
}
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter TmuxSessionModelTests`
Expected: FAIL.

- [ ] **Step 3: Implement structural handling**

`TmuxSessionModel.swift`:
```swift
public enum TmuxModelEffect: Equatable, Sendable {
    case createSession(window: TmuxWindowID, name: String)
    case removeSession(window: TmuxWindowID)
    case renameSession(window: TmuxWindowID, name: String)
    case routeOutput(window: TmuxWindowID, bytes: [UInt8])
    case tearDown
    case diagnostic(String)
}

public struct TmuxSessionModel: Sendable {
    private var windows: Set<TmuxWindowID> = []          // windows we've mapped to sessions
    private var paneToWindow: [TmuxPaneID: TmuxWindowID] = [:]
    private var windowLeadingPane: [TmuxWindowID: TmuxPaneID] = [:]

    public init() {}

    public mutating func handle(_ event: TmuxEvent) -> [TmuxModelEffect] {
        switch event {
        case .windowAdd(let w):
            windows.insert(w)
            return [.createSession(window: w, name: "")]
        case .windowRenamed(let w, let name):
            guard windows.contains(w) else { return [] }
            return [.renameSession(window: w, name: name)]
        case .windowClose(let w, _):
            guard windows.contains(w) else { return [] }
            windows.remove(w)
            paneToWindow = paneToWindow.filter { $0.value != w }
            windowLeadingPane[w] = nil
            return [.removeSession(window: w)]
        default:
            return []                                     // output/layout/exit handled in Task 7
        }
    }
}
```

- [ ] **Step 4: Run — expect PASS**

Run: `cd agtermCore && swift test --filter TmuxSessionModelTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/eshreder/projects/agterm
git add agtermCore/Sources/agtermCore/TmuxSessionModel.swift agtermCore/Tests/agtermCoreTests/TmuxSessionModelTests.swift
git commit -m "agtermCore: tmux session model — window lifecycle effects"
```

---

### Task 7: `TmuxSessionModel` — output routing, no-splits rule, teardown

Complete the model: use `%layout-change` to learn pane↔window (applying the no-splits leading-
pane rule with a diagnostic), route `%output` to the owning window, and tear down on `%exit`.
Deliverable: an end-to-end event sequence (add → layout → output → exit) yields the right
effects, including the split diagnostic.

**Files:**
- Modify: `Sources/agtermCore/TmuxSessionModel.swift`
- Modify: `Tests/agtermCoreTests/TmuxSessionModelTests.swift`

**Interfaces:**
- Consumes: everything from Task 6 + `.layoutChange`, `.output`, `.exit`, `.windowPaneChanged`.
- Produces: `.routeOutput(window:bytes:)`, `.tearDown`, `.diagnostic(_)` now emitted; the
  `paneToWindow` map is populated from `.layoutChange`.

- [ ] **Step 1: Write the failing tests**

Append to `TmuxSessionModelTests.swift`:
```swift
    @Test func layoutChangeMapsLeadingPaneAndRoutesOutput() {
        var m = TmuxSessionModel()
        _ = m.handle(.windowAdd(TmuxWindowID("@0")))
        // Single-pane layout: pane %0 belongs to window @0.
        #expect(m.handle(.layoutChange(window: TmuxWindowID("@0"), layout: "b25d,80x24,0,0,0")) == [])
        // %output %0 now routes to window @0.
        #expect(m.handle(.output(pane: TmuxPaneID("%0"), bytes: [0x68, 0x69]))
                == [.routeOutput(window: TmuxWindowID("@0"), bytes: [0x68, 0x69])])
    }

    @Test func splitLayoutTakesLeadingPaneWithDiagnostic() {
        var m = TmuxSessionModel()
        _ = m.handle(.windowAdd(TmuxWindowID("@0")))
        let effects = m.handle(.layoutChange(window: TmuxWindowID("@0"),
                                             layout: "0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2}"))
        // The window has a split; we keep the leading pane %0 and emit a diagnostic.
        #expect(effects == [.diagnostic("window @0 has a split; showing leading pane %0")])
        // Output from the leading pane routes; output from the ignored pane does not.
        #expect(m.handle(.output(pane: TmuxPaneID("%0"), bytes: [0x41])) == [.routeOutput(window: TmuxWindowID("@0"), bytes: [0x41])])
        #expect(m.handle(.output(pane: TmuxPaneID("%2"), bytes: [0x42])) == [])
    }

    @Test func outputForUnknownPaneIsDropped() {
        var m = TmuxSessionModel()
        #expect(m.handle(.output(pane: TmuxPaneID("%7"), bytes: [0x41])) == [])
    }

    @Test func exitTearsDown() {
        var m = TmuxSessionModel()
        _ = m.handle(.windowAdd(TmuxWindowID("@0")))
        #expect(m.handle(.exit(reason: nil)) == [.tearDown])
    }
```

- [ ] **Step 2: Run — expect FAIL**

Run: `cd agtermCore && swift test --filter TmuxSessionModelTests`
Expected: the 4 new tests FAIL.

- [ ] **Step 3: Implement routing + no-splits + teardown**

In `TmuxSessionModel.handle`, replace the `default` arm's relevant cases:
```swift
        case .layoutChange(let w, let layout):
            guard windows.contains(w) else { return [] }
            let parsed = TmuxLayout.panes(in: layout)
            guard let leading = parsed.panes.first else { return [] }
            // Re-map: drop this window's old pane bindings, bind only the leading pane.
            paneToWindow = paneToWindow.filter { $0.value != w }
            paneToWindow[leading] = w
            windowLeadingPane[w] = leading
            if parsed.hasSplit {
                return [.diagnostic("window \(w.raw) has a split; showing leading pane \(leading.raw)")]
            }
            return []

        case .output(let pane, let bytes):
            guard let w = paneToWindow[pane] else { return [] }
            return [.routeOutput(window: w, bytes: bytes)]

        case .exit:
            return [.tearDown]

        default:
            return []
```
(Keep the `.windowAdd/.windowRenamed/.windowClose` cases from Task 6. `.windowPaneChanged`,
`.sessionChanged`, `.sessionWindowChanged`, `.sessionsChanged`, `.blockBegin/.blockLine/.blockEnd`,
`.unknown`, `.layoutChange`-already-handled fall through to `default` → `[]`.)

- [ ] **Step 4: Run — expect PASS (whole suite)**

Run: `cd agtermCore && swift test`
Expected: the full `agtermCore` suite is green, including all new tmux tests.

- [ ] **Step 5: Lint + commit**

```bash
cd /Users/eshreder/projects/agterm
make lint 2>&1 | tail -3     # expect clean
git add agtermCore/Sources/agtermCore/TmuxSessionModel.swift agtermCore/Tests/agtermCoreTests/TmuxSessionModelTests.swift
git commit -m "agtermCore: tmux model output routing, no-splits leading pane, teardown"
```

---

## Self-Review

**Spec coverage (spec components 2 & 3):**
- `TmuxControlParser` — Tasks 2–3 (framing, octal `%output`, all captured notifications,
  begin/end blocks, unknown-% ignored). ✓
- Outbound command encoder — Task 5 (`new-window`/`kill-window`/`rename-window`/`send-keys`
  (hex)/`refresh-client -C`/`detach-client`). ✓
- `TmuxSessionModel` events→effects with window↔session + pane↔window maps — Tasks 6–7. ✓
- No-splits leading-pane + diagnostic — Task 7. ✓
- Host-free, `swift test`-only, Sendable value types — enforced by Global Constraints and the
  test targets. ✓
- **Deferred to later phases (correctly out of scope for Phase 2):** the gateway subprocess,
  headless-surface wiring, `TmuxController` (Phase 3); control-API/CLI + agent-skill (Phases
  4–5). The `%client-detached` notification and the `%begin` block's `list-windows` *parsing
  into initial windows* are consumed by Phase 3's controller (this phase emits the raw
  `.blockLine`s; turning the initial `list-windows` block into sessions is the controller's
  job, since the block correlation to the attach command lives in the gateway).

**Placeholder scan:** every code step contains complete code; every test step contains real
assertions with real captured fixtures; no "TBD"/"handle edge cases"/"similar to Task N".

**Type consistency:** `TmuxWindowID`/`TmuxPaneID`/`TmuxSessionID`, `TmuxEvent` cases,
`TmuxLayout.panes(in:)`, `TmuxCommand`/`TmuxCommandEncoder.encode`, `TmuxModelEffect`,
`TmuxSessionModel.handle` — names and signatures are identical everywhere they appear across
Tasks 1–7. `.output(pane:bytes:)`, `.routeOutput(window:bytes:)`, `.diagnostic(_)`,
`.tearDown` match between the parser/model definitions and the tests.
