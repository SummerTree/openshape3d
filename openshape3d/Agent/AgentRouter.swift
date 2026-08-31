//
//  AgentRouter.swift
//  openshape3d
//
//  The response half of the DEBUG-only agent bridge: which endpoint a parsed
//  request names, and every reply that can be produced without touching the
//  live editor.
//
//  Split out of `AgentServer` so the interesting decisions are pure values a
//  test can assert on. What is left in the server is the socket, and what is in
//  `AgentBridge` is the main-actor hop; neither is testable, and neither needs
//  to be once routing and error shaping live here.
//
//  THE ONE THING THIS FILE EXISTS TO GET RIGHT: `EditorViewModel.runCommand`
//  returns a single `Bool` for three very different situations — the id was a
//  typo, the id is real but nothing routes it yet, or the id is fine but the
//  editor is in the wrong mode. A human pressing a key cannot tell those apart
//  and does not need to. An agent absolutely does: told only "false", it will
//  retry the same call forever. The catalog is a pure static, so this file can
//  separate all three before the request ever reaches the main actor.
//

#if DEBUG

import Foundation

// MARK: - A reply

nonisolated struct AgentResponse: Sendable {
    var status: Int
    var reason: String
    var contentType: String = "application/json"
    var body: Data

    static func json(_ status: Int, _ reason: String, _ object: [String: Any]) -> AgentResponse {
        // `.sortedKeys` so responses are byte-stable — worth it for diffing a
        // log and for asserting on one in a test.
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"encoding_failed"}"#.utf8)
        return AgentResponse(status: status, reason: reason, body: data)
    }

    static func ok(_ object: [String: Any]) -> AgentResponse {
        var payload = object
        payload["ok"] = true
        return .json(200, "OK", payload)
    }

    /// `error` is a stable machine code; `message` is for a human reading a log.
    static func failure(_ status: Int, _ reason: String, error: String, message: String) -> AgentResponse {
        .json(status, reason, ["ok": false, "error": error, "message": message])
    }

    static func png(_ data: Data) -> AgentResponse {
        AgentResponse(status: 200, reason: "OK", contentType: "image/png", body: data)
    }
}

// MARK: - Where a request is headed

nonisolated enum AgentRoute: Sendable, Equatable {
    /// Answerable without the editor.
    case health
    case commands
    /// Needs the live `EditorViewModel` — see `AgentBridge`.
    case state
    case runCommand(id: String)
    case exec(AgentExecOp)
    case screenshot(width: Int, height: Int)
    /// Already-decided replies.
    case reply(status: Int, error: String, message: String)

    /// Whether serving this needs a hop to the main actor.
    var needsEditor: Bool {
        switch self {
        case .state, .runCommand, .exec, .screenshot: return true
        case .health, .commands, .reply: return false
        }
    }
}

// MARK: - Routing

nonisolated enum AgentRouter {

    /// Bounds on `?w=`/`?h=`. The upper end is a guard against an accidental
    /// 40000px request wedging the renderer, not a considered maximum.
    static let defaultShotSize = 1024
    static let minShotSize = 64
    static let maxShotSize = 4096

    static func route(_ request: AgentRequest) -> AgentRoute {
        switch request.path {

        case "/v1/health":
            return get(request) ?? .health

        case "/v1/commands":
            return get(request) ?? .commands

        case "/v1/state":
            return get(request) ?? .state

        case "/v1/screenshot":
            if let bad = get(request) { return bad }
            return .screenshot(
                width: request.intQuery("w", default: defaultShotSize,
                                        min: minShotSize, max: maxShotSize),
                height: request.intQuery("h", default: defaultShotSize,
                                         min: minShotSize, max: maxShotSize))

        case "/v1/command":
            guard request.method == "POST" else {
                return .reply(status: 405, error: "method_not_allowed",
                              message: "POST a JSON body to /v1/command.")
            }
            guard let id = request.jsonBody?["id"] as? String, !id.isEmpty else {
                return .reply(status: 400, error: "missing_id",
                              message: #"Body must be JSON like {"id":"view.isometric"}."#)
            }
            return classify(id)

        case "/v1/exec":
            guard request.method == "POST" else {
                return .reply(status: 405, error: "method_not_allowed",
                              message: "POST a JSON body to /v1/exec.")
            }
            switch AgentExec.parse(request.jsonBody) {
            case .success(let op):
                return .exec(op)
            case .failure(let error):
                return .reply(status: 400, error: error.code, message: error.message)
            }

        default:
            return .reply(status: 404, error: "unknown_path",
                          message: "No such endpoint: \(request.path). GET /v1/commands lists what this build can do.")
        }
    }

    /// The three-way split described in this file's header.
    private static func classify(_ id: String) -> AgentRoute {
        guard CommandRegistry.command(inCatalog: id) != nil else {
            return .reply(status: 400, error: "unknown_command",
                          message: "No command with id '\(id)'. GET /v1/commands for the list.")
        }
        guard CommandRegistry.routableIDs.contains(id) else {
            // The catalog is deliberately wider than the routing table: it also
            // names commands whose editor entry points do not exist yet, and
            // `unroutedChordedCommands` keeps that gap visible. Saying so beats
            // reporting a success that changed nothing.
            return .reply(status: 400, error: "unrouted_command",
                          message: "'\(id)' is in the catalog but has no editor entry point in this build.")
        }
        return .runCommand(id: id)
    }

    /// 405 unless the method is GET.
    private static func get(_ request: AgentRequest) -> AgentRoute? {
        request.method == "GET" ? nil : .reply(
            status: 405, error: "method_not_allowed",
            message: "\(request.path) is GET only.")
    }

    // MARK: Replies that need no editor

    static func healthResponse(port: UInt16) -> AgentResponse {
        .ok([
            "protocol": AgentServer.protocolVersion,
            "app": "openshape3d",
            "port": Int(port),
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "platform": platformName,
            // An agent that knows a document is open can skip straight to
            // /v1/state; one that does not knows to open a project first.
            "hasDocument": AgentAttachment.isAttached,
        ])
    }

    /// Exactly what Command Search is allowed to offer — commands that actually
    /// reach the editor. An agent handed the full catalog would waste turns on
    /// ids that cannot run.
    static func commandsResponse() -> AgentResponse {
        let commands = CommandRegistry.launchableCommands.map { command -> [String: Any] in
            var entry: [String: Any] = [
                "id": command.id,
                "title": command.title,
                "category": command.category.rawValue,
            ]
            if let chord = command.chord { entry["chord"] = chord.label }
            return entry
        }
        return .ok(["count": commands.count, "commands": commands])
    }

    static func response(for reply: AgentRoute) -> AgentResponse? {
        guard case let .reply(status, error, message) = reply else { return nil }
        return .failure(status, httpReason(status), error: error, message: message)
    }

    static func httpReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "Error"
        }
    }

    static var platformName: String {
        #if targetEnvironment(macCatalyst)
        return "maccatalyst"
        #elseif targetEnvironment(simulator)
        return "simulator"
        #else
        return "device"
        #endif
    }
}

#endif
