//
//  AgentServer.swift
//  openshape3d
//
//  DEBUG-ONLY control channel: a loopback HTTP listener that lets an external
//  agent drive the app. Two clients ship with it, both talking this same HTTP:
//  `.claude/skills/drive-openshape3d/SKILL.md` (Claude Code, via curl) and
//  `scripts/mcp_openshape3d.py` (Claude Desktop, via MCP). See
//  `docs/AGENT_CONTROL.md`.
//
//  Compiled out of Release entirely — and the matching sandbox entitlement
//  (`ENABLE_INCOMING_NETWORK_CONNECTIONS`) is set on the Debug configuration
//  only, so a Release build has neither the code nor the capability. Same
//  posture as the existing `OS3D_*` debug hooks.
//
//  Everything here is explicitly `nonisolated` because the project builds with
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — without it these types would
//  be implicitly main-actor and could not run on the listener queue.
//
//  This file is now only the socket. The parts worth testing live next door:
//  framing in `AgentHTTP`, routing and error shaping in `AgentRouter`, and the
//  hop onto the editor in `AgentBridge`.
//
//  STATUS: serving. Health, command catalog, editor state, command dispatch and
//  a viewport PNG. What is NOT here is parameterisation: `runCommand` arms a
//  tool, it does not set a distance or commit — see the closing section of
//  `docs/AGENT_CONTROL.md`.
//
//  TWO THINGS THAT COST AN HOUR, both of which fail SILENTLY:
//
//  1. The app must be launched through LaunchServices (`open Foo.app`), NOT by
//     exec'ing `Contents/MacOS/openshape3d`. Executed directly, a Catalyst app
//     does not get its full sandbox/entitlement context and `listen()` never
//     takes effect — while NWListener still reports `.ready`. To pass the env
//     var through `open`, set it for the session first:
//         launchctl setenv OS3D_AGENT 1 && open path/to/openshape3d.app
//         …then `launchctl unsetenv OS3D_AGENT` when finished.
//
//  2. Do not set `requiredLocalEndpoint` on listener parameters. It is meant
//     for outbound connections; on a listener it produces the same silent
//     no-op. Pass the port to `NWListener(using:on:)` instead.
//
//  The diagnostic for both: `lsof -nP -iTCP -a -p <pid>` shows the socket in
//  (CLOSED) rather than (LISTEN), even though the listener logged "ready".
//  Always log `listener.port` — never the requested port — or this is invisible.
//

#if DEBUG

import Foundation
import Network

nonisolated final class AgentServer: @unchecked Sendable {
    static let shared = AgentServer()

    /// Bumped when a response shape changes incompatibly. Clients check it in
    /// `/v1/health` and refuse rather than misread a newer app.
    static let protocolVersion = 1

    /// Default port; `OS3D_AGENT_PORT` overrides. Fixed-by-default means the
    /// clients have something to talk to with no discovery file.
    static let defaultPort: UInt16 = 8787

    /// All mutable state below is confined to this queue.
    private let queue = DispatchQueue(label: "com.laan.labs.openshape3d.agent", qos: .userInitiated)
    private var listener: NWListener?
    private var boundPort: UInt16?

    private init() {}

    /// No-op unless `OS3D_AGENT` is set, so an ordinary debug run is unaffected.
    func startIfRequested() {
        guard ProcessInfo.processInfo.environment["OS3D_AGENT"] != nil else { return }
        let requested = ProcessInfo.processInfo.environment["OS3D_AGENT_PORT"]
            .flatMap(UInt16.init) ?? Self.defaultPort
        queue.async { [weak self] in self?.start(port: requested) }
    }

    private func start(port requested: UInt16) {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: requested) else {
            NSLog("[agent] invalid port \(requested)")
            return
        }

        let params = NWParameters.tcp
        // Loopback ONLY, via the INTERFACE constraint. Do not use
        // `requiredLocalEndpoint` here: that is meant for outbound connections,
        // and on a listener it yields a socket stuck in CLOSED while the
        // listener still reports `.ready` — i.e. a silent no-op. The port must
        // come from `NWListener(using:on:)`.
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            NSLog("[agent] NWListener init failed on \(requested): \(error)")
            return
        }
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // Log the ACTUAL bound port, never the requested one — that
                // distinction is what hid the CLOSED-socket bug above.
                let actual = self?.listener?.port?.rawValue ?? 0
                self?.boundPort = actual
                NSLog("[agent] listening on http://127.0.0.1:\(actual) "
                      + "(\(AgentRouter.platformName), protocol \(Self.protocolVersion))")
            case .failed(let error):
                // The expected sandbox failure mode is POSIX EPERM on bind.
                NSLog("[agent] listener FAILED: \(error) — if this is EPERM the "
                      + "app lacks com.apple.security.network.server")
                self?.listener?.cancel()
                self?.listener = nil
            case .cancelled:
                self?.listener = nil
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        // Defence in depth: the interface constraint above should make this
        // unreachable, but never serve a non-loopback peer.
        if case let .hostPort(host, _) = connection.endpoint, !Self.isLoopback(host) {
            NSLog("[agent] rejecting non-loopback peer \(host)")
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    /// Accumulate until `AgentHTTP` says the request is whole — which, unlike
    /// the original header-only read, includes waiting for a `Content-Length`
    /// body that arrived in a second packet.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if let error {
                NSLog("[agent] receive error: \(error)")
                connection.cancel()
                return
            }

            switch AgentHTTP.parse(buffer) {
            case .incomplete:
                // A half-sent request with the peer already gone is a dead
                // connection, not a slow one.
                if isComplete { connection.cancel(); return }
                self.receive(on: connection, buffer: buffer)

            case .complete(let request):
                self.dispatch(request, on: connection)

            case .malformed(let reason):
                NSLog("[agent] malformed request: \(reason)")
                self.send(.failure(400, "Bad Request", error: "malformed_request",
                                   message: reason), on: connection)

            case .tooLarge:
                self.send(.failure(413, "Payload Too Large", error: "body_too_large",
                                   message: "Bodies are capped at \(AgentHTTP.maxBodyBytes) bytes."),
                          on: connection)
            }
        }
    }

    private func dispatch(_ request: AgentRequest, on connection: NWConnection) {
        let route = AgentRouter.route(request)

        // Anything the editor is not needed for is answered right here on the
        // listener queue — including /v1/health, which must still respond when
        // the main actor is wedged, since that is the condition it exists to
        // report.
        if let decided = AgentRouter.response(for: route) {
            send(decided, on: connection)
            return
        }
        guard route.needsEditor else {
            switch route {
            case .health:   send(AgentRouter.healthResponse(port: boundPort ?? 0), on: connection)
            case .commands: send(AgentRouter.commandsResponse(), on: connection)
            default:        send(.failure(500, "Internal Server Error", error: "unhandled_route",
                                          message: "No handler for \(request.path)."), on: connection)
            }
            return
        }

        Task { @MainActor [weak self] in
            let response = AgentBridge.shared.handle(route)
            self?.send(response, on: connection)
        }
    }

    private func send(_ response: AgentResponse, on connection: NWConnection) {
        var out = Data("HTTP/1.1 \(response.status) \(response.reason)\r\n".utf8)
        out.append(Data("Content-Type: \(response.contentType)\r\n".utf8))
        out.append(Data("Content-Length: \(response.body.count)\r\n".utf8))
        out.append(Data("Connection: close\r\n\r\n".utf8))
        out.append(response.body)

        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

#endif
