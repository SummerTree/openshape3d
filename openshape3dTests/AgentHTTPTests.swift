//
//  AgentHTTPTests.swift
//  openshape3dTests
//
//  Framing for the agent bridge. Pure values — no sockets, no
//  `EditorViewModel` (which owns a `DocumentSession`, and an in-process
//  `ModelContainer` crashes XCTest — STATUS_AND_NEXT_STEPS gotcha 1).
//
//  The cases that matter are the ones a hand-rolled parser gets wrong: a body
//  split across two reads, a `Content-Length` that disagrees with what arrived,
//  and a head that never terminates. Each of those fails as a hang or a
//  truncated command rather than an error, which is exactly the kind of bug
//  that is invisible until an agent is mid-way through a model.
//

import XCTest
@testable import openshape3d

final class AgentHTTPTests: XCTestCase {

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    /// A POST with a correct `Content-Length`. Computed, never hand-counted:
    /// getting that number wrong is precisely the bug the parser must catch, so
    /// a fixture that miscounts tests the wrong thing (it did, first time —
    /// a 23-byte body labelled 22).
    private func post(_ body: String, path: String = "/v1/command") -> String {
        "POST \(path) HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    private func parsed(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> AgentRequest? {
        guard case let .complete(request) = AgentHTTP.parse(bytes(text)) else {
            XCTFail("expected a complete request", file: file, line: line)
            return nil
        }
        return request
    }

    // MARK: Request line and target

    func testParsesSimpleGET() {
        let request = parsed("GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.path, "/v1/health")
        XCTAssertEqual(request?.headers["host"], "127.0.0.1")
        XCTAssertEqual(request?.body, Data())
    }

    func testMethodIsUppercased() {
        XCTAssertEqual(parsed("get /v1/health HTTP/1.1\r\n\r\n")?.method, "GET")
    }

    func testSplitsQueryOffThePath() {
        let request = parsed("GET /v1/screenshot?w=800&h=600 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(request?.path, "/v1/screenshot")
        XCTAssertEqual(request?.query["w"], "800")
        XCTAssertEqual(request?.query["h"], "600")
    }

    func testDecodesPercentEncodingInQuery() {
        let request = parsed("GET /v1/state?note=a%20b HTTP/1.1\r\n\r\n")
        XCTAssertEqual(request?.query["note"], "a b")
    }

    func testValuelessQueryItemIsEmptyNotMissing() {
        let request = parsed("GET /v1/state?verbose HTTP/1.1\r\n\r\n")
        XCTAssertEqual(request?.query["verbose"], "")
    }

    func testHeaderNamesAreLowercasedAndValuesTrimmed() {
        let request = parsed("GET /v1/health HTTP/1.1\r\nContent-Type:   application/json   \r\n\r\n")
        XCTAssertEqual(request?.headers["content-type"], "application/json")
    }

    // MARK: Incompleteness — the reason this file exists

    func testHeadWithoutTerminatorIsIncomplete() {
        XCTAssertEqual(AgentHTTP.parse(bytes("GET /v1/health HTTP/1.1\r\nHost: x")), .incomplete)
    }

    func testEmptyBufferIsIncomplete() {
        XCTAssertEqual(AgentHTTP.parse(Data()), .incomplete)
    }

    func testBodyShorterThanContentLengthIsIncomplete() {
        let partial = "POST /v1/command HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"id\":\"mod"
        XCTAssertEqual(AgentHTTP.parse(bytes(partial)), .incomplete)
    }

    /// The split-packet case: the same request delivered one byte at a time must
    /// stay `.incomplete` until the last byte and then parse identically.
    func testRequestArrivingByteByByteParsesOnlyWhenWhole() {
        let all = bytes(post(#"{"id":"view.isometric"}"#))
        var buffer = Data()
        for (offset, byte) in all.enumerated() {
            buffer.append(byte)
            let result = AgentHTTP.parse(buffer)
            if offset < all.count - 1 {
                XCTAssertEqual(result, .incomplete, "premature parse at byte \(offset)")
            } else {
                guard case let .complete(request) = result else {
                    return XCTFail("last byte did not complete the request")
                }
                XCTAssertEqual(request.jsonBody?["id"] as? String, "view.isometric")
            }
        }
    }

    // MARK: Bodies

    func testReadsBodyOfExactlyContentLength() {
        let request = parsed(post(#"{"id":"view.isometric"}"#))
        XCTAssertEqual(request?.jsonBody?["id"] as? String, "view.isometric")
    }

    /// A pipelined second request must not bleed into the first one's body.
    func testExtraBytesBeyondContentLengthAreNotConsumed() {
        let request = parsed("POST /v1/command HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}GET /v1/health HTTP/1.1\r\n\r\n")
        XCTAssertEqual(request?.body, bytes("{}"))
    }

    func testMissingContentLengthMeansNoBody() {
        let request = parsed("POST /v1/command HTTP/1.1\r\n\r\n{\"id\":\"ignored\"}")
        XCTAssertEqual(request?.body, Data())
        XCTAssertNil(request?.jsonBody)
    }

    func testOversizedContentLengthIsRefusedNotBuffered() {
        let head = "POST /v1/command HTTP/1.1\r\nContent-Length: \(AgentHTTP.maxBodyBytes + 1)\r\n\r\n"
        XCTAssertEqual(AgentHTTP.parse(bytes(head)), .tooLarge)
    }

    // MARK: Malformed

    func testRequestLineWithOneFieldIsMalformed() {
        guard case .malformed = AgentHTTP.parse(bytes("GET\r\n\r\n")) else {
            return XCTFail("expected malformed")
        }
    }

    func testHeaderWithoutColonIsMalformed() {
        guard case .malformed = AgentHTTP.parse(bytes("GET /v1/health HTTP/1.1\r\nnonsense\r\n\r\n")) else {
            return XCTFail("expected malformed")
        }
    }

    func testNonNumericContentLengthIsMalformed() {
        guard case .malformed = AgentHTTP.parse(bytes("POST /v1/command HTTP/1.1\r\nContent-Length: soon\r\n\r\n")) else {
            return XCTFail("expected malformed")
        }
    }

    /// Without this cap a client that never terminates its head is
    /// indistinguishable from one that is merely slow, and the buffer grows
    /// forever.
    func testUnterminatedHeadIsRefusedOnceItPassesTheCap() {
        let flood = "GET /v1/health HTTP/1.1\r\n" + String(repeating: "X", count: AgentHTTP.maxHeadBytes + 1)
        guard case .malformed = AgentHTTP.parse(bytes(flood)) else {
            return XCTFail("expected malformed")
        }
    }

    // MARK: Query bounds

    func testIntQueryClampsToRange() {
        let request = parsed("GET /v1/screenshot?w=99999&h=1 HTTP/1.1\r\n\r\n")
        XCTAssertEqual(request?.intQuery("w", default: 1024, min: 64, max: 4096), 4096)
        XCTAssertEqual(request?.intQuery("h", default: 1024, min: 64, max: 4096), 64)
        XCTAssertEqual(request?.intQuery("absent", default: 1024, min: 64, max: 4096), 1024)
        XCTAssertEqual(request?.intQuery("w", default: 7, min: 1, max: 10), 10)
    }

    func testNonNumericSizeFallsBackToTheDefault() {
        let request = parsed("GET /v1/screenshot?w=big HTTP/1.1\r\n\r\n")
        XCTAssertEqual(request?.intQuery("w", default: 1024, min: 64, max: 4096), 1024)
    }
}
