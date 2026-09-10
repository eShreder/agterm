import Foundation

/// One session on a host that runs zmx without agterm, as that host's own `zmx list` reports it.
public struct ControlRemoteHostSession: Codable, Sendable, Equatable {
    public let name: String
    public let clients: Int
    /// The path of the row's `cwd=file://host/path`, absent when zmx reported none.
    public let cwd: String?
    /// Unix seconds, as zmx prints them.
    public let created: Int?
    /// Every other key on the row: zmx labels such as `project=api`.
    public let labels: [String: String]

    public init(name: String, clients: Int, cwd: String? = nil, created: Int? = nil,
                labels: [String: String] = [:]) {
        self.name = name
        self.clients = clients
        self.cwd = cwd
        self.created = created
        self.labels = labels
    }
}

/// Reads `zmx list`: one row per session, tab-separated `key=value` fields, a leading indent on some rows,
/// and prose lines such as `No sessions found in …` that carry no `name=`.
public enum RemoteHostList {
    private static let builtinKeys: Set<String> = ["name", "pid", "clients", "created", "cwd"]

    public static func parse(_ text: String) -> [ControlRemoteHostSession] {
        text.split(separator: "\n").compactMap { line in
            var fields: [String: String] = [:]
            for field in line.split(separator: "\t") {
                let trimmed = field.trimmingCharacters(in: .whitespaces)
                guard let separator = trimmed.firstIndex(of: "=") else { continue }
                fields[String(trimmed[..<separator])] = String(trimmed[trimmed.index(after: separator)...])
            }
            guard let name = fields["name"], !name.isEmpty else { return nil }
            // agterm's own daemons on a host that also runs agterm are reached through `zmx tree`, where
            // their split and ownership are known
            guard !ZmxSupport.isDaemonName(name) else { return nil }
            return ControlRemoteHostSession(name: name,
                                            clients: fields["clients"].flatMap { Int($0) } ?? 0,
                                            cwd: fields["cwd"].flatMap(path(fromFileURI:)),
                                            created: fields["created"].flatMap { Int($0) },
                                            labels: fields.filter { !builtinKeys.contains($0.key) })
        }
    }

    /// `file://host/path` → `/path`, percent-decoded; a bare path passes through.
    static func path(fromFileURI value: String) -> String? {
        guard value.hasPrefix("file://") else { return value.isEmpty ? nil : value }
        let rest = value.dropFirst("file://".count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let path = String(rest[slash...])
        return path.removingPercentEncoding ?? path
    }
}
