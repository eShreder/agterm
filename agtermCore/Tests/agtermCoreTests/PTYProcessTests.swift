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
        // Generous deadline: the wait returns as soon as the echo lands, so a large bound only buys
        // tolerance for a loaded machine (swift-testing runs suites in parallel, and spawning a child
        // there can take seconds) — it never slows the passing case.
        try await waitUntil(20.0) { received.contains("hello") }
        #expect(received.text.contains("hello"))
        pty.terminate()
    }

    // The pty carries a sane window size from the moment the child execs. A fresh `posix_openpt` is 0x0,
    // and a `tmux -CC` child takes its tty size as the CLIENT size — so without this seed `tmux new`
    // would create a session sized from a degenerate tty, and every mirrored window would be driven from
    // it until the first relay `refresh-client -C` arrived. `stty size` prints "<rows> <cols>".
    @Test func ptySeedsAWindowSizeBeforeTheChildExecs() async throws {
        let pty = PTYProcess()
        let received = LockedBox()
        try pty.start(path: "/bin/sh", args: ["/bin/sh", "-c", "/bin/stty size"], env: [:],
                      onData: { received.append($0) },
                      onExit: { _ in })
        try await waitUntil(20.0) { received.contains("24 80") }
        #expect(received.contains("24 80"))
        pty.terminate()
    }

    // A child that exits on its own fires onExit carrying its wait status (WEXITSTATUS decodes to the
    // child's exit code), and a terminate() AFTER the child has already been reaped is safe — the reap
    // clears `pid` under pidLock so no SIGTERM is sent to a freed/recycled PID.
    @Test func onExitFiresWithChildStatusAndTerminateAfterReapIsSafe() async throws {
        let pty = PTYProcess()
        let status = LockedInt()
        try pty.start(path: "/bin/sh", args: ["/bin/sh", "-c", "exit 3"], env: [:],
                      onData: { _ in },
                      onExit: { status.set(Int($0)) })
        try await waitUntil(20.0) { status.value != nil }
        let raw = try #require(status.value)
        #expect((raw >> 8) & 0xff == 3)
        pty.terminate()   // child already reaped: must not crash / SIGTERM a recycled PID
    }

    // terminate() SIGTERMs the child but must NOT disarm the reaper: the process source has to survive to
    // waitpid the SIGTERM'd child, else it lingers as a zombie until app exit. Proven here by onExit firing
    // after a terminate() that PRECEDES the child's own exit — onExit only runs from the process source's
    // reap handler, so if terminate() had cancelled that source, onExit would never fire (old zombie bug).
    @Test func terminateBeforeChildExitStillReapsViaOnExit() async throws {
        let pty = PTYProcess()
        let status = LockedInt()
        try pty.start(path: "/bin/sh", args: ["/bin/sh", "-c", "sleep 30"], env: [:],
                      onData: { _ in },
                      onExit: { status.set(Int($0)) })
        pty.terminate()   // SIGTERM well before the child would exit on its own
        try await waitUntil(20.0) { status.value != nil }
        #expect(status.value != nil)   // onExit fired => the process source reaped the child (no zombie)
    }

    // start() throws on a nonexistent executable (posix_spawn returns ENOENT synchronously on Darwin).
    @Test func startThrowsOnMissingExecutable() throws {
        let pty = PTYProcess()
        #expect(throws: PTYError.self) {
            try pty.start(path: "/no/such/binary", args: ["/no/such/binary"], env: [:],
                          onData: { _ in }, onExit: { _ in })
        }
    }
}

final class LockedInt: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Int?
    func set(_ v: Int) { lock.lock(); stored = v; lock.unlock() }
    var value: Int? { lock.lock(); defer { lock.unlock() }; return stored }
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
    // Record the timeout explicitly so a hung wait fails HERE with context, instead of falling
    // through to the caller's assertion with no hint that the deadline (not the value) was the problem.
    Issue.record("waitUntil timed out after \(seconds)s")
}
