//
//  PersistedFeatureTests.swift
//  openshape3dTests
//
//  Round-trip coverage for the Phase D feature encode/decode helpers
//  (`encodeFeatureKind`/`decodeFeatureKind`, `encodeBodyIDs`/`decodeBodyIDs`,
//  and the `FeatureNode` <-> `PersistedFeature` bridge). SwiftData persistence
//  itself (ModelContainer/ModelContext) is intentionally NOT exercised here —
//  only the pure JSON helpers plus an in-memory @Model instance.
//

import XCTest
@testable import openshape3d

final class PersistedFeatureTests: XCTestCase {

    /// Order-stable JSON so structural equality can be asserted without
    /// requiring `FeatureKind: Equatable`.
    private func canonicalJSON(_ kind: FeatureKind) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(kind)
    }

    private func assertRoundTrips(_ kind: FeatureKind,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let data = encodeFeatureKind(kind)
        XCTAssertFalse(data.isEmpty, "encode produced empty data", file: file, line: line)
        let decoded = try XCTUnwrap(decodeFeatureKind(data), file: file, line: line)
        XCTAssertEqual(try canonicalJSON(decoded),
                       try canonicalJSON(kind),
                       "decoded FeatureKind is not structurally equal",
                       file: file, line: line)
    }

    func testPrimitiveKindRoundTrips() throws {
        var placement = Transform3D.identity
        placement.translation = SIMD3(1, 2, 3)
        placement.scale = 2
        let kind = FeatureKind.primitive(
            spec: .box(width: 10, depth: 20, height: 30),
            placement: placement)
        try assertRoundTrips(kind)

        // Stronger, human-readable check on the primitive payload.
        let decoded = try XCTUnwrap(decodeFeatureKind(encodeFeatureKind(kind)))
        guard case let .primitive(spec, place) = decoded else {
            return XCTFail("expected .primitive, got \(decoded)")
        }
        XCTAssertEqual(spec, .box(width: 10, depth: 20, height: 30))
        XCTAssertEqual(place, placement)
    }

    func testExtrudeKindRoundTrips() throws {
        let profile = ProfileRef(
            sketchID: SketchID(),
            entityIDs: [UUID(), UUID()],
            holeEntityIDs: [[UUID()]],
            seedPoint: SIMD2(0.25, 0.75))
        let kind = FeatureKind.extrude(
            profile: profile,
            plane: PlaneRef(source: .ground),
            distance: Expr(value: 15),
            symmetric: true,
            boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: [])
        try assertRoundTrips(kind)
    }

    func testBodyIDsRoundTrip() throws {
        let ids = [BodyID(), BodyID(), BodyID()]
        let data = encodeBodyIDs(ids)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(decodeBodyIDs(data), ids)
    }

    func testEmptyBlobsDecodeToNil() {
        XCTAssertNil(decodeFeatureKind(Data()))
        XCTAssertNil(decodeBodyIDs(Data()))
    }

    /// Full FeatureNode <-> PersistedFeature bridge. The @Model is built in
    /// memory (no ModelContainer/ModelContext), so this covers the helper
    /// mapping only, not SwiftData storage.
    func testFeatureNodeBridgeRoundTrips() throws {
        let node = FeatureNode(
            id: FeatureID(),
            name: "Extrude 1",
            kind: .primitive(spec: .sphere(radius: 5), placement: .identity),
            suppressed: true,
            outputBodyIDs: [BodyID(), BodyID()])

        let pf = encodeFeature(node, orderIndex: 3)
        XCTAssertEqual(pf.featureID, node.id.raw)
        XCTAssertEqual(pf.orderIndex, 3)
        XCTAssertEqual(pf.name, "Extrude 1")
        XCTAssertTrue(pf.suppressed)

        let back = try XCTUnwrap(decodeFeature(pf))
        XCTAssertEqual(back.id, node.id)
        XCTAssertEqual(back.name, node.name)
        XCTAssertEqual(back.suppressed, node.suppressed)
        XCTAssertEqual(back.outputBodyIDs, node.outputBodyIDs)
        XCTAssertEqual(try canonicalJSON(back.kind), try canonicalJSON(node.kind))
    }
}
