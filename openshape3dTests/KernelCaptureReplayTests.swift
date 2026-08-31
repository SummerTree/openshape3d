//
//  KernelCaptureReplayTests.swift
//  openshape3dTests
//
//  Replays every committed capture fixture through the real kernel entry
//  points and holds it to its manifest's `expect` block — FreeCAD's
//  frozen-.brep regression pattern (docs/FREECAD_PLAYBOOK.md D3). Promoting
//  a live failure to a permanent regression test is: pull the bundle
//  (scripts/fetch_captures.sh), drop it under Fixtures/Captures/, add an
//  `expect` block to its manifest.
//
//  Fixtures live in the REPO, not the test bundle: the synchronized test
//  group flat-copies resources, so two bundles both containing a
//  manifest.json break the build outright ("Multiple commands produce…" —
//  measured). The Fixtures folder is excluded from the target (pbxproj
//  membership exception) and read off the host filesystem, which simulator
//  tests share. `#filePath` is baked at build time, so this only works where
//  the build happened — which is where tests run.
//

import XCTest
@testable import openshape3d

final class KernelCaptureReplayTests: XCTestCase {

    private static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Captures", isDirectory: true)

    private func fixtureBundles() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: Self.fixturesDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return entries.filter(\.hasDirectoryPath)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testEveryCommittedFixtureReplaysToItsExpectedOutcome() throws {
        let bundles = fixtureBundles()
        XCTAssertFalse(bundles.isEmpty,
                       "no fixtures under \(Self.fixturesDir.path) — at least the "
                       + "seed fixture should be committed; if fixtures were "
                       + "deliberately removed, remove this harness too")
        for bundle in bundles {
            let name = bundle.lastPathComponent
            let manifest = try KernelCaptureReplay.manifest(bundleAt: bundle)
            let outcome = try KernelCaptureReplay.replay(bundleAt: bundle)
            guard let expect = manifest["expect"] as? [String: Any] else {
                XCTFail("\(name): no expect block — a fixture that asserts "
                        + "nothing only proves the process survived; add "
                        + #""expect": {"outcome": "failure"} at minimum"#)
                continue
            }
            switch expect["outcome"] as? String {
            case "failure":
                XCTAssertFalse(outcome.succeeded,
                               "\(name): expected the op to fail, got: \(outcome.detail)")
            case "success":
                XCTAssertTrue(outcome.succeeded,
                              "\(name): expected the op to succeed, got: \(outcome.detail)")
            default:
                XCTFail("\(name): expect.outcome must be \"success\" or \"failure\"")
            }
            if let fragment = expect["errorContains"] as? String {
                XCTAssertTrue(outcome.detail.contains(fragment),
                              "\(name): detail \"\(outcome.detail)\" lacks \"\(fragment)\"")
            }
            if let volume = expect["volumeMM3"] as? Double {
                let accuracy = expect["volumeToleranceMM3"] as? Double ?? 1e-6
                XCTAssertEqual(outcome.volumeMM3 ?? .nan, volume,
                               accuracy: accuracy, name)
            }
        }
    }
}
