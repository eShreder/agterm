import Foundation

/// A framed message on the per-window relay socket between the app's `TmuxController` and the
/// `agtermctl tmux-pipe` child. Both directions use the same framing.
///
/// This is the seam that lets a remote `tmux -CC` window render in a STOCK (unpatched) agterm
/// surface: the window is a normal exec session whose child process (`tmux-pipe`) relays its PTY
/// to the in-app tmux gateway over a unix socket, instead of the app painting bytes into a
/// PTY-less "headless" surface (which required forking libghostty).
public enum RelayFrame: Equatable, Sendable {
    /// Raw terminal bytes. app→child = tmux `%output` (written to the surface); child→app =
    /// keystrokes the user typed into the surface (forwarded to tmux as `send-keys`).
    case data([UInt8])
    /// A resize event (child→app): the child's PTY changed size (`SIGWINCH`), forwarded to tmux
    /// as `refresh-client -C <cols>x<rows>`.
    case resize(cols: UInt16, rows: UInt16)
}

/// Encoder + incremental decoder for the relay wire format `[type:1][len:UInt32 BE][payload]`.
/// Host-free and byte-exact so the app bridge and the CLI child can never drift.
///
/// - `type 0` = data: payload is the raw bytes.
/// - `type 1` = resize: payload is `cols:UInt16 BE` + `rows:UInt16 BE` (len == 4).
///
/// A frame with an unknown type byte, or a resize whose payload isn't exactly 4 bytes, is DROPPED
/// (consumed; decoding continues at the next frame): the app and the `tmux-pipe` child ship in
/// lockstep from the same bundle, so version skew is impossible and a malformed frame means stream
/// corruption — folding its payload into `.data` would write the garbage into the terminal (or send
/// it to tmux as keystrokes).
public enum RelayCodec {
    private static let typeData: UInt8 = 0
    private static let typeResize: UInt8 = 1

    public static func encode(_ frame: RelayFrame) -> [UInt8] {
        switch frame {
        case .data(let bytes):
            return header(typeData, UInt32(bytes.count)) + bytes
        case .resize(let cols, let rows):
            let payload = beBytes16(cols) + beBytes16(rows)
            return header(typeResize, UInt32(payload.count)) + payload
        }
    }

    private static func header(_ type: UInt8, _ len: UInt32) -> [UInt8] {
        [type,
         UInt8((len >> 24) & 0xff), UInt8((len >> 16) & 0xff),
         UInt8((len >> 8) & 0xff), UInt8(len & 0xff)]
    }

    private static func beBytes16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }

    /// Buffers partial reads and yields whole frames as they complete. A single `feed` may return
    /// zero, one, or many frames — PTY/socket reads split and coalesce frames arbitrarily.
    public struct Decoder {
        private var buffer: [UInt8] = []
        public init() {}

        public mutating func feed(_ bytes: [UInt8]) -> [RelayFrame] {
            buffer += bytes
            var frames: [RelayFrame] = []
            while buffer.count >= 5 {
                let len = Int(buffer[1]) << 24 | Int(buffer[2]) << 16 | Int(buffer[3]) << 8 | Int(buffer[4])
                guard buffer.count >= 5 + len else { break }        // whole payload not in yet
                let type = buffer[0]
                let payload = Array(buffer[5 ..< 5 + len])
                buffer.removeSubrange(0 ..< 5 + len)
                if type == RelayCodec.typeData {
                    frames.append(.data(payload))
                } else if type == RelayCodec.typeResize, payload.count == 4 {
                    frames.append(.resize(cols: UInt16(payload[0]) << 8 | UInt16(payload[1]),
                                          rows: UInt16(payload[2]) << 8 | UInt16(payload[3])))
                }
                // else: unknown type / malformed resize — corruption, dropped (see the type doc)
            }
            return frames
        }
    }
}
