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
        let gw = TmuxGateway(callbacks: .init(
            onBootstrapBytes: { boot.append($0) },
            onHandshake: { handshaken.set() },
            onEvent: { events.append($0) },
            onExit: { _ in }))
        // Emit the transcript verbatim from a subprocess.
        let escaped = transcript.replacingOccurrences(of: "'", with: "'\\''")
        try gw.start(path: "/bin/sh", args: ["/bin/sh", "-c", "printf %s '\(escaped)'"], env: [:])
        try await waitUntil(2.0) { events.contains(.exit(reason: nil)) }
        #expect(boot.text.contains("password:"))
        #expect(handshaken.isSet)
        #expect(events.all.contains(.windowAdd(TmuxWindowID("@0"))))
        #expect(events.all.contains(.output(pane: TmuxPaneID("%0"), bytes: Array("hi".utf8))))
        #expect(events.all.contains(.exit(reason: nil)))
        gw.stop()
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
