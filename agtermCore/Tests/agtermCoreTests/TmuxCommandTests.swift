import Testing
@testable import agtermCore

struct TmuxCommandTests {
    @Test func encodesWindowCommands() {
        #expect(TmuxCommandEncoder.encode(.newWindow(name: nil)) == "new-window")
        #expect(TmuxCommandEncoder.encode(.newWindow(name: "logs")) == "new-window -n 'logs'")
        #expect(TmuxCommandEncoder.encode(.killWindow(TmuxWindowID("@1"))) == "kill-window -t @1")
        #expect(TmuxCommandEncoder.encode(.renameWindow(TmuxWindowID("@0"), name: "api")) == "rename-window -t @0 'api'")
    }

    // A name with spaces (or a single quote) must be single-quoted so tmux parses it as ONE argument.
    @Test func quotesWindowNamesWithSpaces() {
        #expect(TmuxCommandEncoder.encode(.renameWindow(TmuxWindowID("@0"), name: "my project"))
                == "rename-window -t @0 'my project'")
        #expect(TmuxCommandEncoder.encode(.newWindow(name: "a'b"))
                == "new-window -n 'a'\\''b'")
    }

    // CR/LF must be STRIPPED from names: the control stream is line-delimited, so a raw newline in a name
    // would break out of the single-quoted argument and let the tail parse as a separate tmux command
    // (command injection). Single-quoting alone does not stop this.
    @Test func stripsLineBreaksFromNamesToPreventInjection() {
        #expect(TmuxCommandEncoder.encode(.renameWindow(TmuxWindowID("@0"), name: "api\nkill-server"))
                == "rename-window -t @0 'apikill-server'")
        #expect(TmuxCommandEncoder.encode(.renameWindow(TmuxWindowID("@0"), name: "a\r\nb"))
                == "rename-window -t @0 'ab'")
        #expect(TmuxCommandEncoder.encode(.newWindow(name: "x\ny"))
                == "new-window -n 'xy'")
    }

    // list-windows drives explicit -F fields (id + layout first, free-form name last) so the parser
    // recovers names with spaces/parens/trailing flag chars — the human display is ambiguous.
    @Test func encodesListWindows() {
        #expect(TmuxCommandEncoder.encode(.listWindows)
                == "list-windows -F '#{window_id} #{window_layout} #{window_name}'")
    }

    @Test func encodesCapturePane() {
        #expect(TmuxCommandEncoder.encode(.capturePane(TmuxPaneID("%0"))) == "capture-pane -p -e -t %0")
        #expect(TmuxCommandEncoder.encode(.capturePane(TmuxPaneID("%12"))) == "capture-pane -p -e -t %12")
    }

    @Test func encodesKillSession() {
        #expect(TmuxCommandEncoder.encode(.killSession) == "kill-session")
    }

    // Comma form: tmux ≤3.1 parses ONLY `-C W,H` (`WxH` errors); ≥3.2 accepts both.
    @Test func encodesResizeAndDetach() {
        #expect(TmuxCommandEncoder.encode(.resizeClient(cols: 80, rows: 24)) == "refresh-client -C 80,24")
        #expect(TmuxCommandEncoder.encode(.detachClient) == "detach-client")
    }

    // send-keys uses -H (hex) so arbitrary bytes (control chars, UTF-8) round-trip safely.
    @Test func encodesSendKeysAsHex() {
        // "ab" + newline (0x0a) -> "61 62 0a"
        let cmd = TmuxCommand.sendKeys(pane: TmuxPaneID("%0"), bytes: [0x61, 0x62, 0x0A])
        #expect(TmuxCommandEncoder.encode(cmd) == "send-keys -t %0 -H 61 62 0a")
    }
}
