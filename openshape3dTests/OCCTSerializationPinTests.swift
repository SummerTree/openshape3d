//
//  OCCTSerializationPinTests.swift
//  openshape3dTests
//
//  The brep persistence contract (docs/FREECAD_PLAYBOOK.md P1 / review
//  R4-O5): blobs carry NO derived triangulation and are written at a PINNED
//  TopTools format version, so a future OCCT upgrade can't silently change
//  what saved documents contain.
//

import XCTest
import simd
@testable import openshape3d

final class OCCTSerializationPinTests: XCTestCase {

    func testBlobExcludesTriangulationAndStaysStable() throws {
        let cyl = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 5, height: 20), placement: .identity))
        let before = try XCTUnwrap(OCCTKernel.serialize(cyl))
        // Tessellating stores triangulations into the shape's faces…
        _ = OCCTKernel.renderMesh(from: cyl)
        let after = try XCTUnwrap(OCCTKernel.serialize(cyl))
        // …but the blob must not balloon with them: derived state is rebuilt
        // on load, not persisted. (With triangles the same blob grows ~10×.)
        XCTAssertLessThan(Double(after.count), Double(before.count) * 1.5,
                          "triangulation leaked into the persisted blob")
    }

    func testPinnedFormatRoundTripsAnalytic() throws {
        let cyl = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 5, height: 20), placement: .identity))
        let blob = try XCTUnwrap(OCCTKernel.serialize(cyl))
        let restored = try XCTUnwrap(OCCTKernel.deserialize(blob))
        let counts = OCCTKernel.faceTypeCounts(restored)
        XCTAssertEqual(counts.cylindrical, 1)
        XCTAssertEqual(counts.planar, 2)
        XCTAssertEqual(OCCTKernel.volume(restored), OCCTKernel.volume(cyl),
                       accuracy: 1e-6)
    }

    func testGarbageBlobIsRefusedNotCrashed() {
        XCTAssertNil(OCCTKernel.deserialize(Data("not a brep".utf8)))
        XCTAssertNil(OCCTKernel.deserialize(Data()))
    }

    /// Fuzz family "count-*" (OCCTFuzzTests): the ASCII format's declared
    /// section counts ("Curve2ds 2147483647") send OCCT's reader into loops
    /// the read deadline cannot interrupt — a 2KB hostile blob spun for
    /// minutes. The plausibility gate refuses any count exceeding the blob's
    /// byte length BEFORE OCCT parses, so the refusal must be instant. A
    /// valid blob's counts are always tiny relative to its bytes, so the
    /// gate can never eat a legitimate document.
    func testInflatedSectionCountsAreRefusedInstantly() throws {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 10, depth: 10, height: 10), placement: .identity))
        let blob = try XCTUnwrap(OCCTKernel.serialize(box))
        let text = try XCTUnwrap(String(data: blob, encoding: .utf8))

        for poison in ["2147483647", "4294967295", "99999999999999999999",
                       "1000000000", "-1"] {
            var hit = false
            let mutated = text.components(separatedBy: "\n").map { line -> String in
                let parts = line.split(separator: " ")
                if !hit, parts.count == 2, parts[0] == "Curve2ds" {
                    hit = true
                    return "Curve2ds \(poison)"
                }
                return line
            }.joined(separator: "\n")
            let start = Date()
            XCTAssertNil(OCCTKernel.deserialize(Data(mutated.utf8)),
                         "count \(poison) must be refused")
            XCTAssertLessThan(Date().timeIntervalSince(start), 2.0,
                              "the refusal must come from the pre-gate, "
                              + "not a timed-out reader (count \(poison))")
        }

        // The IN-RECORD variant ("0 1000000000" deep in the data — the fuzz
        // corpus's process-KILLING case, an unchecked allocation rather than
        // a spin) is caught by the loose global ceiling.
        for poison in ["2147483647", "1000000000"] {
            var hit = false
            let mutated = text.components(separatedBy: "\n").map { line -> String in
                let parts = line.split(separator: " ")
                if !hit, parts.count == 2, Int(parts[0]) != nil, Int(parts[1]) != nil {
                    hit = true
                    return "\(parts[0]) \(poison)"
                }
                return line
            }.joined(separator: "\n")
            let start = Date()
            XCTAssertNil(OCCTKernel.deserialize(Data(mutated.utf8)),
                         "in-record count \(poison) must be refused")
            XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        }

        // A NON-TEXT byte anywhere (a NUL splitting a token, a high 0xFF from
        // a bit-flip) is structurally impossible in the printable-ASCII BRep
        // format and desyncs OCCT's reader into a crash — rejected in one
        // pass (fuzz nul-at-*, flip-*=FF).
        for evil: UInt8 in [0x00, 0xFF, 0x01, 0x7F] {
            var corrupted = blob
            corrupted[corrupted.count / 2] = evil
            XCTAssertNil(OCCTKernel.deserialize(corrupted),
                         "a 0x\(String(evil, radix: 16)) byte must be refused")
        }

        // The gate never rejects the unmutated blob.
        XCTAssertNotNil(OCCTKernel.deserialize(blob))
    }

    /// Non-finite float literals (a coordinate as "1e999" → inf, a bare
    /// "nan") crash geometry reconstruction INSIDE BRepTools::Read, before
    /// the finite-bounds guard can see the shape (fuzz numeric-1e999). The
    /// pre-gate rejects any token that parses wholly to a non-finite double;
    /// finite floats and "1e-07"-style tolerances are kept.
    func testNonFiniteFloatLiteralsAreRefused() throws {
        // The cylinder has genuine non-integer coordinates (a box's are whole).
        let cyl = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 3, height: 5), placement: .identity))
        let blob = try XCTUnwrap(OCCTKernel.serialize(cyl))
        let text = try XCTUnwrap(String(data: blob, encoding: .utf8))
        // A real dotted coordinate token to poison in place.
        let float = try XCTUnwrap(
            text.split(whereSeparator: { $0 == " " || $0 == "\n" })
                .first { tok in
                    tok.contains(".") && Double(tok) != nil
                }
                .map(String.init),
            "expected a decimal coordinate token in the cylinder blob")

        for poison in ["1e999", "-1e999", "nan", "inf"] {
            guard let r = text.range(of: " \(float)") else {
                return XCTFail("could not locate the coordinate token")
            }
            let mutated = text.replacingCharacters(in: r, with: " \(poison)")
            let start = Date()
            XCTAssertNil(OCCTKernel.deserialize(Data(mutated.utf8)),
                         "a \(poison) coordinate must be refused, not parsed")
            XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        }
        // A "0x…" hex token where a coordinate belongs: strtod reads it as a
        // hex float, but OCCT's istream>> reads only "0" and desyncs — a
        // crash records later (fuzz numeric-hex). Rejected by prefix; the
        // "4CN"-style edge-continuity codes a real blob contains are kept
        // (the round-trip test proves it).
        if let r = text.range(of: " \(float)") {
            let mutated = text.replacingCharacters(in: r, with: " 0x41414141")
            XCTAssertNil(OCCTKernel.deserialize(Data(mutated.utf8)),
                         "a hex coordinate must be refused, not parsed")
        }
        XCTAssertNotNil(OCCTKernel.deserialize(blob), "the real blob still loads")
    }
}
