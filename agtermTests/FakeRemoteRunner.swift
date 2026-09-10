import Foundation
@testable import agterm
import agtermCore

/// Records what it was asked to run and answers with a canned result, so the remote commands are covered
/// without a second Mac.
final class FakeRemoteRunner: RemoteCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let result: RemoteCommandResult
    private let beforeReturn: (@MainActor @Sendable () -> Void)?

    var invocations: [[String]] { lock.withLock { recorded } }

    init(result: RemoteCommandResult, beforeReturn: (@MainActor @Sendable () -> Void)? = nil) {
        self.beforeReturn = beforeReturn
        self.result = result
    }

    func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
        lock.withLock { recorded.append(argv) }
        await beforeReturn?()
        return result
    }
}
