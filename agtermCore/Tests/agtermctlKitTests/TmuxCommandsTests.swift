import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

/// The requests the tmux group builds. The mirror label is the point: `tmux attach` names a workspace it
/// creates, so it must ride `workspaceName` and refuse the `--workspace` address flag every other command
/// takes.
struct TmuxCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func tmuxAttachWithHostAndOptions() throws {
        // the mirror label maps to `workspaceName`, not `workspace` (which is an id/prefix address
        // everywhere else in the protocol) — attach CREATES its workspace rather than addressing one.
        let expected = ControlRequest(cmd: .tmuxAttach,
                                      args: ControlArgs(name: "dev", workspaceName: "servers", host: "user@host"))
        #expect(try request(["tmux", "attach", "user@host", "--session", "dev", "--workspace-name", "servers"]) == expected)
    }

    @Test func tmuxAttachRejectsWorkspaceAddressFlag() {
        #expect(throws: (any Error).self) {
            try Agtermctl.parseAsRoot(["tmux", "attach", "user@host", "--workspace", "servers"])
        }
    }

    @Test func tmuxAttachDefaultsSessionAndWorkspaceNil() throws {
        #expect(try request(["tmux", "attach", "user@host"])
            == ControlRequest(cmd: .tmuxAttach, args: ControlArgs(name: nil, workspaceName: nil, host: "user@host")))
    }

    @Test func tmuxAttachRequiresHost() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["tmux", "attach"]) }
    }

    @Test func tmuxListTakesNoTarget() throws {
        #expect(try request(["tmux", "list"]) == ControlRequest(cmd: .tmuxList))
    }

    @Test func tmuxDetachWithAndWithoutConnectionId() throws {
        #expect(try request(["tmux", "detach", "9f3c"]) == ControlRequest(cmd: .tmuxDetach, target: "9f3c"))
        #expect(try request(["tmux", "detach"]) == ControlRequest(cmd: .tmuxDetach, target: nil))
    }

    @Test func tmuxKillWithConnectionId() throws {
        #expect(try request(["tmux", "kill", "9f3c"]) == ControlRequest(cmd: .tmuxKill, target: "9f3c"))
    }
}
