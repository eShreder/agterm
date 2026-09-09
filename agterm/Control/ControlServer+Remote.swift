import Foundation
import agtermCore

/// The `remote` group: zmx sessions on a host that runs nothing of agterm's. List and kill are one ssh each
/// through the injected runner; attach never sshes here — the pane's own command does, so a transport
/// failure is an ordinary held pane exit, as for `zmx.attach`.
extension ControlServer {
    func listRemoteHostSessions(host: String) async -> ControlResponse {
        let argv: [String]
        do {
            argv = try RemoteSession.hostListCommand(host: host)
        } catch {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteTreeDeadline)
        if let failure = Self.remoteHostFailure(result, host: host) { return failure }
        return ControlResponse(ok: true, result: ControlResult(remoteSessions: RemoteHostList.parse(result.stdout)))
    }

    func attachRemoteHostSession(host: String, name: String, window: String?, create: Bool,
                                 command: String?) async -> ControlResponse {
        let pane: String
        do {
            pane = try RemoteSession.hostAttachPaneCommand(host: host, name: name, create: create, command: command)
        } catch RemoteSession.InvocationError.invalidSession {
            return ControlResponse(ok: false, error: "invalid remote session")
        } catch {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let store: AppStore
        switch resolveOpenWindow(window) {
        case .failure(let response): return response
        case .success(let (_, resolved)): store = resolved
        }
        guard let workspace = store.currentWorkspaceID else {
            return ControlResponse(ok: false, error: "no window to attach into")
        }
        // the LOCAL home: libghostty chdirs the ssh process here, and the far side's path may not exist
        guard let created = store.addSession(toWorkspace: workspace, cwd: NSHomeDirectory(), command: pane,
                                             name: name, wait: true, remoteHost: host) else {
            return ControlResponse(ok: false, error: "could not create the session")
        }
        actions.focusSplitPane(created, wantSplit: false)
        return ControlResponse(ok: true, result: ControlResult(id: created.id.uuidString))
    }

    func killRemoteHostSession(host: String, name: String) async -> ControlResponse {
        let argv: [String]
        do {
            argv = try RemoteSession.hostKillCommand(host: host, name: name)
        } catch RemoteSession.InvocationError.invalidSession {
            return ControlResponse(ok: false, error: "invalid remote session")
        } catch {
            return ControlResponse(ok: false, error: "invalid host")
        }
        let result = await remoteRunner.run(argv, deadline: Self.remoteTreeDeadline)
        if let failure = Self.remoteHostFailure(result, host: host) { return failure }
        let said = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ControlResponse(ok: true, result: ControlResult(text: said.isEmpty ? "killed \(name) on \(host)" : said))
    }

    /// 127 is the far side's shell failing to find zmx, which deserves its own sentence; any other nonzero
    /// status reports what ssh or zmx said, intact, as `zmx.tree` does.
    private static func remoteHostFailure(_ result: RemoteCommandResult, host: String) -> ControlResponse? {
        guard result.status != 0 else { return nil }
        if result.status == 127 { return ControlResponse(ok: false, error: "zmx is not installed on \(host)") }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return ControlResponse(ok: false, error: stderr.isEmpty ? "the remote command failed on \(host)" : stderr)
    }
}
