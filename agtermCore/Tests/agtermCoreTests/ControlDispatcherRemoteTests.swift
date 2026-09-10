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

    @Test func listRoutesTheHost() async {
        let actions = MockControlActions()
        _ = await dispatch(ControlRequest(cmd: .remoteList, args: ControlArgs(host: " devbox ")), actions)
        #expect(actions.calls == [.remoteList(host: "devbox")])
    }

    @Test func attachRoutesEveryArgumentAndDefaultsCreateToFalse() async {
        let actions = MockControlActions()
        _ = await dispatch(ControlRequest(cmd: .remoteAttach, target: "api",
                                          args: ControlArgs(host: "devbox", window: "w1")), actions)
        _ = await dispatch(ControlRequest(cmd: .remoteAttach, target: "api",
                                          args: ControlArgs(host: "devbox", create: true, command: "claude")), actions)
        #expect(actions.calls == [
            .remoteAttach(host: "devbox", name: "api", window: "w1", create: false, command: nil),
            .remoteAttach(host: "devbox", name: "api", window: nil, create: true, command: "claude"),
        ])
    }

    @Test func killRoutesOnlyWithForce() async {
        let actions = MockControlActions()
        let refused = await dispatch(ControlRequest(cmd: .remoteKill, target: "api",
                                                    args: ControlArgs(host: "devbox")), actions)
        #expect(refused?.error == "remote.kill requires --force")
        _ = await dispatch(ControlRequest(cmd: .remoteKill, target: "api",
                                          args: ControlArgs(force: true, host: "devbox")), actions)
        #expect(actions.calls == [.remoteKill(host: "devbox", name: "api")])
    }

    @Test(arguments: [Command.remoteList, .remoteAttach, .remoteKill])
    func everyRemoteCommandRequiresAHost(command: Command) async {
        let actions = MockControlActions()
        let response = await dispatch(ControlRequest(cmd: command, target: "api", args: ControlArgs(force: true)), actions)
        #expect(response?.error == "\(command.rawValue) requires a host")
        #expect(actions.calls.isEmpty)
    }

    @Test(arguments: [Command.remoteAttach, .remoteKill])
    func attachAndKillRequireASessionName(command: Command) async {
        let actions = MockControlActions()
        let response = await dispatch(ControlRequest(cmd: command, args: ControlArgs(force: true, host: "devbox")), actions)
        #expect(response?.error == "\(command.rawValue) requires a session name")
        #expect(actions.calls.isEmpty)
    }

    // the unresolved-session message names the session, so a control character reaching it would be
    // printed to a terminal by agtermctl after JSON decoding
    @Test(arguments: ["api\nrm -rf /", "a b", "a/b", "-rf"])
    func attachRefusesAnUnsafeNameBeforeTheHostIsReached(_ name: String) async {
        let actions = MockControlActions()
        let response = await dispatch(ControlRequest(cmd: .remoteAttach, target: name,
                                                     args: ControlArgs(host: "devbox")), actions)
        #expect(response?.error == "invalid remote session")
        #expect(actions.calls.isEmpty)
    }

    @Test func aCommandWithoutCreateIsRefused() async {
        let actions = MockControlActions()
        let response = await dispatch(ControlRequest(cmd: .remoteAttach, target: "api",
                                                     args: ControlArgs(host: "devbox", command: "claude")), actions)
        #expect(response?.error == "remote.attach --command requires --create")
        #expect(actions.calls.isEmpty)
    }

    // agtermCore is a library the agterm-linux fork consumes, so every Mac-only requirement ships a default
    @Test func theDefaultsRefuseByName() {
        #expect(ControlActionsUnsupported.message("remote.list") == "remote.list is not supported on this platform")
    }
}
