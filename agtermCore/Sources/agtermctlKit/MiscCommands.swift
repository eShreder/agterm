import ArgumentParser
import agtermCore

// MARK: - keymap

struct Keymap: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Keymap commands.",
        subcommands: [Reload.self]
    )

    struct Reload: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Re-read and apply keymap.conf (prints the diagnostic count).")
        // keymap.reload is app-global (the frontmost window's settings model), so no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .keymapReload) }
    }
}

// MARK: - config

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Config commands.",
        subcommands: [Reload.self]
    )

    struct Reload: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Re-read and apply the agterm-scoped ghostty.conf (prints the diagnostic count).")
        // config.reload is app-global (one settings model + GhosttyApp), so no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .configReload) }
    }
}

// MARK: - restore

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restore-running-command commands.",
        subcommands: [Clear.self]
    )

    struct Clear: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Clear every session's saved foreground command so the next restart restores plain shells.")
        // restore.clear is app-global (clears every open window), so no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .restoreClear) }
    }
}

// MARK: - theme

struct Theme: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Theme commands.",
        subcommands: [Set.self, List.self]
    )

    struct Set: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Set + persist the terminal theme (omit NAME for ghostty's built-in default).")
        @Argument(help: "Theme name (a bundled theme); omit for ghostty's built-in default.") var name: String?
        // theme is app-global (one settings model), so no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .themeSet, args: ControlArgs(name: name))
        }
    }

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "List bundled themes (the current one marked).")
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .themeList) }
    }
}

// MARK: - quick

struct Quick: RequestCommand {
    static let configuration = CommandConfiguration(abstract: "Quick terminal (show|hide|toggle).")
    @Argument(help: "Mode: show, hide, or toggle (default).") var mode: String = "toggle"
    // the quick terminal is always the frontmost window's, so this carries no `--window` selector.
    @OptionGroup var options: BasicOptions

    func makeRequest() throws -> ControlRequest {
        ControlRequest(cmd: .quick, args: ControlArgs(mode: mode))
    }
}

// MARK: - sidebar

struct Sidebar: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sidebar visibility and view mode.",
        subcommands: [Visibility.self, Mode.self, Expand.self, Collapse.self],
        defaultSubcommand: Visibility.self
    )

    /// `agtermctl sidebar [show|hide|toggle]` — the default, so the bare verb keeps working. Toggles the
    /// frontmost window's sidebar visibility.
    struct Visibility: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "visibility", abstract: "Sidebar visibility (show|hide|toggle).")
        @Argument(help: "Mode: show, hide, or toggle (default).") var mode: String = "toggle"
        // the sidebar is always the frontmost window's, so this carries no `--window` selector.
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sidebar, args: ControlArgs(mode: mode))
        }
    }

    /// `agtermctl sidebar mode [tree|flagged|toggle]` — flips the frontmost window's sidebar view between
    /// the workspace tree and the flat flagged working-set list.
    struct Mode: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "mode", abstract: "Sidebar view mode (tree|flagged|toggle).")
        @Argument(help: "Mode: tree, flagged, or toggle (default).") var mode: String = "toggle"
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard ["tree", "flagged", "toggle"].contains(mode) else {
                throw ValidationError("mode must be tree, flagged, or toggle")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sidebarMode, args: ControlArgs(mode: mode))
        }
    }

    /// `agtermctl sidebar expand [--window W]` — expand every workspace in a window's sidebar tree
    /// (defaults to the frontmost). Unlike `visibility`/`mode`, this carries the `--window` selector so a
    /// script can expand a background window's tree.
    struct Expand: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Expand every workspace in the sidebar.")
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .sidebarExpand, args: options.withWindow()) }
    }

    /// `agtermctl sidebar collapse [--window W]` — collapse every workspace except the active one (it
    /// stays expanded) in a window's sidebar (defaults to the frontmost).
    struct Collapse: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Collapse all workspaces except the active one.")
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .sidebarCollapse, args: options.withWindow()) }
    }
}

// MARK: - notify

struct Notify: RequestCommand {
    static let configuration = CommandConfiguration(abstract: "Post a desktop notification (default: the active session of the frontmost window).")
    @Argument(help: "Notification body.") var body: String
    @Option(name: .long, help: "Notification title (defaults to the session name).") var title: String?
    @OptionGroup var target: TargetOptions
    @OptionGroup var options: ClientOptions

    func makeRequest() throws -> ControlRequest {
        ControlRequest(cmd: .notify, target: target.target, args: options.withWindow(ControlArgs(title: title, body: body)))
    }
}

// MARK: - font

struct Font: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Font size commands.",
        subcommands: [Inc.self, Dec.self, Reset.self]
    )

    struct Inc: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Increase font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontInc, target: target.target, args: options.withWindow())
        }
    }

    struct Dec: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Decrease font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontDec, target: target.target, args: options.withWindow())
        }
    }

    struct Reset: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Reset font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontReset, target: target.target, args: options.withWindow())
        }
    }
}

// MARK: - tmux (-CC control mode)

/// `agtermctl tmux attach|detach|list|kill` — the connection-level tmux control verbs. Distinct from
/// the internal `tmux-pipe` relay child (a root subcommand, not part of this group).
struct Tmux: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tmux",
        abstract: "Attach/detach/list native tmux -CC sessions.",
        subcommands: [Attach.self, Detach.self, List.self, Kill.self])

    /// `tmux attach <host> [--session <name>] [--workspace <name>]` — start a gateway and mirror the
    /// remote tmux session's windows as native agterm sessions. Echoes the connection id (create-like:
    /// the id isn't known yet, and it's what `tmux detach`/`kill` address).
    struct Attach: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Attach to a remote tmux -CC session over ssh.")
        @Argument(help: "The ssh host (e.g. user@host).") var host: String
        @Option(name: .long, help: "The tmux session name (default: main).") var session: String?
        @Option(name: .long, help: "Override the created workspace name.") var workspace: String?
        @OptionGroup var options: BasicOptions
        var echoesResultID: Bool { true }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .tmuxAttach, args: ControlArgs(name: session, workspace: workspace, host: host))
        }
    }

    /// `tmux detach [connection-id]` — soft detach (tmux survives server-side). No id = the only/first
    /// live connection.
    struct Detach: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Detach a tmux connection (tmux survives).")
        @Argument(help: "Connection id (the tmux workspace uuid); omit for the only live connection.")
        var connection: String?
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .tmuxDetach, target: connection)
        }
    }

    /// `tmux list` — the live tmux connections (id, host, window names).
    struct List: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "List active tmux connections.")
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .tmuxList)
        }
    }

    /// `tmux kill [connection-id]` — hard remote `kill-session`. No id = the only/first live connection.
    struct Kill: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Kill a tmux connection remotely (kill-session).")
        @Argument(help: "Connection id (the tmux workspace uuid); omit for the only live connection.")
        var connection: String?
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .tmuxKill, target: connection)
        }
    }
}
