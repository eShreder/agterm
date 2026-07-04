import Foundation

#if canImport(Darwin)
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
    /// Guards `pid` against the PID-reuse race: the process source reaps the child (clearing `pid`) on
    /// its own queue while `terminate()`/`deinit` read-and-SIGTERM it off-queue. Without this a natural
    /// exit — reap on the pty queue, then `onExit` hops to the main actor and drives teardown →
    /// `terminate()` — would `kill` an already-reaped, possibly-recycled PID.
    private let pidLock = NSLock()
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

        // Raw mode: a control-mode transport carries the multiplexer's stream (and binary
        // %output) verbatim — cooked-mode output post-processing (ONLCR turning every \n
        // into \r\n) and input echo/canonicalization would corrupt it. Match what a
        // control-mode child (tmux -CC) sets on its own tty.
        var term = termios()
        if tcgetattr(subFD, &term) == 0 {
            cfmakeraw(&term)
            tcsetattr(subFD, TCSANOW, &term)
        }

        // Give the child the pty as its CONTROLLING terminal, not just fd 0/1/2: ssh's interactive
        // prompts (the host-key confirmation and password/keyboard-interactive auth) read from
        // `/dev/tty`, not stdin, and `/dev/tty` only resolves with a ctty — without one the entire
        // bootstrap auth phase fails ("can't open /dev/tty"). POSIX_SPAWN_SETSID (below) makes the
        // child a session leader; this addopen of the pts as fd 0 is then the new session's FIRST
        // tty open, which acquires it as the controlling terminal (the pre-opened parent `subFD`
        // is O_NOCTTY and only used for the raw-mode tcsetattr).
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, ptsPath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addclose(&actions, subFD)
        posix_spawn_file_actions_addclose(&actions, primary)
        defer { posix_spawn_file_actions_destroy(&actions) }

        // Reset the child's signal state: exec PRESERVES ignored dispositions and the signal mask, so a
        // host that ignores/blocks SIGTERM (e.g. a test runner) would silently spawn children our
        // `terminate()` SIGTERM can never kill. Standard spawn hygiene — every signal back to default,
        // empty mask (what ghostty itself does when spawning the shell).
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigdefault(&attrs, &allSignals)
        posix_spawnattr_setsigmask(&attrs, &noSignals)
        // SETSID: new session, so the fd-0 addopen above acquires the pty as the child's ctty.
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSID))

        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0)=\($1)") } + [nil]
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, path, &actions, &attrs, argv, envp)
        close(subFD)
        guard rc == 0 else { close(primary); throw PTYError.spawnFailed(rc) }
        self.primaryFD = primary
        self.pid = childPID

        let rs = DispatchSource.makeReadSource(fileDescriptor: primary, queue: queue)
        // The cancel handler is the SOLE owner of the fd close — every teardown path
        // (EOF/error, terminate(), child exit, deinit) routes through cancel(), so the
        // fd is closed exactly once and never while the source still monitors it. It
        // captures `self` STRONGLY on purpose: this keeps the PTYProcess alive until the
        // fd is actually closed, even if the owner releases its last reference the instant
        // after calling terminate() (a weak capture would see nil and leak the fd). The
        // resulting retain cycle self-breaks when libdispatch releases the handler after
        // cancellation completes; the owner MUST call terminate() (or the child must exit)
        // for that to happen — the controller always does on teardown.
        rs.setCancelHandler { [self] in
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
        // The exit handler is the SOLE reaper (`waitpid`), so it captures `self` STRONGLY — like the read
        // source's cancel handler — to keep the PTYProcess alive until the child has actually been reaped,
        // even if the owner calls `terminate()` and drops its last reference the instant after. Without
        // this (the old `[weak self]` + a `terminate()` that cancelled this source) a SIGTERM'd child that
        // had not exited yet would leave the source disarmed → never `waitpid`ed → a zombie until app exit.
        // The retain cycle self-breaks the moment this handler cancels the source after reaping.
        ps.setEventHandler { [self] in
            var status: Int32 = 0
            // Reap AND clear `pid` under `pidLock`, so a concurrent `terminate()`/`deinit` can never
            // SIGTERM in the window between the `waitpid` (which frees the PID for OS reuse) and the
            // clear. Holding the lock across `waitpid` is safe: the source fired because the child
            // already exited, so the wait returns immediately. Cleared BEFORE `onExit` so any teardown
            // it triggers sees pid == -1.
            pidLock.lock()
            waitpid(childPID, &status, 0)
            pid = -1
            pidLock.unlock()
            onExit(status)
            readSource?.cancel()   // closes the primary fd via the read source's cancel handler
            // Cancel the LOCAL `ps`, not `self.procSource`: a short-lived child can exit and fire this
            // handler on `queue` in the window between `ps.resume()` and `self.procSource = ps` below, when
            // the property is still nil — a `procSource?.cancel()` would no-op and leak the retain cycle
            // (and racing-read the property). The local capture always cancels. Mirrors the read source's
            // `rs.cancel()`. Cancelling self here breaks the strong-capture retain cycle once reaping is done.
            ps.cancel()
        }
        ps.resume()
        self.procSource = ps
    }

    /// Write bytes to the pty primary (the child's stdin). No-op after termination. Writes ALL bytes:
    /// a single `write(2)` to a pty can be short (its buffer fills), and a partial write of a control-mode
    /// command (e.g. a large `send-keys -H` expansion) would truncate/corrupt the multiplexer stream — so
    /// loop until every byte is flushed, retrying on EINTR. Runs on the private serial `queue`, which also
    /// owns `primaryFD`, so the fd can't be closed mid-loop.
    public func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.primaryFD >= 0 else { return }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let w = Darwin.write(self.primaryFD, base.advanced(by: offset), raw.count - offset)
                    if w < 0 { if errno == EINTR { continue }; return }   // EINTR: retry; other error: give up
                    offset += w
                }
            }
        }
    }

    /// Send SIGTERM to the child and tear down the sources. The primary fd is closed by
    /// the read source's cancel handler (which strong-captures self) — never directly here
    /// (closing a monitored fd is libdispatch UB). `cancel()` is thread-safe and is called
    /// synchronously here, NOT via a `[weak self]` queue hop: the owner often releases the
    /// PTYProcess immediately after `terminate()`, and a weak hop would deallocate self
    /// before the cancel ran, leaking the fd. `readSource`/`procSource` are set once in
    /// `start()` and never mutated after, so reading them off-queue is safe; the read-and-SIGTERM
    /// of `pid` happens UNDER `pidLock` (the reap handler holds it across `waitpid` + clear), so the
    /// kill can never race a just-freed, possibly-recycled PID.
    public func terminate() {
        pidLock.lock()
        if pid > 0 { kill(pid, SIGTERM) }
        pidLock.unlock()
        readSource?.cancel()   // strong-capture cancel handler closes the fd, keeping self alive until then
        // Do NOT cancel `procSource` here: it is the sole reaper (`waitpid`), and cancelling it before the
        // just-SIGTERM'd child has exited would orphan the child into a zombie until app exit. The child
        // exits from the SIGTERM, the process source fires, and its strong-capture handler reaps + cancels
        // itself. (On a child that had already exited/been reaped, the handler has already cancelled it.)
    }

    deinit {
        // Both sources strong-tie `self` (the read source via its cancel handler, the process source via
        // its exit handler), so deinit runs only AFTER both have been cancelled — the fd is already closed
        // and the child already reaped. These cancels are defensive no-op backstops; deinit stays self-free.
        readSource?.cancel()
        procSource?.cancel()
        pidLock.lock()
        if pid > 0 { kill(pid, SIGTERM) }
        pidLock.unlock()
    }
}

public enum PTYError: Error {
    case openFailed
    case spawnFailed(Int32)
}

#endif // The PTY transport is Darwin-only (posix_spawn file actions + DispatchSourceProcess); the Linux agtermctl build (thin socket client) never touches it, so it is compiled out there.
