//
//  ClevisFilletCrashTests.swift
//  openshape3dTests
//
//  Practice sheet 4.7's clevis plate: an R2 fillet on the two concave arcs
//  where the R11 lug cylinder meets the plate's side faces killed the app
//  (2026-09-04). The captured body is a committed fixture; this pins that the
//  op either builds or fails TYPED — never takes the process down.
//

import Darwin
import XCTest
import simd
@testable import openshape3d

final class ClevisFilletCrashTests: XCTestCase {

    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Captures/clevis-lug-junction-fillet-r2", isDirectory: true)

    func testLugJunctionFilletDoesNotCrash() throws {
        // (To see WHERE a fault happens, install `signal(SIGSEGV/SIGBUS/
        // SIGTRAP)` handlers here that `backtrace_symbols_fd` and `_exit` —
        // that is how the ChFi3d frame below was found. Leave them out
        // normally: the bridge's crash guard is what this test proves.)
        let manifest = try KernelCaptureReplay.manifest(bundleAt: Self.fixture)
        let params = try XCTUnwrap(manifest["params"] as? [String: Any])
        let points = try XCTUnwrap(params["points"] as? [[Double]]).map { SIMD3($0[0], $0[1], $0[2]) }
        let outcome = try KernelCaptureReplay.replay(bundleAt: Self.fixture)
        // Whatever the kernel decides, the process is still here.
        NSLog("clevis fillet outcome: succeeded=\(outcome.succeeded) detail=\(outcome.detail) volume=\(String(describing: outcome.volumeMM3)) points=\(points)")
        // Today OCCT faults in ChFi3d_Builder::PerformOneCorner →
        // Extrema_ExtCC::Points on this input. With the signal conversion
        // armed, ChFi3d's own try block catches it and the op reports two
        // faulty contours (partialResult) — a typed failure, no crash. Should
        // a future OCCT build it, that is fine too: a concave fillet fills
        // the corner, so the volume can only grow.
        if outcome.succeeded {
            XCTAssertGreaterThan(outcome.volumeMM3 ?? 0, 130486.74, "a concave fillet fills the corner")
        } else {
            XCTAssertFalse(outcome.detail.isEmpty, "a typed refusal names its reason")
        }
    }
}
