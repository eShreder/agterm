public enum TmuxLayout {
    public static func panes(in layout: String) -> (panes: [TmuxPaneID], hasSplit: Bool) {
        let hasSplit = layout.contains("{") || layout.contains("[")
        var panes: [TmuxPaneID] = []
        // Replace group delimiters with commas so cells become a flat comma list, then
        // walk cells of the form "WxH,x,y,pane". A pane id is the 4th field of each
        // 4-field cell; container cells have only 3 fields (WxH,x,y) before their group.
        let flattened = layout.map { ch -> Character in
            (ch == "{" || ch == "}" || ch == "[" || ch == "]") ? "," : ch
        }
        let fields = String(flattened).split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        // Scan for the "WxH" marker; the pane id (if any) is the 3rd field after it.
        var i = 0
        while i < fields.count {
            if fields[i].contains("x"), i + 3 < fields.count,
               Int(fields[i + 1]) != nil, Int(fields[i + 2]) != nil, Int(fields[i + 3]) != nil,
               !fields[i + 3].contains("x") {
                // WxH , x , y , paneId  — but only when field[i+3] is a pane id, i.e. the
                // NEXT field (i+4) is another WxH or end, not part of this cell.
                let next = i + 4 < fields.count ? fields[i + 4] : ""
                if next.isEmpty || next.contains("x") {
                    panes.append(TmuxPaneID("%\(fields[i + 3])"))
                }
            }
            i += 1
        }
        return (panes, hasSplit)
    }
}
