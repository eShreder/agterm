import Foundation
import Testing
@testable import agtCore

@MainActor
struct WorkspaceTests {
    @Test func unseenCountSumsItsSessions() {
        let a = Session(initialCwd: "/a")
        let b = Session(initialCwd: "/b")
        a.unseenCount = 2
        b.unseenCount = 3
        let workspace = Workspace(name: "work", sessions: [a, b])
        #expect(workspace.unseenCount == 5)
    }

    @Test func unseenCountIsZeroWhenNonePending() {
        let workspace = Workspace(name: "empty", sessions: [Session(initialCwd: "/a")])
        #expect(workspace.unseenCount == 0)
    }
}
