import Foundation

extension ControlDispatcher {
    /// The `remote` group. Split out like `+Zmx` so `ControlDispatcher.swift` stays inside the file limit.
    func dispatchRemoteCommand(_ request: ControlRequest) async -> ControlResponse {
        // the target names a session on ANOTHER machine, so there is no `active` default anywhere here
        guard let host = request.args?.host?.trimmedOrNil else {
            return ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a host")
        }
        if request.cmd == .remoteList {
            return await actions.listRemoteHostSessions(host: host)
        }
        guard let name = request.target?.trimmedOrNil else {
            return ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a session name")
        }
        // refused before it can reach an argv or an error message a terminal would print
        guard RemoteSession.isSessionName(name) else {
            return ControlResponse(ok: false, error: "invalid remote session")
        }
        switch request.cmd {
        case .remoteKill:
            guard request.args?.force == true else {
                return ControlResponse(ok: false, error: "remote.kill requires --force")
            }
            return await actions.killRemoteHostSession(host: host, name: name)
        case .remoteAttach:
            let create = request.args?.create == true
            let command = request.args?.command?.trimmedOrNil
            guard command == nil || create else {
                return ControlResponse(ok: false, error: "remote.attach --command requires --create")
            }
            return await actions.attachRemoteHostSession(host: host, name: name,
                                                         window: request.args?.window?.trimmedOrNil,
                                                         create: create, command: command)
        default:
            preconditionFailure("unexpected remote command: \(request.cmd.rawValue)")
        }
    }
}
