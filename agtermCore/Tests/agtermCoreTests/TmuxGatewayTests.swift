import Testing
import Foundation
@testable import agtermCore

struct TmuxGatewayTests {
    @Test func splitsBootstrapFromControlAndParsesEvents() async throws {
        // Pre-handshake "password:" preamble, then the DCS handshake + a couple notifications.
        let transcript = "password: \u{1b}P1000p%window-add @0\r\n%output %0 hi\r\n%exit\r\n\u{1b}\\"
        let boot = LockedBox()
        let events = EventBox()
        let handshaken = FlagBox()
        let exited = FlagBox()
        let gw = TmuxGateway(callbacks: .init(
            onBootstrapBytes: { boot.append($0) },
            onHandshake: { handshaken.set() },
            onEvent: { events.append($0) },
            onExit: { _ in exited.set() }))
        // Emit the transcript verbatim from a subprocess.
        let escaped = transcript.replacingOccurrences(of: "'", with: "'\\''")
        try gw.start(path: "/bin/sh", args: ["/bin/sh", "-c", "printf %s '\(escaped)'"], env: [:])
        try await waitUntil(2.0) { events.contains(.exit(reason: nil)) }
        #expect(boot.text.contains("password:"))
        #expect(handshaken.isSet)
        #expect(events.all.contains(.windowAdd(TmuxWindowID("@0"))))
        #expect(events.all.contains(.output(pane: TmuxPaneID("%0"), bytes: Array("hi".utf8))))
        #expect(events.all.contains(.exit(reason: nil)))
        // The child's exit must also fire the gateway-level onExit callback — the seam the
        // controller's ENTIRE teardown hangs on; the parsed %exit event alone doesn't prove it.
        try await waitUntil(2.0) { exited.isSet }
        #expect(exited.isSet)
        gw.stop()
    }

    // The keep-partial-marker math holds back ONLY a trailing suffix that could still be the START of a
    // split \u{1b}P1000p handshake — NOT a fixed 6 bytes — so a blocking auth prompt whose tail is not a
    // marker prefix (e.g. "password: ") is flushed in full rather than truncated by up to 6 chars.
    @Test func partialMarkerPrefixKeepsOnlyGenuinePrefix() {
        let marker = Data("\u{1b}P1000p".utf8)
        // A tail that builds toward the marker is kept by its matching length.
        #expect(TmuxGateway.partialMarkerPrefixLength(of: Data("hi\u{1b}P1".utf8), marker: marker) == 3)
        // A bare trailing ESC is a 1-byte marker prefix.
        #expect(TmuxGateway.partialMarkerPrefixLength(of: Data("abc\u{1b}".utf8), marker: marker) == 1)
        // A prompt tail that is not a marker prefix keeps nothing (else it would be held back/truncated).
        #expect(TmuxGateway.partialMarkerPrefixLength(of: Data("password: ".utf8), marker: marker) == 0)
        // An ESC followed by a non-marker byte cannot be the marker start.
        #expect(TmuxGateway.partialMarkerPrefixLength(of: Data("x\u{1b}Q".utf8), marker: marker) == 0)
        // Empty input keeps nothing.
        #expect(TmuxGateway.partialMarkerPrefixLength(of: Data(), marker: marker) == 0)
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock(); private var items: [TmuxEvent] = []
    func append(_ e: TmuxEvent) { lock.lock(); items.append(e); lock.unlock() }
    func contains(_ e: TmuxEvent) -> Bool { lock.lock(); defer { lock.unlock() }; return items.contains(e) }
    var all: [TmuxEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

final class FlagBox: @unchecked Sendable {
    private let lock = NSLock(); private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
