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

    @Test func layoutChangeMapsLeadingPaneAndRoutesOutput() {
        var m = TmuxSessionModel()
        _ = m.handle(.windowAdd(TmuxWindowID("@0")))
        // Single-pane layout: pane %0 belongs to window @0.
        #expect(m.handle(.layoutChange(window: TmuxWindowID("@0"), layout: "b25d,80x24,0,0,0")) == [])
        // %output %0 now routes to window @0.
        #expect(m.handle(.output(pane: TmuxPaneID("%0"), bytes: [0x68, 0x69]))
                == [.routeOutput(window: TmuxWindowID("@0"), bytes: [0x68, 0x69])])
    }

    @Test func splitLayoutTakesLeadingPaneWithDiagnostic() {
        var m = TmuxSessionModel()
        _ = m.handle(.windowAdd(TmuxWindowID("@0")))
        let effects = m.handle(.layoutChange(window: TmuxWindowID("@0"),
                                             layout: "0206,80x24,0,0{40x24,0,0,0,39x24,41,0,2}"))
        // The window has a split; we keep the leading pane %0 and emit a diagnostic.
        #expect(effects == [.diagnostic("window @0 has a split; showing leading pane %0")])
        // Output from the leading pane routes; output from the ignored pane does not.
        #expect(m.handle(.output(pane: TmuxPaneID("%0"), bytes: [0x41])) == [.routeOutput(window: TmuxWindowID("@0"), bytes: [0x41])])
        #expect(m.handle(.output(pane: TmuxPaneID("%2"), bytes: [0x42])) == [])
    }

    @Test func outputForUnknownPaneIsDropped() {
        var m = TmuxSessionModel()
        #expect(m.handle(.output(pane: TmuxPaneID("%7"), bytes: [0x41])) == [])
    }

    @Test func exitTearsDown() {
        var m = TmuxSessionModel()
        _ = m.handle(.windowAdd(TmuxWindowID("@0")))
        #expect(m.handle(.exit(reason: nil)) == [.tearDown])
    }
}
