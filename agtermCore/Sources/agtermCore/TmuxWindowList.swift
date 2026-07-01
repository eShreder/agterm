public enum TmuxWindowList {
    public static func parse(_ blockLines: [String]) -> [(id: TmuxWindowID, name: String)] {
        var result: [(id: TmuxWindowID, name: String)] = []
        for line in blockLines {
            // Window id: the whitespace token beginning with '@'.
            guard let idToken = line.split(separator: " ").first(where: { $0.hasPrefix("@") })
            else { continue }
            // Name: text after the first ": " up to the first " (".
            guard let colon = line.range(of: ": ") else { continue }
            let afterColon = line[colon.upperBound...]
            let namePart = afterColon.range(of: " (").map { String(afterColon[..<$0.lowerBound]) }
                ?? String(afterColon)
            // Strip a trailing tmux flag char ('*' active / '-' last).
            var name = namePart
            if let last = name.last, last == "*" || last == "-" { name.removeLast() }
            result.append((TmuxWindowID(String(idToken)), name))
        }
        return result
    }
}
