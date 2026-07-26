public enum TmuxWindowList {
    /// Parse the reply block of `list-windows -F '#{window_id} #{window_layout} #{window_name}'`.
    ///
    /// The format string puts the two SPACE-FREE fields first — `window_id` (`@N`) and `window_layout`
    /// (a comma/brace checksum, never spaces) — and the free-form `window_name` LAST, so a name that
    /// contains spaces, parentheses, or a trailing `*`/`-` survives verbatim. That is why we drive
    /// `-F` instead of parsing tmux's human `list-windows` display (`name (N panes) … [layout …]`),
    /// which is ambiguous to parse back: `api (prod)` would truncate at the first `" ("` and `build-`
    /// would lose its trailing dash to flag-stripping.
    public static func parse(_ blockLines: [String]) -> [(id: TmuxWindowID, name: String, layout: String)] {
        var result: [(id: TmuxWindowID, name: String, layout: String)] = []
        for line in blockLines {
            // Split off id and layout; everything after the second space is the (possibly space- or
            // paren-bearing) name. omittingEmptySubsequences: false keeps an empty name field intact.
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 2, fields[0].hasPrefix("@") else { continue }
            let id = TmuxWindowID(String(fields[0]))
            let layout = String(fields[1])
            let name = fields.count >= 3 ? String(fields[2]) : ""
            result.append((id, name, layout))
        }
        return result
    }
}
