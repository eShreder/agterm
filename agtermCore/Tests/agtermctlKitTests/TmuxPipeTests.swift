import ArgumentParser
import Testing
@testable import agtermctlKit
@testable import agtermCore

// The relay's FRAMING lives in `RelayCodec` (covered by `RelayProtocolTests`); the poll loop is
// manually gated against a live `tmux -CC`. What is unit-testable here are the relay's cheap
// validation edges: a bad socket path must fail fast with a thrown error, never hang the child.
@Suite struct TmuxPipeTests {
    #if canImport(Darwin)
    @Test func connectToMissingSocketThrows() {
        #expect(throws: ValidationError.self) {
            try TmuxPipeRelay(socketPath: "/nonexistent/agterm-tmux-pipe-test.sock").run()
        }
    }

    @Test func overlongSocketPathThrows() {
        // sun_path caps at ~104 bytes on Darwin; the relay must reject, not truncate.
        #expect(throws: ValidationError.self) {
            try TmuxPipeRelay(socketPath: String(repeating: "a", count: 300)).run()
        }
    }
    #endif
}
