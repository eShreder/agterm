import Foundation
import agtermCore
import Darwin

/// One per-window unix-domain socket bridging the app's `TmuxController` to a single
/// `agtermctl tmux-pipe` child (the tmux window's session command). The app is the LISTENER; the
/// child connects. Inbound bytes are decoded with `RelayCodec` and delivered as `RelayFrame`s; the
/// app writes `%output` back with `send(_:)`.
///
/// `@unchecked Sendable` mirroring `TmuxGateway`. The BLOCKING accept/read loop runs on its OWN
/// dedicated thread (never a shared queue — a blocking read there would starve writes); `send(_:)`
/// writes on a separate serial `writeQueue`. `clientFD`/`pending`/`closed` are guarded by `lock`.
/// `onFrame` fires OFF the main actor (like `GhosttyCallbacks`) — the controller hops it to `@MainActor`.
///
/// **Buffer-until-connect:** the child connects ASYNC (session created → eager deck mounts the surface →
/// ghostty spawns the child → it `connect`s), so `%output` sent before then — crucially the `capture-pane`
/// paint of a pre-existing window on attach — would otherwise be DROPPED, leaving the window blank until
/// some live output (why Ctrl-L "half fixed" it). So `send(_:)` BUFFERS into `pending` while no client is
/// attached, and the flush runs ON `writeQueue` (serialized with sends → no interleaving mid-frame). This
/// mirrors how the headless surface buffered `writeOutput` until it mounted.
///
/// The socket path lives under `/tmp` on purpose: `sockaddr_un.sun_path` is only ~104 bytes, and the
/// per-window Application-Support path would overflow it. The file is unlinked on `close()`.
///
/// **Hardening:** `/tmp` is world-traversable, so the relay is locked to the owner — the containing dir
/// is created `0700` and the socket file is `chmod`ed `0600` right after bind. A `0600` unix socket
/// denies `connect()` to any other local user (connect needs write permission on the socket file),
/// closing the hijack vector: without it a co-user could race the `tmux-pipe` child, connect first, and
/// inject `send-keys` (command execution on the remote host) or read the window's `%output`.
final class RelaySocket: @unchecked Sendable {
    /// Filesystem path the child connects to (passed as `tmux-pipe --socket <path>`).
    let path: String

    private let onFrame: @Sendable (RelayFrame) -> Void
    private let writeQueue = DispatchQueue(label: "com.umputun.agterm.relaysocket.write")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var pending: [UInt8] = []      // outbound bytes buffered until the child connects
    private var closed = false
    /// Cap on the pre-connect buffer: a child that never connects must not grow it without bound.
    private static let maxPending = 8 * 1024 * 1024

    /// Bind + listen immediately so `path` exists before the child is spawned. `onFrame` is invoked on
    /// the read thread for each decoded inbound frame.
    init?(onFrame: @escaping @Sendable (RelayFrame) -> Void) {
        self.onFrame = onFrame
        // Per-uid, owner-only dir so a co-user can neither reach the socket nor contend for the path.
        let dir = "/tmp/agterm-relay-\(getuid())"
        self.path = "\(dir)/\(UUID().uuidString.prefix(12)).sock"
        // FAIL CLOSED if the dir isn't one WE own at 0700. `/tmp` is world-writable, so a co-user who
        // pre-creates `/tmp/agterm-relay-<uid>` (or a symlink) would own the dir and could unlink our
        // 0600 socket and bind their own before the child connects (relay hijack → send-keys into the
        // remote session / %output read). createDirectory + best-effort chmod could NOT establish
        // ownership: it no-ops on a pre-existing foreign dir and the chmod then silently fails.
        guard Self.ensureOwnerOnlyDir(dir) else { return nil }
        guard bindAndListen() else { return nil }
        Thread.detachNewThread { [weak self] in self?.readLoop() }
    }

    /// Create `dir` as a fresh `0700` directory we own, or accept a pre-existing one ONLY if it is a real
    /// directory (not a symlink), owned by us, with no group/other access. Fails closed otherwise so a
    /// co-user's pre-created dir can never host our relay socket. `mkdir` is atomic (no create-then-chmod
    /// TOCTOU); `lstat` does not follow a symlink, so a planted link reads as `S_IFLNK` and is rejected.
    private static func ensureOwnerOnlyDir(_ dir: String) -> Bool {
        if mkdir(dir, 0o700) == 0 { return true }           // fresh: created + owned by us at 0700
        guard errno == EEXIST else { return false }
        var st = stat()
        guard lstat(dir, &st) == 0 else { return false }
        let mode = st.st_mode                                    // mode_t — compare against S_IF* in-domain
        guard (mode & S_IFMT) == S_IFDIR else { return false }   // a real directory, not a symlink/file
        guard st.st_uid == getuid() else { return false }        // OURS — reject an attacker's pre-created dir
        return (mode & 0o077) == 0                                // owner-only: no group/other traversal
    }

