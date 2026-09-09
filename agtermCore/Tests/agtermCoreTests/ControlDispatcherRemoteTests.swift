import Foundation
import Testing
@testable import agtermCore

/// Dispatcher and wire coverage for the `remote` group: sessions on a host that runs zmx and no agterm.
@MainActor
struct ControlDispatcherRemoteTests {
    private func dispatch(_ request: ControlRequest, _ actions: MockControlActions) async -> ControlResponse? {
        await ControlDispatcher(actions: actions).dispatch(request)
    }

    @Test(arguments: [(Command.remoteList, "remote.list"), (.remoteAttach, "remote.attach"), (.remoteKill, "remote.kill")])
    func remoteCommandsKeepTheirWireNames(command: Command, wire: String) throws {
        let json = try #require(try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(ControlRequest(cmd: command))) as? [String: Any])
        #expect(json["cmd"] as? String == wire)
    }

    @Test func createAndRemoteSessionsSurviveTheWire() throws {
        let request = ControlRequest(cmd: .remoteAttach, target: "api",
                                     args: ControlArgs(host: "devbox", create: true, command: "claude"))
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)

        let session = ControlRemoteHostSession(name: "api", clients: 2, cwd: "/srv", created: 7, labels: ["k": "v"])
        let data = try JSONEncoder().encode(ControlResult(remoteSessions: [session]))
        #expect(try JSONDecoder().decode(ControlResult.self, from: data).remoteSessions == [session])
    }
}
