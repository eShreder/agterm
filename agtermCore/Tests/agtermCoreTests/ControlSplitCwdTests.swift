import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlSplitCwdTests {
    @Test(arguments: [false, true])
    func splitCwdReportsEachFallbackEvenWhenHidden(shown: Bool) throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/primary"))
        session.hasSplit = true
        session.isSplit = shown
        for (initial, reported, expected): (String?, String?, String) in [
            (nil, nil, "/primary"), ("/restored", nil, "/restored"), ("/restored", "/live", "/live"),
        ] {
            session.initialSplitCwd = initial
            session.splitCwd = reported
            let node = store.controlTree().workspaces[0].sessions[0]
            let data = try JSONEncoder().encode(node)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["splitCwd"] as? String == expected)
            #expect(node.cwd == "/primary")
            #expect(try JSONDecoder().decode(ControlSessionNode.self, from: data) == node)
        }
    }

    @Test func noSplitOmitsTheDirectoryEvenWithStaleSplitFields() throws {
        let store = makeStore()
        let workspace = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/primary"))
        session.splitCwd = "/stale"
        session.initialSplitCwd = "/restored"
        let node = store.controlTree().workspaces[0].sessions[0]
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any])
        #expect(json["splitCwd"] == nil)
    }

    @Test func oldNodesStillDecodeAndNewNodesPreserveSplitCwd() throws {
        let old = ControlSessionNode(id: "s", name: "shell", cwd: "/main", active: true, split: true)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        #expect(try JSONDecoder().decode(ControlSessionNode.self, from: JSONEncoder().encode(old)) == old)
        json["splitCwd"] = "/other"
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: JSONSerialization.data(withJSONObject: json))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(encoded["splitCwd"] as? String == "/other")
    }
}
