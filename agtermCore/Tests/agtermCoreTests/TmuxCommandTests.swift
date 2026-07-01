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

    @Test func encodesListWindows() {
        #expect(TmuxCommandEncoder.encode(.listWindows) == "list-windows")
    }

    @Test func encodesKillSession() {
        #expect(TmuxCommandEncoder.encode(.killSession) == "kill-session")
    }

    @Test func encodesResizeAndDetach() {
        #expect(TmuxCommandEncoder.encode(.resizeClient(cols: 80, rows: 24)) == "refresh-client -C 80x24")
        #expect(TmuxCommandEncoder.encode(.detachClient) == "detach-client")
    }

    // send-keys uses -H (hex) so arbitrary bytes (control chars, UTF-8) round-trip safely.
    @Test func encodesSendKeysAsHex() {
        // "ab" + newline (0x0a) -> "61 62 0a"
        let cmd = TmuxCommand.sendKeys(pane: TmuxPaneID("%0"), bytes: [0x61, 0x62, 0x0A])
        #expect(TmuxCommandEncoder.encode(cmd) == "send-keys -t %0 -H 61 62 0a")
    }
}
