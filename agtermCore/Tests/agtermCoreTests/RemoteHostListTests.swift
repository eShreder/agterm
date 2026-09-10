import Foundation
import Testing
@testable import agtermCore

/// What the far side's own `zmx list` prints, read back row by row.
struct RemoteHostListTests {
    private static let rows = """
    name=api\tpid=22598\tclients=1\tcreated=1788988802\tcwd=file://devbox/home/me/api\tproject=api\trole=worker
      name=build\tpid=22600\tclients=0\tcreated=1788988810
    name=agterm-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1\tpid=1\tclients=1
    No sessions found in /tmp/zmx-1000
    """

    @Test func parsesEveryFieldAndKeepsTheRestAsLabels() throws {
        let sessions = RemoteHostList.parse(Self.rows)
        let api = try #require(sessions.first { $0.name == "api" })
        #expect(api.clients == 1)
        #expect(api.created == 1_788_988_802)
        #expect(api.cwd == "/home/me/api")
        #expect(api.labels == ["project": "api", "role": "worker"])
    }

    @Test func aRowWithoutCwdOrLabelsStillParses() throws {
        let build = try #require(RemoteHostList.parse(Self.rows).first { $0.name == "build" })
        #expect(build.clients == 0)
        #expect(build.cwd == nil)
        #expect(build.labels.isEmpty)
    }

    // agterm's own live-pane daemons on a host that also runs agterm belong to `zmx tree`
    @Test func omitsAgtermDaemonNamesAndProseLines() {
        #expect(RemoteHostList.parse(Self.rows).map(\.name) == ["api", "build"])
    }

    @Test func anEmptyListingIsEmpty() {
        #expect(RemoteHostList.parse("").isEmpty)
        #expect(RemoteHostList.parse("No sessions found in /tmp/zmx-1000\n").isEmpty)
    }

    @Test func aPercentEncodedPathIsDecoded() throws {
        let row = "name=x\tclients=0\tcwd=file://h/home/me/My%20Project"
        #expect(try #require(RemoteHostList.parse(row).first).cwd == "/home/me/My Project")
    }
}
