//
//  BugReportingTests.swift
//  openshape3dTests
//
//  The bug reporter's pure parts: config parsing, the Firestore REST
//  document shape, attachment paths, and server error extraction. No
//  network — the service's two calls are exercised by hand against the
//  real project (docs/BUG_REPORTS.md).
//

import XCTest
@testable import openshape3d

final class BugReportingTests: XCTestCase {

    private let context = BugReportContext(
        appVersion: "1.0", build: "1", osVersion: "iOS 26.0", deviceModel: "iPad",
        documentName: "Bracket", bodyCount: 3, featureCount: 7, lastAction: "Fillet")

    func testConfigParsesRequiredKeysAndRejectsPlaceholders() {
        let good = FirebaseConfig(plist: [
            "API_KEY": "AIza-real", "PROJECT_ID": "openshape3d",
            "STORAGE_BUCKET": "openshape3d.firebasestorage.app", "IS_ANALYTICS_ENABLED": false,
        ])
        XCTAssertEqual(good, FirebaseConfig(
            apiKey: "AIza-real", projectID: "openshape3d",
            storageBucket: "openshape3d.firebasestorage.app"))
        XCTAssertNil(FirebaseConfig(plist: ["API_KEY": "x", "PROJECT_ID": "p"]), "bucket missing")
        XCTAssertNil(FirebaseConfig(plist: [
            "API_KEY": "YOUR-FIREBASE-WEB-API-KEY", "PROJECT_ID": "p", "STORAGE_BUCKET": "b",
        ]), "the example plist's placeholder must not count as configured")
        XCTAssertNil(FirebaseConfig.load(from: Bundle(for: Self.self)),
                     "the test bundle carries no config")
    }

    func testFirestoreFieldsShape() throws {
        let report = BugReport(
            title: "  Fillet crashes  ", details: "It closes the app.\n", steps: "1. Fillet R2",
            contactEmail: " me@example.com ", context: context)
        let date = Date(timeIntervalSince1970: 1_757_000_000)
        let fields = FirestoreEncoding.fields(
            for: report, reportID: "abc", createdAt: date,
            attachmentPath: "bugReports/abc/Bracket.os3d", attachmentBytes: 1234)

        XCTAssertEqual(fields["title"] as? [String: String], ["stringValue": "Fillet crashes"])
        XCTAssertEqual(fields["details"] as? [String: String], ["stringValue": "It closes the app."])
        XCTAssertEqual(fields["contactEmail"] as? [String: String], ["stringValue": "me@example.com"])
        XCTAssertEqual(fields["status"] as? [String: String], ["stringValue": "new"])
        XCTAssertEqual((fields["createdAt"] as? [String: String])?["timestampValue"],
                       "2025-09-04T15:33:20.000Z")

        let ctx = try XCTUnwrap(((fields["context"] as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any])
        XCTAssertEqual(ctx["bodyCount"] as? [String: String], ["integerValue": "3"],
                       "Firestore REST integers travel as decimal strings")
        XCTAssertEqual(ctx["documentName"] as? [String: String], ["stringValue": "Bracket"])
        XCTAssertEqual(ctx["lastAction"] as? [String: String], ["stringValue": "Fillet"])

        let att = try XCTUnwrap(((fields["attachment"] as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any])
        XCTAssertEqual(att["path"] as? [String: String], ["stringValue": "bugReports/abc/Bracket.os3d"])
        XCTAssertEqual(att["bytes"] as? [String: String], ["integerValue": "1234"])

        // The whole thing must be JSON-serialisable as the request body.
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["fields": fields]))

        // No attachment → no attachment field, and no context extras when absent.
        var plain = report
        plain.context.documentName = nil
        plain.context.lastAction = nil
        let bare = FirestoreEncoding.fields(for: plain, reportID: "x", createdAt: date,
                                            attachmentPath: nil, attachmentBytes: nil)
        XCTAssertNil(bare["attachment"])
        XCTAssertNil(bare["attachmentError"])
        let failed = FirestoreEncoding.fields(
            for: plain, reportID: "x", createdAt: date, attachmentPath: nil, attachmentBytes: nil,
            attachmentError: "bucket missing")
        XCTAssertEqual(failed["attachmentError"] as? [String: String], ["stringValue": "bucket missing"])
        let bareCtx = ((bare["context"] as? [String: Any])?["mapValue"] as? [String: Any])?["fields"] as? [String: Any]
        XCTAssertNil(bareCtx?["documentName"])
        XCTAssertNil(bareCtx?["lastAction"])
    }

    func testAttachmentPathSanitisesFileNames() {
        XCTAssertEqual(FirestoreEncoding.attachmentPath(reportID: "r1", fileName: "Bracket.os3d"),
                       "bugReports/r1/Bracket.os3d")
        XCTAssertEqual(FirestoreEncoding.attachmentPath(reportID: "r1", fileName: "a/b:c?d.os3d"),
                       "bugReports/r1/a_b_c_d.os3d")
        XCTAssertEqual(FirestoreEncoding.attachmentPath(reportID: "r1", fileName: ""),
                       "bugReports/r1/design.os3d")
    }

    func testContextSummaryAndErrors() {
        XCTAssertEqual(context.summaryLines, [
            "App 1.0 (1)", "iOS 26.0, iPad",
            "Design “Bracket”: 3 bodies, 7 features", "Last action: Fillet",
        ])
        let body = Data(#"{"error":{"code":403,"message":"Missing or insufficient permissions."}}"#.utf8)
        XCTAssertEqual(BugReportService.serverMessage(body), "Missing or insufficient permissions.")
        XCTAssertEqual(BugReportService.serverMessage(Data("plain".utf8)), "plain")
        XCTAssertEqual(BugReportService.serverMessage(Data()), "no details")
        XCTAssertTrue(BugReportError.attachmentTooLarge(bytes: 50 * 1_048_576)
            .errorDescription?.contains("50.0 MB") == true)
    }
}
