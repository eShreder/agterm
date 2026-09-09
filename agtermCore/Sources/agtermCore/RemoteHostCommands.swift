import Foundation

/// The ssh command lines that reach zmx on a host that runs no agterm. The far side keeps its own socket
/// directory and PATH conventions; agterm only widens the PATH sshd's non-interactive shell starts with.
extension RemoteSession {
    /// zmx.sh installs into `~/.local/bin`, Homebrew into `/usr/local/bin` or `/opt/homebrew/bin`, and sshd's
    /// remote-command shell reads no profile, so none of these is on PATH unless added here.
    static let hostPathPrefix = "PATH=\"$PATH:$HOME/.local/bin:$HOME/bin:/usr/local/bin:/opt/homebrew/bin\""

    private static let guardScript = "printf '%s\\n' 'agterm: remote session is gone'; exit 1"

    public static func hostListCommand(host: String, connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false)
            + [remoteChain(["zmx", "list"])]
    }

    /// `create: false` appends the create-only guard, so a name zmx no longer has fails visibly instead of
    /// becoming a fresh shell. `create: true` lets zmx create it, running `command` through `/bin/sh -c`
    /// instead of a login shell when one is given; an existing daemon ignores that payload.
    public static func hostAttachCommand(host: String, name: String, create: Bool, command: String? = nil,
                                         connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        try validate(sessionName: name)
        var attach = ["zmx", "attach", name]
        if !create {
            attach += ["/bin/sh", "-c", guardScript]
        } else if let command {
            attach += ["/bin/sh", "-c", command]
        }
        // the three the local pane clears too, empty being unset to zmx; ZMX_DIR stays the host's own
        let remote = CommandRestore.shellQuotedLine([
            "/usr/bin/env", "ZMX_SESSION=", "ZMX_SESSION_PREFIX=", "ZMX_NO_DETACH_KEY=1",
            "/bin/sh", "-c", hostPathPrefix + " && exec " + CommandRestore.shellQuotedLine(attach),
        ])
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: true) + [remote]
    }

    /// The pane's command: the attach, then one line saying what died, held by `commandWait`.
    public static func hostAttachPaneCommand(host: String, name: String, create: Bool,
                                             command: String? = nil) throws -> String {
        let attach = CommandRestore.shellQuotedLine(
            try hostAttachCommand(host: host, name: name, create: create, command: command))
        let label = CommandRestore.shellQuotedLine(["agterm: \(name) on \(host) disconnected, exit"])
        return "\(attach); status=$?; printf '%s %s\\n' \(label) \"$status\"; exit \"$status\""
    }

    public static func hostKillCommand(host: String, name: String, connectTimeout: Int = 5) throws -> [String] {
        try validate(host: host)
        try validate(sessionName: name)
        return sshArguments(host: host, connectTimeout: connectTimeout, interactive: false)
            + [remoteChain(["zmx", "kill", name])]
    }

    public static func isSessionName(_ value: String) -> Bool {
        (try? validate(sessionName: value)) != nil
    }

    /// A zmx session name becomes a socket file name, and zmx reads a leading `-` as an option.
    static func validate(sessionName: String) throws {
        guard isPlain(sessionName), !sessionName.contains("/"), !sessionName.hasPrefix("-") else {
            throw InvocationError.invalidSession
        }
    }

    /// One command for the far side's login shell, whatever shell that is: `/bin/sh -c '<PATH widening> && exec …>'`.
    private static func remoteChain(_ argv: [String]) -> String {
        CommandRestore.shellQuotedLine(["/bin/sh", "-c", hostPathPrefix + " && exec " + CommandRestore.shellQuotedLine(argv)])
    }
}
