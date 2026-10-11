//
//  WebHandoff.swift
//  openshape3d
//
//  "Open on the Web": send the open design to the OpenShape3D web app
//  (app.openshape3d.com, repo laanlabs/openshape-cloud) and get back a short
//  link that opens it there — on a laptop, by QR code, or shared with someone.
//
//  One HTTPS request, only when the user presses Send: the design's .os3d
//  archive goes to POST /api/handoffs, which stores it for 24 hours and
//  answers with an 8-character code. The link is
//  https://app.openshape3d.com/?open=CODE. No account, no device identifier,
//  nothing else is sent. Same flow as OpenPlan3D's "Open in OpenPlan3D".
//
//  The server reports limits as HTTP status codes (413 too large, 429 daily
//  or per-minute limit, 503 unavailable); a send is never retried by itself,
//  because an uncertain failure may already have been charged to the quota.
//

import CryptoKit
import Foundation

// MARK: - Link

nonisolated struct WebHandoffLink: Equatable, Sendable {
    let code: String
    let expiresAt: Date

    static let webApp = URL(string: "https://app.openshape3d.com")!

    var url: URL {
        var components = URLComponents(url: Self.webApp, resolvingAgainstBaseURL: false)!
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "open", value: code)]
        return components.url!
    }

    /// 8 symbols from the server's alphabet (no I, O, 0 or 1).
    static func isValidCode(_ code: String) -> Bool {
        code.count == 8 && code.allSatisfy { "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".contains($0) }
    }
}

// MARK: - Errors

nonisolated enum WebHandoffError: LocalizedError, Equatable {
    case empty
    case tooLarge
    case limited
    case unavailable(String?)
    case invalidResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "There's nothing to send — the design couldn't be saved."
        case .tooLarge:
            return "This design is too large to open on the web (the limit is 25 MB). Use Export ▸ Project Archive (.os3d) and open the file at app.openshape3d.com instead."
        case .limited:
            return "Opening designs on the web has reached its limit for now. Try again later, or use Export ▸ Project Archive (.os3d)."
        case .unavailable(let message):
            return message ?? "Opening designs on the web is unavailable right now. Try again later, or use Export ▸ Project Archive (.os3d)."
        case .invalidResponse:
            return "The web app sent an answer this version doesn't understand. Try again later."
        case .network(let reason):
            return "Couldn't reach app.openshape3d.com (\(reason)). Check the connection and try again."
        }
    }
}

// MARK: - Transport

/// The one network call, injectable so tests never touch the network.
protocol WebHandoffTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionHandoffTransport: WebHandoffTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebHandoffError.invalidResponse }
        return (data, http)
    }
}

// MARK: - Service

actor WebHandoffService {
    static let endpoint = URL(string: "https://app.openshape3d.com/api/handoffs")!
    /// Matches the server's HANDOFF_LIMITS.maxBytes; refused before uploading.
    static let maxBytes = 25 * 1024 * 1024
    static let shared = WebHandoffService()

    private let transport: WebHandoffTransport
    private let now: @Sendable () -> Date
    /// Links already made this session, by the design's SHA-256: sending the
    /// same unchanged design again reuses its link instead of another upload.
    private var links: [String: WebHandoffLink] = [:]
    private var inFlight: [String: Task<WebHandoffLink, Error>] = [:]

    init(transport: WebHandoffTransport = URLSessionHandoffTransport(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.now = now
    }

    func send(design: Data) async throws -> WebHandoffLink {
        guard !design.isEmpty else { throw WebHandoffError.empty }
        guard design.count <= Self.maxBytes else { throw WebHandoffError.tooLarge }
        let key = SHA256.hash(data: design).map { String(format: "%02x", $0) }.joined()
        // Reuse a link with at least a minute left, so it still works when opened.
        if let link = links[key], link.expiresAt.timeIntervalSince(now()) > 60 { return link }
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await self.upload(design) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let link = try await task.value
        links[key] = link
        return link
    }

    private func upload(_ design: Data) async throws -> WebHandoffLink {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = design

        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as WebHandoffError {
            throw error
        } catch {
            throw WebHandoffError.network(error.localizedDescription)
        }
        return try Self.parse(data, response, now: now())
    }

    /// The reply, checked as strictly as the server checks the request.
    static func parse(_ data: Data, _ response: HTTPURLResponse, now: Date) throws -> WebHandoffLink {
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch response.statusCode {
        case 201:
            guard let code = body?["code"] as? String, WebHandoffLink.isValidCode(code),
                  let expiry = (body?["expiresAt"] as? String).flatMap(Self.parseDate),
                  expiry.timeIntervalSince(now) > 60,
                  expiry.timeIntervalSince(now) <= 24 * 3600 + 300   // a little clock skew
            else { throw WebHandoffError.invalidResponse }
            return WebHandoffLink(code: code, expiresAt: expiry)
        case 413:
            throw WebHandoffError.tooLarge
        case 429:
            throw WebHandoffError.limited
        default:
            throw WebHandoffError.unavailable(body?["error"] as? String)
        }
    }

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
