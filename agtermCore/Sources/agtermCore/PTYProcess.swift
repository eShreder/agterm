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
    /// Throws on open/spawn failure.
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
        rs.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(self.primaryFD, &buf, buf.count)
            if n > 0 { onData(Data(buf[0..<n])) }
        }
        rs.resume()
        self.readSource = rs

        let ps = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        ps.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(childPID, &status, 0)
            onExit(status)
            self?.readSource?.cancel()
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

    /// Send SIGTERM to the child and close the primary fd.
    public func terminate() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.pid > 0 { kill(self.pid, SIGTERM) }
            if self.primaryFD >= 0 { close(self.primaryFD); self.primaryFD = -1 }
        }
    }
}

public enum PTYError: Error {
    case openFailed
    case spawnFailed(Int32)
}
