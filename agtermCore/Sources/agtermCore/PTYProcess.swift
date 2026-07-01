import Foundation
import Darwin

/// A host-free PTY wrapper: opens a pseudoterminal, `posix_spawn`s a command with the
/// subordinate end as its stdin/stdout/stderr, reads the primary asynchronously on a private
/// background queue (invoking `onData` with each chunk), writes to the primary, and
/// terminates the child. This is the transport the tmux gateway drives.
///
/// `@unchecked Sendable`: it owns an fd + a `DispatchSourceRead`; all mutation is
/// serialized on its own queue. Callbacks fire on that background queue — the CONSUMER
/// is responsible for hopping to the main actor.
///
/// - Important: `start()` must be called (and return) before any concurrent `write`/
///   `terminate`. `start()` publishes the fd/pid/sources via the source `resume()`
///   barrier; steady-state mutation thereafter is confined to the private queue.
public final class PTYProcess: @unchecked Sendable {
    private var primaryFD: Int32 = -1
    private var pid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var procSource: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "agterm.pty")

    public init() {}

    /// Spawn `path` with `args` (argv[0] is set by the caller, conventionally `path`) and
    /// `env`. `onData` is called on a background queue with each chunk read from the pty
    /// primary. `onExit` is called once with the child's wait status when it exits.
    /// Throws on open/spawn failure. Must be called before any concurrent `write`/`terminate`.
    public func start(path: String, args: [String], env: [String: String],
                      onData: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws {
        let primary = posix_openpt(O_RDWR | O_NOCTTY)
        guard primary >= 0, grantpt(primary) == 0, unlockpt(primary) == 0,
              let ptsPath = ptsname(primary) else {
            if primary >= 0 { close(primary) }
            throw PTYError.openFailed
        }
        // The subordinate (child-side) end of the pty.
        let subFD = open(ptsPath, O_RDWR | O_NOCTTY)
        guard subFD >= 0 else { close(primary); throw PTYError.openFailed }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, subFD, 0)
        posix_spawn_file_actions_adddup2(&actions, subFD, 1)
        posix_spawn_file_actions_adddup2(&actions, subFD, 2)
        posix_spawn_file_actions_addclose(&actions, subFD)
        posix_spawn_file_actions_addclose(&actions, primary)
        defer { posix_spawn_file_actions_destroy(&actions) }

        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0)=\($1)") } + [nil]
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, path, &actions, nil, argv, envp)
        close(subFD)
        guard rc == 0 else { close(primary); throw PTYError.spawnFailed(rc) }
        self.primaryFD = primary
        self.pid = childPID

        let rs = DispatchSource.makeReadSource(fileDescriptor: primary, queue: queue)
        // The cancel handler is the SOLE owner of the fd close — every teardown path
        // (EOF/error, terminate(), child exit, deinit) routes through cancel(), so the
        // fd is closed exactly once and never while the source still monitors it.
        rs.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.primaryFD >= 0 { close(self.primaryFD); self.primaryFD = -1 }
        }
        rs.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(self.primaryFD, &buf, buf.count)
            // EOF (0) or error (<0): cancel -> fd closed by cancel handler.
            if n > 0 { onData(Data(buf[0..<n])) } else { rs.cancel() }
        }
        rs.resume()
        self.readSource = rs

        let ps = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        ps.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(childPID, &status, 0)
            onExit(status)
            self?.readSource?.cancel()   // closes the primary fd via the read source's cancel handler
            self?.procSource?.cancel()
        }
        ps.resume()
        self.procSource = ps
    }

    /// Write bytes to the pty primary (the child's stdin). No-op after termination.
    public func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.primaryFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                _ = Darwin.write(self.primaryFD, raw.baseAddress, raw.count)
            }
        }
    }

    /// Send SIGTERM to the child and tear down the sources. The primary fd is closed by
    /// the read source's cancel handler — never directly here (closing a monitored fd is
    /// libdispatch UB).
    public func terminate() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.pid > 0 { kill(self.pid, SIGTERM) }
            self.readSource?.cancel()   // cancel handler owns the fd close
            self.procSource?.cancel()
        }
    }

    deinit {
        // Synchronous and self-free: capturing self from a deallocating object is UB, so
        // touch only the retained sources/pid directly (no queue.async { self... }).
        readSource?.cancel()
        procSource?.cancel()
        if pid > 0 { kill(pid, SIGTERM) }
    }
}

public enum PTYError: Error {
    case openFailed
    case spawnFailed(Int32)
}
