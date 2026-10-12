//
//  WebHandoffTests.swift
//  openshape3dTests
//
//  "Open on the Web": the request the app sends, how it reads the reply, the
//  limits it enforces before sending, and the link it builds. A stub
//  transport stands in for the network; nothing is sent anywhere.
//

import XCTest
@testable import openshape3d

private actor StubTransport: WebHandoffTransport {
    var requests: [URLRequest] = []
    var replies: [(Int, String)]
    var delay: Duration = .zero

    init(_ replies: [(Int, String)], delay: Duration = .zero) {
        self.replies = replies
        self.delay = delay
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if delay > .zero { try await Task.sleep(for: delay) }
        let (status, body) = replies.isEmpty ? (500, "{}") : replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

final class WebHandoffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private var tomorrow: String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(24 * 3600))
    }
    private let design = Data("bplist00 the design".utf8)

    private func service(_ transport: StubTransport, now: Date? = nil) -> WebHandoffService {
        let fixed = now ?? self.now
        return WebHandoffService(transport: transport, now: { fixed })
    }

    func testSendsTheArchiveAndBuildsTheLink() async throws {
        let stub = StubTransport([(201, #"{"code":"AB2CD3EF","expiresAt":"\#(tomorrow)"}"#)])
        let link = try await service(stub).send(design: design)

        XCTAssertEqual(link.code, "AB2CD3EF")
        XCTAssertEqual(link.url.absoluteString, "https://app.openshape3d.com/?open=AB2CD3EF")
        XCTAssertEqual(link.expiresAt.timeIntervalSince(now), 24 * 3600, accuracy: 1)

        let requests = await stub.requests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url, WebHandoffService.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.httpBody, design, "the body is the .os3d and nothing else")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testTheSameDesignReusesItsLinkAndConcurrentSendsShareOneUpload() async throws {
        let stub = StubTransport([(201, #"{"code":"AB2CD3EF","expiresAt":"\#(tomorrow)"}"#)],
                                 delay: .milliseconds(50))
        let svc = service(stub)
        async let first = svc.send(design: design)
        async let second = svc.send(design: design)
        let links = try await [first, second]
        let again = try await svc.send(design: design)
        XCTAssertEqual(Set(links.map(\.code) + [again.code]), ["AB2CD3EF"])
        let count = await stub.requests.count
        XCTAssertEqual(count, 1)
    }

    func testAChangedDesignIsSentAgain() async throws {
        let stub = StubTransport([(201, #"{"code":"AB2CD3EF","expiresAt":"\#(tomorrow)"}"#),
                                  (201, #"{"code":"GH4JK5LM","expiresAt":"\#(tomorrow)"}"#)])
        let svc = service(stub)
        _ = try await svc.send(design: design)
        let second = try await svc.send(design: design + Data([1]))
        XCTAssertEqual(second.code, "GH4JK5LM")
    }

    func testRefusesOversizeAndEmptyDesignsWithoutSending() async throws {
        let stub = StubTransport([])
        let svc = service(stub)
        do {
            _ = try await svc.send(design: Data(count: WebHandoffService.maxBytes + 1))
            XCTFail("expected tooLarge")
        } catch let error as WebHandoffError {
            XCTAssertEqual(error, .tooLarge)
        }
        do {
            _ = try await svc.send(design: Data())
            XCTFail("expected empty")
        } catch let error as WebHandoffError {
            XCTAssertEqual(error, .empty)
        }
        let count = await stub.requests.count
        XCTAssertEqual(count, 0)
    }

    func testMapsServerRefusalsAndNeverRetries() async throws {
        let cases: [(Int, String, WebHandoffError)] = [
            (413, #"{"error":"too large"}"#, .tooLarge),
            (429, #"{"error":"limit"}"#, .limited),
            (503, #"{"error":"Opening designs on the web is unavailable right now."}"#,
             .unavailable("Opening designs on the web is unavailable right now.")),
            (500, "not json", .unavailable(nil)),
        ]
        for (status, body, expected) in cases {
            let stub = StubTransport([(status, body)])
            do {
                _ = try await service(stub).send(design: design)
                XCTFail("expected \(expected)")
            } catch let error as WebHandoffError {
                XCTAssertEqual(error, expected)
            }
            let count = await stub.requests.count
            XCTAssertEqual(count, 1, "HTTP \(status) must not be retried")
        }
    }

    func testRejectsRepliesItCannotTrust() async throws {
        let bad = [
            #"{"code":"ABCDEFGI","expiresAt":"\#(tomorrow)"}"#,     // I is not in the alphabet
            #"{"code":"ABC","expiresAt":"\#(tomorrow)"}"#,
            #"{"code":"AB2CD3EF","expiresAt":"yesterday"}"#,
            #"{"code":"AB2CD3EF","expiresAt":"\#(ISO8601DateFormatter().string(from: now.addingTimeInterval(30)))"}"#,
            #"{"code":"AB2CD3EF","expiresAt":"\#(ISO8601DateFormatter().string(from: now.addingTimeInterval(7 * 86400)))"}"#,
        ]
        for body in bad {
            do {
                _ = try await service(StubTransport([(201, body)])).send(design: design)
                XCTFail("accepted \(body)")
            } catch let error as WebHandoffError {
                XCTAssertEqual(error, .invalidResponse, body)
            }
        }
    }

    func testAcceptsTheServersFractionalSecondTimestamps() throws {
        // Node's Date.toISOString() — what the server actually sends.
        let reply = Data(#"{"code":"AB2CD3EF","expiresAt":"2026-10-12T22:16:40.123Z"}"#.utf8)
        let response = HTTPURLResponse(url: WebHandoffService.endpoint, statusCode: 201, httpVersion: nil, headerFields: nil)!
        let sent = ISO8601DateFormatter().date(from: "2026-10-11T22:16:40Z")!
        XCTAssertEqual(try WebHandoffService.parse(reply, response, now: sent).code, "AB2CD3EF")
    }

    func testTheQRCodeEncodesTheLink() throws {
        let link = WebHandoffLink(code: "AB2CD3EF", expiresAt: now)
        let image = try XCTUnwrap(WebHandoffSheet.qrCode(for: link.url))
        XCTAssertGreaterThan(image.size.width, 200)
        // Decode it back with Core Image's QR detector.
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)!
        let features = detector.features(in: CIImage(cgImage: try XCTUnwrap(image.cgImage)))
        XCTAssertEqual((features.first as? CIQRCodeFeature)?.messageString, link.url.absoluteString)
    }
}
