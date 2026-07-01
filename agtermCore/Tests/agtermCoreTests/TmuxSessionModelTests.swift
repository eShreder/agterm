import Testing
@testable import agtermCore

struct TmuxSessionModelTests {
    @Test func windowAddCreatesSession() {
        var m = TmuxSessionModel()
        #expect(m.handle(.windowAdd(TmuxWindowID("@2"))) == [.createSession(window: TmuxWindowID("@2"), name: "")])
    }

    @Test func windowRenamedAfterAddRenamesSession() {
        var m = TmuxSessionModel()
        _ = m.handle(.windowAdd(TmuxWindowID("@2")))
        #expect(m.handle(.windowRenamed(TmuxWindowID("@2"), name: "logs"))
                == [.renameSession(window: TmuxWindowID("@2"), name: "logs")])
    }

    @Test func windowCloseRemovesTrackedSessionOnly() {
        var m = TmuxSessionModel()
        _ = m.handle(.windowAdd(TmuxWindowID("@2")))
        #expect(m.handle(.windowClose(TmuxWindowID("@2"), unlinked: false))
                == [.removeSession(window: TmuxWindowID("@2"))])
        // An unlinked-close for a window we never tracked is ignored (belongs to another session).
        #expect(m.handle(.windowClose(TmuxWindowID("@9"), unlinked: true)) == [])
    }

    @Test func renameOfUntrackedWindowIsIgnored() {
        var m = TmuxSessionModel()
        #expect(m.handle(.windowRenamed(TmuxWindowID("@5"), name: "x")) == [])
    }
}
