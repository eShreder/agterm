import Foundation

/// The tmux `-CC` control-mode transport. Combines `PTYProcess` (spawn + async read) with
/// `TmuxControlParser` (line -> `TmuxEvent`) and `TmuxCommandEncoder` (outbound commands).
///
/// A control-mode command (e.g. `ssh host -- tmux -CC attach`) may print interactive
/// ssh-auth output BEFORE tmux enters control mode. The gateway splits that "bootstrap"
/// phase from the control stream by detecting the `\u{1b}P1000p` DCS handshake: bytes
/// before the marker are surfaced raw via `onBootstrapBytes` (so the UI can show the auth
/// prompt and forward keystrokes via `writeBootstrap`); on the marker it fires `onHandshake`
/// and feeds everything from the marker onward (inclusive — the parser strips the DCS intro)
/// into the parser, forwarding each event to `onEvent`.
///
/// `@unchecked Sendable`: `ingest` runs on `PTYProcess`'s background queue, so the shared
/// parse state (`parser`, `inControlMode`, `preHandshake`) is guarded by `lock`.
public final class TmuxGateway: @unchecked Sendable {
    public struct Callbacks: Sendable {
        public var onBootstrapBytes: @Sendable (Data) -> Void
        public var onHandshake: @Sendable () -> Void
        public var onEvent: @Sendable (TmuxEvent) -> Void
        public var onExit: @Sendable (Int32) -> Void
        public init(onBootstrapBytes: @escaping @Sendable (Data) -> Void,
                    onHandshake: @escaping @Sendable () -> Void,
                    onEvent: @escaping @Sendable (TmuxEvent) -> Void,
                    onExit: @escaping @Sendable (Int32) -> Void) {
            self.onBootstrapBytes = onBootstrapBytes
            self.onHandshake = onHandshake
            self.onEvent = onEvent
            self.onExit = onExit
        }
    }

    private let callbacks: Callbacks
    private let pty = PTYProcess()
    private let lock = NSLock()
    private var parser = TmuxControlParser()
    private var inControlMode = false
    private var preHandshake = Data()
    private static let marker = Data("\u{1b}P1000p".utf8)

    public init(callbacks: Callbacks) { self.callbacks = callbacks }

    /// Spawn the control-mode command in a pty. `onData`/`onExit` fire on the pty's
    /// background queue; `ingest` re-serializes with `lock`. Throws on spawn failure.
    public func start(path: String, args: [String], env: [String: String]) throws {
        try pty.start(path: path, args: args, env: env,
                      onData: { [weak self] in self?.ingest($0) },
                      onExit: { [weak self] in self?.callbacks.onExit($0) })
    }

    private func ingest(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if inControlMode {
            for event in parser.feed(Array(data)) { callbacks.onEvent(event) }
            return
        }
        preHandshake.append(data)
        if let range = preHandshake.range(of: Self.marker) {
            // Everything before the marker is bootstrap output.
            let before = preHandshake[..<range.lowerBound]
            if !before.isEmpty { callbacks.onBootstrapBytes(Data(before)) }
            callbacks.onHandshake()
            inControlMode = true
            let fromMarker = Data(preHandshake[range.lowerBound...])   // include the DCS intro
            preHandshake.removeAll()
            for event in parser.feed(Array(fromMarker)) { callbacks.onEvent(event) }
        } else {
            // No marker yet: flush what we have as bootstrap, but KEEP a trailing partial
            // marker prefix in the buffer so a marker split across reads still matches.
            let keep = min(preHandshake.count, Self.marker.count - 1)
            let flush = preHandshake.count - keep
            if flush > 0 {
                callbacks.onBootstrapBytes(Data(preHandshake.prefix(flush)))
                preHandshake.removeFirst(flush)
            }
        }
    }

    /// Encode `command` and write it as a `"<line>\n"` to the control stream.
    public func send(_ command: TmuxCommand) {
        pty.write(Data((TmuxCommandEncoder.encode(command) + "\n").utf8))
    }

    /// Write raw bytes to the pty stdin — user keystrokes during the ssh-auth phase.
    public func writeBootstrap(_ data: Data) { pty.write(data) }

    /// Terminate the child. The gateway owns the `PTYProcess` lifecycle and must always
    /// terminate it — `PTYProcess.deinit` does not reliably close the fd on its own.
    public func stop() { pty.terminate() }
}
