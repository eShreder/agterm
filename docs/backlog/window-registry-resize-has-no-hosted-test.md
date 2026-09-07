---
worth: later
where: agterm/WindowRegistry.swift:68
added: 2026-09-07
---
# WindowRegistry.resize has no hosted test

`WindowRegistry.resize` is the one place the display bound is applied to a control request, and no
`agtermTests` case exercises it. `WindowGeometry.clampSize` is covered host-free, but the wiring above
it (screen resolution, the fixed top edge, the `minSize` floor) is reached only through
`window.resize` in three UI tests. `ControlServerAskTests` already registers a real `NSWindow` with
`WindowRegistry.shared`, so the same setup can drive `resize` directly and assert the applied frame.
Surfaced while reviewing discussion #559.
