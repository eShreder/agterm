// DEV-ONLY harness — the tmux -CC fork-viability gate (Phase 1).
//
// Behind the `AGTERM_HEADLESS_HARNESS=1` env gate, this creates a PTY-less (headless) libghostty
// surface in its own window, feeds it external VT bytes via `ghostty_surface_write_output` (a red
// "hello", the VISUAL render check the controller/user confirms on screen), and PROGRAMMATICALLY
// proves the input seam by injecting synthetic text via `ghostty_surface_text` and observing it come
// back through the surface's `on_input` callback. Every step self-verifies into
// `/tmp/agterm-headless-harness.log`, truncated fresh each run.
//
// A normal launch (no env var) never touches any of this — `HeadlessHarness.start()` is called only
// when `isEnabled` is true, so no headless surface and no extra window exist otherwise.

import AppKit
import Foundation

@MainActor
enum HeadlessHarness {
    /// Where the self-verification lines land. The controller reads this after the gate run.
    static let logPath = "/tmp/agterm-headless-harness.log"

    /// The env gate. Only when this is true does any harness code path run.
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["AGTERM_HEADLESS_HARNESS"] == "1" }

    /// Kept alive for the app's lifetime so the surface/window aren't torn down mid-gate.
    private static var window: NSWindow?
    private static var view: GhosttySurfaceView?

    /// Stand up the headless surface + window and schedule the render/input/read-back checks. Called from
    /// `applicationDidFinishLaunching` (after libghostty boots) ONLY when `isEnabled`.
    static func start() {
        truncateLog()
        log("HARNESS: start (pid \(ProcessInfo.processInfo.processIdentifier))")

        let view = GhosttySurfaceView(workingDirectory: NSHomeDirectory())
        view.makeHeadless { data in
            // on_input fired: the input seam works. Log every received chunk as hex.
            log("INPUT-CHECK: got \(hex(data))")
        }
        view.headlessOnResize = { cols, rows in
            log("RESIZE: \(cols)x\(rows)")
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "agterm headless harness"
        window.isReleasedWhenClosed = false
        window.contentView = view // triggers viewDidMoveToWindow → createHeadlessSurface
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        Self.window = window
        Self.view = view
        log("HARNESS: window up, surface \(view.surface == nil ? "PENDING" : "live")")

        // 1) VISUAL render check: feed red "hello" once the surface is live.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            view.writeOutput(Data("\u{1b}[31mhello\u{1b}[0m\r\n".utf8))
            log("WRITE: fed red hello via write_output")
        }

        // 2) PROGRAMMATIC input check: inject synthetic input; on_input should log "INPUT-CHECK: got 616263".
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            view.sendText("abc")
            log("SENDTEXT: injected abc via ghostty_surface_text")
        }

        // 3) BEST-EFFORT render read-back: confirm the written bytes actually rendered.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            if let text = view.readViewportText() {
                let flat = text.split(whereSeparator: { $0.isNewline || $0 == " " }).joined(separator: " ")
                if text.contains("hello") {
                    log("RENDER-CHECK: contains hello — \(flat)")
                } else {
                    log("RENDER-CHECK: read viewport but no hello — \(flat)")
                }
            } else {
                log("RENDER-CHECK: skipped (visual only)")
            }
        }
    }

    // MARK: - Logging

    private static func truncateLog() {
        FileManager.default.createFile(atPath: logPath, contents: Data())
    }

    private static func log(_ line: String) {
        guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
