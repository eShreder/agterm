import ArgumentParser
import Foundation
import Testing
@testable import agtermCore
@testable import agtermctlKit

/// The requests the remote group builds and the rows it prints. Nothing here touches a socket.
struct RemoteCommandsTests {
    @Test func listSendsTheHostAsAnArgument() throws {
        let request = try Remote.List.parse(["devbox"]).makeRequest()
        #expect(request.cmd == .remoteList)
        #expect(request.args?.host == "devbox")
        #expect(request.target == nil)
    }

    @Test func attachSendsHostNameWindowCreateAndCommand() throws {
        let plain = try Remote.Attach.parse(["devbox", "api"]).makeRequest()
        #expect(plain.cmd == .remoteAttach)
        #expect(plain.target == "api")
        #expect(plain.args?.host == "devbox")
        #expect(plain.args?.create == nil, "absent rather than false, like every optional flag on the wire")
        #expect(plain.args?.command == nil)

        let full = try Remote.Attach.parse(["devbox", "api", "--create", "--command", "claude", "--window", "w1"]).makeRequest()
        #expect(full.args?.create == true)
        #expect(full.args?.command == "claude")
        #expect(full.args?.window == "w1")
        #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(full)) == full)
    }

    @Test func attachRefusesACommandWithoutCreateBeforeSendingAnything() {
        #expect(throws: (any Error).self) { try Remote.Attach.parse(["devbox", "api", "--command", "claude"]) }
    }

    @Test(arguments: [[], ["devbox"]])
    func attachAndKillNeedBothAHostAndAName(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try Remote.Attach.parse(arguments) }
        #expect(throws: (any Error).self) { try Remote.Kill.parse(arguments + ["--force"]) }
    }

    @Test func killRequiresForceAndSendsIt() throws {
        #expect(throws: (any Error).self) { try Remote.Kill.parse(["devbox", "api"]) }
        let request = try Remote.Kill.parse(["devbox", "api", "--force"]).makeRequest()
        #expect(request.cmd == .remoteKill)
        #expect(request.target == "api")
        #expect(request.args?.host == "devbox")
        #expect(request.args?.force == true)
    }

    @Test func attachEchoesTheSessionItCreated() throws {
        #expect(try Remote.Attach.parse(["devbox", "api"]).echoesResultID)
        #expect(try !Remote.List.parse(["devbox"]).echoesResultID)
    }

    @Test func listRendersOneRowPerSessionAndSaysWhenThereAreNone() {
        let rows = [
            ControlRemoteHostSession(name: "api", clients: 1, cwd: "/home/me/api", labels: ["role": "worker", "project": "api"]),
            ControlRemoteHostSession(name: "build", clients: 0),
        ]
        #expect(SocketClient.formatRemoteHostSessions(rows) == """
          api  1 client  /home/me/api  project=api role=worker
          build  0 clients
        """)
        #expect(SocketClient.formatRemoteHostSessions([]) == "no sessions")
    }

    @Test func theRootCommandListsRemote() {
        #expect(Agtermctl.configuration.subcommands.contains { $0 == Remote.self })
    }
}