    private func bindAndListen() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        unlink(path)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { Darwin.close(fd); return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for i in 0..<bytes.count { dst[i] = CChar(bitPattern: bytes[i]) }
                dst[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 }
        }
        guard ok, listen(fd, 1) == 0 else { Darwin.close(fd); return false }
        chmod(path, 0o600)   // owner-only: deny connect() to any other local user (relay hijack guard)
        listenFD = fd
        return true
    }

    /// Accept the single child connection, then pump reads — on a DEDICATED thread so the blocking
    /// `read` never starves `send`. Each decoded frame is delivered via `onFrame` (off-main).
    private func readLoop() {
        // Snapshot listenFD UNDER lock: close() writes it (to -1) under the same lock, so an unsynchronized
        // read here would be a data race (the outcome is benign — accept gets the real fd, then close()'s
        // Darwin.close unblocks it, or -1/EBADF and the thread exits — but the C-boundary contract avoids
        // races on principle). If close() already ran, `listen` is -1 and accept bails immediately.
        lock.lock()
        let listen = closed ? -1 : listenFD
        lock.unlock()
        let client = accept(listen, nil, nil)
        guard client >= 0 else { return }
        // Never let a `%output` write to a child that already hung up (window killed / child exited with a
        // write still queued) raise SIGPIPE — it is default-fatal and would take the WHOLE app down.
        // SO_NOSIGPIPE turns it into a normal EPIPE from write(), which rawWrite ignores. Mirrors
        // ControlServer.handleConnection's per-connection guard.
        var noSigPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // Publish the fd + flush anything buffered before connect, ON writeQueue so it can't interleave
        // mid-frame with a concurrent send(). The read loop below uses the `client` local independently.
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.closed { self.lock.unlock(); Darwin.close(client); return }
            self.clientFD = client
            let toFlush = self.pending
            self.pending = []
            self.lock.unlock()
            self.rawWrite(client, toFlush)
        }

        var decoder = RelayCodec.Decoder()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }                        // child exited / EOF
            for frame in decoder.feed(Array(buf[0..<n])) { onFrame(frame) }
        }
        // Child hung up: reclaim the client fd NOW rather than waiting for close(), so later send()s
        // buffer instead of EPIPE-ing into a dead socket and the fd doesn't linger until teardown.
        // ON writeQueue like every other client-fd touch; the connect-publish task was enqueued before
        // any read could return, so it has already run on this serial queue. If close() won the race
        // (`closed` set), it owns the fd — closing here too would double-close a recycled descriptor.
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let owned = !self.closed && self.clientFD == client
            if owned { self.clientFD = -1 }
            self.lock.unlock()
            if owned { Darwin.close(client) }
        }
    }

    /// Write a frame to the child (e.g. tmux `%output` as `.data`). Serialized on `writeQueue`. Before
    /// the child connects, the bytes are BUFFERED (`pending`) and flushed on connect — so a pre-connect
    /// `capture-pane` paint isn't lost.
    func send(_ frame: RelayFrame) {
        let bytes = RelayCodec.encode(frame)
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.closed { self.lock.unlock(); return }
            let fd = self.clientFD
            if fd < 0 {
                if self.pending.count + bytes.count <= Self.maxPending { self.pending += bytes }
                self.lock.unlock()
                return
            }
            self.lock.unlock()
            self.rawWrite(fd, bytes)
        }
    }

    /// Blocking write-all of `bytes` to `fd` (EINTR-safe). Called only on `writeQueue`.
    private func rawWrite(_ fd: Int32, _ bytes: [UInt8]) {
        guard fd >= 0, !bytes.isEmpty else { return }
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let w = write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if w < 0 { if errno == EINTR { continue }; return }
                offset += w
            }
        }
    }

    /// Close both fds and unlink the socket file. Idempotent. The blocking `read` returns 0 once the
    /// fd is closed, ending the read thread.
    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let client = clientFD, listen = listenFD
        clientFD = -1; listenFD = -1
        pending = []
        lock.unlock()
        // The LISTEN fd is only ever read by the one `accept` in readLoop; closing it here unblocks that
        // accept (and unlink drops the path). Safe off-queue.
        if listen >= 0 { Darwin.close(listen) }
        unlink(path)
        // Close the CLIENT fd ON writeQueue so it is serialized with send()/the connect flush — both write
        // to the client fd from writeQueue. Closing it here (off-queue) could race a queued rawWrite that
        // already captured the fd, writing to a closed-or-recycled descriptor (dropped output / cross-relay
        // corruption). `closed` is now set, so any not-yet-run send bails under the lock before writing,
        // making this the LAST writeQueue task to touch the fd.
        if client >= 0 { writeQueue.async { Darwin.close(client) } }
    }
}
