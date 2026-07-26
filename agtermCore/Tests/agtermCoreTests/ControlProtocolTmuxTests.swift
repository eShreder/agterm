import Foundation
import Testing
@testable import agtermCore

/// The `tmux.*` wire shapes: the commands, the `tmux.list` payload, and the tree node's `tmuxWindow`/
/// `tmuxPane` read-back, which must stay absent for a local session rather than encode as null.
struct ControlProtocolTmuxTests {
    private func roundTrip(_ request: ControlRequest) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))
    }

    private func roundTrip(_ response: ControlResponse) throws -> ControlResponse {
        try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response))
    }

    @Test func tmuxCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .tmuxAttach, args: ControlArgs(name: "main", host: "user@host")),
            ControlRequest(cmd: .tmuxAttach, args: ControlArgs(workspaceName: "servers", host: "user@host")),
            ControlRequest(cmd: .tmuxDetach, target: "9f3c"),
            ControlRequest(cmd: .tmuxList),
            ControlRequest(cmd: .tmuxKill, target: "9f3c"),
        ]
        for request in cases { #expect(try roundTrip(request) == request) }
    }

    @Test func tmuxListResultRoundTrips() throws {
        let response = ControlResponse(ok: true, result: ControlResult(tmuxConnections: [
            ControlTmuxNode(id: "9f3c", host: "user@host", session: "dev", windows: ["editor", "logs"]),
            ControlTmuxNode(id: "0a12", host: "local", session: nil, windows: ["window"]),
        ]))
        #expect(try roundTrip(response) == response)
    }

    @Test func treeSessionNodeRoundTripsWithTmuxIdentity() throws {
        // the read side of `tmux:` addressing: the mirrored window + its leading pane ride the tree node.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false,
                                         backedByZmx: nil, tmuxWindow: "@7", tmuxPane: "%12")
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        let node = decoded.result?.tree?.workspaces.first?.sessions.first
        #expect(node?.tmuxWindow == "@7")
        #expect(node?.tmuxPane == "%12")
    }

    @Test func treeSessionNodeOmitsTmuxIdentityWhenNil() throws {
        // a local (non-tmux-backed) session has no mirrored window/pane — the keys must be omitted, not
        // emitted as null.
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false,
                                         backedByZmx: nil)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("tmuxWindow"), "a nil tmuxWindow must be omitted from the JSON; got \(json)")
        #expect(!json.contains("tmuxPane"), "a nil tmuxPane must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.tmuxWindow == nil)
        #expect(decoded.tmuxPane == nil)
    }
}
