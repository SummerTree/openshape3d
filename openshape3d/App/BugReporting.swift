//
//  BugReporting.swift
//  openshape3d
//
//  In-app bug reports. A user fills in a short form (optionally attaching
//  the design they are working on as an .os3d archive) and it lands in the
//  Firestore collection `bugReports` of the Firebase project named by the
//  bundled `GoogleService-Info.plist`; the attachment goes to the project's
//  Storage bucket under `bugReports/<reportID>/`.
//
//  Deliberately NO Firebase SDK: the two writes are plain HTTPS calls to the
//  Firestore and Cloud Storage REST APIs, so nothing else ships (no
//  analytics, no crash reporting, no identifiers) and nothing runs unless
//  the user presses Send. The plist is read for three values — API key,
//  project ID, bucket — and is git-ignored; a build without it shows a
//  "not configured" notice instead of the form.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Config

/// The three values the reporter needs from `GoogleService-Info.plist`.
nonisolated struct FirebaseConfig: Equatable, Sendable {
    let apiKey: String
    let projectID: String
    let storageBucket: String

    init(apiKey: String, projectID: String, storageBucket: String) {
        self.apiKey = apiKey
        self.projectID = projectID
        self.storageBucket = storageBucket
    }

    /// nil when a required key is missing or still a placeholder.
    init?(plist: [String: Any]) {
        guard let apiKey = plist["API_KEY"] as? String, !apiKey.isEmpty,
              !apiKey.hasPrefix("YOUR-"),
              let projectID = plist["PROJECT_ID"] as? String, !projectID.isEmpty,
              !projectID.hasPrefix("your-"),
              let bucket = plist["STORAGE_BUCKET"] as? String, !bucket.isEmpty
        else { return nil }
        self.init(apiKey: apiKey, projectID: projectID, storageBucket: bucket)
    }

    static func load(from bundle: Bundle = .main) -> FirebaseConfig? {
        guard let url = bundle.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return FirebaseConfig(plist: plist)
    }

    /// The app's config, read once. nil in builds without the plist.
    nonisolated(unsafe) static let bundled: FirebaseConfig? = load()
}

// MARK: - Report

/// What the form collects, plus the context shown to the user as
/// "included automatically" — nothing is sent that the sheet doesn't list.
nonisolated struct BugReport: Equatable, Sendable {
    var title: String
    var details: String
    var steps: String
    var contactEmail: String
    var context: BugReportContext
}

nonisolated struct BugReportContext: Equatable, Sendable {
    var appVersion: String
    var build: String
    var osVersion: String
    var deviceModel: String
    var documentName: String?
    var bodyCount: Int
    var featureCount: Int
    /// The undo stack's top title — the last thing the user did.
    var lastAction: String?

    /// One line per fact, for the form's "Included with your report" footer.
    var summaryLines: [String] {
        var lines = ["App \(appVersion) (\(build))", "\(osVersion), \(deviceModel)"]
        if let documentName {
            lines.append("Design “\(documentName)”: \(bodyCount) bodies, \(featureCount) features")
        }
        if let lastAction { lines.append("Last action: \(lastAction)") }
        return lines
    }

    @MainActor
    static func current(documentName: String?, bodyCount: Int, featureCount: Int,
                        lastAction: String?) -> BugReportContext {
        let info = Bundle.main.infoDictionary ?? [:]
        #if canImport(UIKit)
        let device = UIDevice.current
        let os = "\(device.systemName) \(device.systemVersion)"
        let model = device.model
        #else
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let model = "Mac"
        #endif
        return BugReportContext(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            osVersion: os,
            deviceModel: model,
            documentName: documentName,
            bodyCount: bodyCount,
            featureCount: featureCount,
            lastAction: lastAction)
    }
}

nonisolated struct BugAttachment: Sendable {
    let fileName: String
    let data: Data

    /// Storage uploads over this are refused up front with a clear message
    /// rather than failing minutes into a cellular upload.
    static let maxBytes = 40 * 1024 * 1024
}

nonisolated enum BugReportError: LocalizedError, Equatable {
    case notConfigured
    case attachmentTooLarge(bytes: Int)
    case badURL
    case http(status: Int, message: String)
    case unexpectedResponse
    /// The Storage bucket answered 404: not provisioned, or misnamed in the plist.
    case storageBucketMissing(bucket: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Bug reporting isn't configured in this build (GoogleService-Info.plist is missing)."
        case .attachmentTooLarge(let bytes):
            let mb = Double(bytes) / 1_048_576
            return String(format: "The design is %.1f MB; attachments are limited to %d MB. Send the report without it, or export the archive and share it another way.", mb, BugAttachment.maxBytes / 1_048_576)
        case .badURL:
            return "Couldn't build the upload address."
        case .http(let status, let message):
            return "The server answered \(status): \(message)"
        case .unexpectedResponse:
            return "The server's answer wasn't understood."
        case .storageBucketMissing(let bucket):
            return "The Storage bucket “\(bucket)” doesn't exist yet (Firebase console → Storage → Get started), so the design couldn't be attached."
        }
    }
}

/// What `submit` hands back: the report's ID, and — when the design could
/// not be uploaded but the report itself was filed — why.
nonisolated struct BugReportReceipt: Equatable, Sendable {
    let reportID: String
    let attachmentError: String?
}

// MARK: - Firestore REST encoding (pure, unit-tested)

