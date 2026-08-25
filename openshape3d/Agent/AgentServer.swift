//
//  AgentServer.swift
//  openshape3d
//
//  DEBUG-ONLY control channel: a loopback HTTP listener that lets an external
//  agent (the MCP server in `scripts/mcp_openshape3d.py`) drive the app.
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
//  STATUS: step 1 of the plan — proves a sandboxed Catalyst app can bind a
//  listening socket. Answers GET /v1/health and nothing else; the request and
//  dispatch layers land next.
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

    /// Default port; `OS3D_AGENT_PORT` overrides. Fixed-by-default means the
    /// MCP server has something to talk to even with no discovery file.
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
                NSLog("[agent] listening on http://127.0.0.1:\(actual)")
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

    /// Reads until the headers are complete. The spike only needs the request
    /// line, so it does not yet handle a body — `AgentHTTP` (next step) becomes
    /// a proper incremental parser that can be unit-tested without sockets.
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
            guard let headerEnd = Self.headerTerminator(in: buffer) else {
                if isComplete { connection.cancel(); return }
                self.receive(on: connection, buffer: buffer)
                return
            }

            let head = String(decoding: buffer[..<headerEnd], as: UTF8.self)
            let requestLine = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            self.respond(to: requestLine, on: connection)
        }
    }

    private static func headerTerminator(in data: Data) -> Data.Index? {
        let marker = Data("\r\n\r\n".utf8)
        return data.range(of: marker)?.lowerBound
    }

    private func respond(to requestLine: String, on connection: NWConnection) {
        let fields = requestLine.split(separator: " ")
        let method = fields.first.map(String.init) ?? ""
        let path = fields.count > 1 ? String(fields[1]) : ""

        let status: String
        let body: Data
        if method == "GET", path == "/v1/health" {
            status = "200 OK"
            let payload: [String: Any] = [
                "ok": true,
                "protocol": 1,
                "app": "openshape3d",
                "port": boundPort ?? 0,
                "pid": ProcessInfo.processInfo.processIdentifier,
            ]
            body = (try? JSONSerialization.data(withJSONObject: payload))
                ?? Data(#"{"ok":true}"#.utf8)
        } else {
            status = "404 Not Found"
            body = Data(#"{"ok":false,"error":"unknown path"}"#.utf8)
        }

        var response = Data("HTTP/1.1 \(status)\r\n".utf8)
        response.append(Data("Content-Type: application/json\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

#endif
