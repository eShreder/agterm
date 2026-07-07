import ArgumentParser
import Foundation
import agtermCore
import Darwin

/// `agtermctl tmux-pipe --socket <path>` — the per-window relay child.
///
/// libghostty spawns this in a real PTY as a tmux window's session command (`Session.initialCommand`).
/// It bridges that PTY to the app's `TmuxController` over a unix socket using `RelayCodec`. This is
/// what lets a remote `tmux -CC` window render in a STOCK (unpatched) agterm surface: there is no
/// headless engine backend, just an ordinary child process whose stdin/stdout ARE the terminal.
///
///   stdin  (keystrokes) ─▶ RelayCodec.encode(.data)  ─▶ socket ─▶ app ─▶ tmux `send-keys`
///   app `%output` ─▶ socket ─▶ RelayCodec.Decoder .data ─▶ stdout (rendered by the surface)
///   SIGWINCH ─▶ TIOCGWINSZ ─▶ RelayCodec.encode(.resize) ─▶ socket ─▶ app ─▶ tmux `refresh-client -C`
///
/// Not user-facing (`shouldDisplay: false`); invoked only by agterm.
public struct TmuxPipe: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tmux-pipe",
        abstract: "Internal: relay a tmux -CC window between its PTY and the agterm control socket.",
        shouldDisplay: false)

    @Option(name: .long, help: "Path of the per-window unix socket to connect to.")
    var socket: String

    public init() {}

    public func run() throws {
        try TmuxPipeRelay(socketPath: socket).run()
    }
}

/// SIGWINCH flag, set from the async-signal-safe handler and drained in the poll loop. A relay
/// process is single-purpose and single-threaded, so a process-global is fine here.
private nonisolated(unsafe) var tmuxPipeWinchPending: sig_atomic_t = 1   // 1 = send an initial size on start

/// The POSIX relay loop behind `tmux-pipe`. First-cut POSIX plumbing — the framing lives in the
/// unit-tested `RelayCodec`; this I/O loop is verified against a live `tmux -CC` on the Mac (see
/// the plan's manual gate), with its cheap validation edges (bad socket path) unit-tested.
final class TmuxPipeRelay {
    private let socketPath: String
    private var sock: Int32 = -1
    private var savedTermios = termios()
    private var rawApplied = false

    init(socketPath: String) { self.socketPath = socketPath }

    func run() throws {
        // A dead peer (the app closed the relay, or libghostty closed the PTY read end) makes the next
        // write RAISE SIGPIPE, whose default action KILLS this child before `writeAll` can observe the
        // EPIPE — so ignore it process-wide (covers both the socket and STDOUT writes) and let the
        // `write() < 0` branch drive a clean loop exit instead.
        signal(SIGPIPE, SIG_IGN)
        try makeStdinRaw()
        defer { restoreStdin() }
        try connectSocket()
        defer { if sock >= 0 { close(sock) } }

        signal(SIGWINCH) { _ in tmuxPipeWinchPending = 1 }

        var decoder = RelayCodec.Decoder()
        var buf = [UInt8](repeating: 0, count: 65536)

        while true {
            if tmuxPipeWinchPending != 0 { tmuxPipeWinchPending = 0; sendResize() }

            var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: sock, events: Int16(POLLIN), revents: 0)]
            // 200ms timeout so a SIGWINCH that lands between poll() arming and blocking is still
            // serviced promptly regardless of the platform's signal-restart semantics.
            let n = poll(&fds, 2, 200)
            if n < 0 {
                if errno == EINTR { continue }        // a signal (e.g. SIGWINCH) — loop re-checks the flag
                break
            }
            if n == 0 { continue }

            // stdin → socket (keystrokes)
            if fds[0].revents & Int16(POLLIN) != 0 {
                let r = readInto(STDIN_FILENO, &buf)
                if r <= 0 { break }                    // PTY closed
                writeAll(sock, RelayCodec.encode(.data(Array(buf[0..<r]))))
            }
            if fds[0].revents & Int16(POLLHUP | POLLERR) != 0 { break }

            // socket → stdout (tmux %output)
            if fds[1].revents & Int16(POLLIN) != 0 {
                let r = readInto(sock, &buf)
                if r <= 0 { break }                    // app closed the relay
                for frame in decoder.feed(Array(buf[0..<r])) {
                    if case .data(let bytes) = frame { writeAll(STDOUT_FILENO, bytes) }
                    // .resize from the app is not expected; ignore.
                }
            }
            if fds[1].revents & Int16(POLLHUP | POLLERR) != 0 { break }
        }
    }

    // MARK: - stdin raw mode

    private func makeStdinRaw() throws {
        guard tcgetattr(STDIN_FILENO, &savedTermios) == 0 else { return }   // not a tty: leave as-is
        var raw = savedTermios
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            throw ValidationError("tmux-pipe: failed to set raw mode")
        }
        rawApplied = true
    }

    private func restoreStdin() {
        if rawApplied { _ = tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios) }
    }

    // MARK: - socket

    private func connectSocket() throws {
        sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw ValidationError("tmux-pipe: socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < capacity else { throw ValidationError("tmux-pipe: socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for i in 0..<pathBytes.count { dst[i] = CChar(bitPattern: pathBytes[i]) }
                dst[pathBytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, len) }
        }
        guard rc == 0 else { throw ValidationError("tmux-pipe: connect() failed (errno \(errno))") }
    }

    // MARK: - resize

    private func sendResize() {
        var ws = winsize()
        guard ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else { return }
        writeAll(sock, RelayCodec.encode(.resize(cols: ws.ws_col, rows: ws.ws_row)))
    }

    // MARK: - I/O helpers (EINTR-safe)

    private func readInto(_ fd: Int32, _ buf: inout [UInt8]) -> Int {
        while true {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if r < 0 && errno == EINTR { continue }
            return r
        }
    }

    private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let w = write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if w < 0 {
                    if errno == EINTR { continue }
                    return
                }
                offset += w
            }
        }
    }
}
