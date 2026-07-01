import Testing
import Foundation
@testable import agtermCore

struct PTYProcessTests {
    // Spawn /bin/cat in a pty; bytes written to stdin echo back on stdout.
    @Test func catEchoesThroughThePty() async throws {
        let pty = PTYProcess()
        let received = LockedBox()
        try pty.start(path: "/bin/cat", args: ["/bin/cat"], env: [:],
                      onData: { received.append($0) },
                      onExit: { _ in })
        pty.write(Data("hello\n".utf8))
        // Poll up to ~2s for the echo (cat is line-buffered on a tty).
        try await waitUntil(2.0) { received.contains("hello") }
        #expect(received.text.contains("hello"))
        pty.terminate()
    }
}

// Small test helpers (put in the same file).
final class LockedBox: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    func contains(_ s: String) -> Bool { text.contains(s) }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

func waitUntil(_ seconds: Double, _ cond: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if cond() { return }
        try await Task.sleep(nanoseconds: 20_000_000)   // 20ms
    }
}