nonisolated enum FirestoreEncoding {
    /// The `fields` object of a Firestore REST document for one report.
    static func fields(for report: BugReport, reportID: String, createdAt: Date,
                       attachmentPath: String?, attachmentBytes: Int?,
                       attachmentError: String? = nil) -> [String: Any] {
        var fields: [String: Any] = [
            "reportID": string(reportID),
            "title": string(report.title.trimmingCharacters(in: .whitespacesAndNewlines)),
            "details": string(report.details.trimmingCharacters(in: .whitespacesAndNewlines)),
            "steps": string(report.steps.trimmingCharacters(in: .whitespacesAndNewlines)),
            "contactEmail": string(report.contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)),
            "createdAt": ["timestampValue": Self.iso8601.string(from: createdAt)],
            "status": string("new"),
            "context": ["mapValue": ["fields": contextFields(report.context)]],
        ]
        if let attachmentPath, let attachmentBytes {
            fields["attachment"] = ["mapValue": ["fields": [
                "path": string(attachmentPath),
                "bytes": integer(attachmentBytes),
            ]]]
        }
        if let attachmentError {
            fields["attachmentError"] = string(attachmentError)
        }
        return fields
    }

    static func contextFields(_ context: BugReportContext) -> [String: Any] {
        var fields: [String: Any] = [
            "appVersion": string(context.appVersion),
            "build": string(context.build),
            "osVersion": string(context.osVersion),
            "deviceModel": string(context.deviceModel),
            "bodyCount": integer(context.bodyCount),
            "featureCount": integer(context.featureCount),
        ]
        if let name = context.documentName { fields["documentName"] = string(name) }
        if let action = context.lastAction { fields["lastAction"] = string(action) }
        return fields
    }

    static func string(_ value: String) -> [String: Any] { ["stringValue": value] }
    /// Firestore's REST API wants 64-bit integers as decimal strings.
    static func integer(_ value: Int) -> [String: Any] { ["integerValue": String(value)] }

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Storage object name for a report's attachment; percent-encoded for
    /// the `name=` query parameter by the caller.
    static func attachmentPath(reportID: String, fileName: String) -> String {
        let safe = fileName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>#"))
            .joined(separator: "_")
        return "bugReports/\(reportID)/\(safe.isEmpty ? "design.os3d" : safe)"
    }
}

// MARK: - Service

/// Two HTTPS calls: the attachment (if any) to Cloud Storage, then the
/// document to Firestore. Runs off the main actor; the sheet awaits it.
nonisolated struct BugReportService: Sendable {
    let config: FirebaseConfig
    var session: URLSession = .shared

    /// Files the report. The attachment goes first; if THAT fails the report
    /// is still filed, carrying the upload error, so a missing bucket or a
    /// flaky connection never swallows the bug description itself. Only a
    /// Firestore failure throws.
    func submit(_ report: BugReport, attachment: BugAttachment?) async throws -> BugReportReceipt {
        let reportID = UUID().uuidString.lowercased()
        var attachmentPath: String?
        var attachmentBytes: Int?
        var attachmentError: String?
        if let attachment {
            if attachment.data.count > BugAttachment.maxBytes {
                attachmentError = BugReportError.attachmentTooLarge(bytes: attachment.data.count)
                    .errorDescription
            } else {
                let path = FirestoreEncoding.attachmentPath(reportID: reportID, fileName: attachment.fileName)
                do {
                    try await upload(attachment.data, to: path)
                    attachmentPath = path
                    attachmentBytes = attachment.data.count
                } catch BugReportError.http(let status, _) where status == 404 {
                    attachmentError = BugReportError.storageBucketMissing(bucket: config.storageBucket)
                        .errorDescription
                } catch {
                    attachmentError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
        let fields = FirestoreEncoding.fields(
            for: report, reportID: reportID, createdAt: Date(),
            attachmentPath: attachmentPath, attachmentBytes: attachmentBytes,
            attachmentError: attachmentError)
        try await createDocument(id: reportID, fields: fields)
        return BugReportReceipt(reportID: reportID, attachmentError: attachmentError)
    }

    private func upload(_ data: Data, to objectPath: String) async throws {
        var components = URLComponents(string:
            "https://firebasestorage.googleapis.com/v0/b/\(config.storageBucket)/o")
        components?.queryItems = [
            URLQueryItem(name: "uploadType", value: "media"),
            URLQueryItem(name: "name", value: objectPath),
        ]
        guard let url = components?.url else { throw BugReportError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        let (body, response) = try await session.upload(for: request, from: data)
        try Self.check(response, body: body)
    }

    private func createDocument(id: String, fields: [String: Any]) async throws {
        var components = URLComponents(string:
            "https://firestore.googleapis.com/v1/projects/\(config.projectID)/databases/(default)/documents/bugReports")
        components?.queryItems = [
            URLQueryItem(name: "documentId", value: id),
            URLQueryItem(name: "key", value: config.apiKey),
        ]
        guard let url = components?.url else { throw BugReportError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": fields])
        request.timeoutInterval = 60
        let (body, response) = try await session.data(for: request)
        try Self.check(response, body: body)
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw BugReportError.unexpectedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw BugReportError.http(status: http.statusCode, message: serverMessage(body))
        }
    }

    /// Google APIs answer errors as `{"error": {"message": …}}`.
    static func serverMessage(_ body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        let text = String(decoding: body.prefix(200), as: UTF8.self)
        return text.isEmpty ? "no details" : text
    }
}
