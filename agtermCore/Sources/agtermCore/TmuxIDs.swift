public struct TmuxWindowID: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct TmuxPaneID: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

public struct TmuxSessionID: Hashable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}
