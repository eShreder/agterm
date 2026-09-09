import ArgumentParser
import Foundation
import agtermCore

// MARK: - remote

struct Remote: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sessions on a host that runs zmx.",
        discussion: """
        Any Linux or Mac host with zmx installed and reachable over key-based ssh; nothing of agterm's is \
        needed there. `remote list` reads the host's own `zmx list`, `remote attach` opens one of those \
        sessions here as a session marked remote, and `remote kill` ends one. A host that also runs agterm \
        keeps its own live-pane sessions out of this listing: those are `zmx tree` and `zmx attach`.

        Every connection is non-interactive: ssh runs with BatchMode, so key-based auth must already work \
        for the host and a password or host-key prompt is a failure rather than a question. zmx is found \
        through the far side's PATH plus ~/.local/bin, ~/bin, /usr/local/bin and /opt/homebrew/bin.
        """,
        subcommands: [List.self, Attach.self, Kill.self]
    )

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the zmx sessions on a host.",
            discussion: """
            One row per session: its name, how many clients are attached, its working directory when zmx \
            reports one, and its labels. An empty list is a successful answer. A host without zmx answers \
            that zmx is not installed.
            """)
        @Argument(help: "The host, as ssh would take it.")
        var host: String
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .remoteList, args: ControlArgs(host: host))
        }
    }

    struct Attach: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Attach to a zmx session on a host, as a session here.",
            discussion: """
            Opens a session marked remote whose pane runs `ssh -tt HOST zmx attach NAME`, in the chosen local \
            window's current workspace, selected. Without --create the attach refuses a name zmx no longer \
            has, so a session gone since the listing fails visibly instead of becoming a fresh shell wearing \
            its name. With --create zmx creates it when absent, running --command instead of a login shell; \
            an existing session ignores that command.

            Closing the session here ends only this side's connection; the far-side process keeps running. \
            It is not restored after a relaunch.
            """)
        @Argument(help: "The host, as ssh would take it.")
        var host: String
        @Argument(help: "The zmx session name, as `remote list` prints it.")
        var name: String
        @Flag(name: .long, help: "Let zmx create the session when the name does not exist.")
        var create = false
        @Option(name: .long, help: "What a NEW session runs instead of a login shell; needs --create.")
        var command: String?
        @Option(name: .long, help: "Local open window id, unique prefix, or active (default: frontmost).")
        var window: String?
        @OptionGroup var options: BasicOptions

        /// It creates a local session, so it echoes that session's id like every other create command.
        var echoesResultID: Bool { true }

        func validate() throws {
            guard command == nil || create else {
                throw ValidationError("--command needs --create; an existing session keeps what it is running")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .remoteAttach, target: name,
                           args: ControlArgs(host: host, create: create ? true : nil, command: command, window: window))
        }
    }

    struct Kill: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "End a zmx session on a host and the process running in it.",
            discussion: """
            Runs `zmx kill NAME` on the host. Every client attached to that session, a pane here included, \
            sees its connection end, so --force is required as confirmation.
            """)
        @Argument(help: "The host, as ssh would take it.")
        var host: String
        @Argument(help: "The zmx session name, as `remote list` prints it.")
        var name: String
        @Flag(name: .long, help: "Required. Confirms ending the process running in that session.")
        var force = false
        @OptionGroup var options: BasicOptions

        func validate() throws {
            guard force else { throw ValidationError("--force is required to end a running process") }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .remoteKill, target: name, args: ControlArgs(force: true, host: host))
        }
    }
}
