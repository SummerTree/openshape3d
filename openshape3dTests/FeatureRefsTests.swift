//
//  FeatureRefsTests.swift
//  openshape3dTests
//
//  Task A0 — Codable round-trip + Hashable coverage for the Phase D feature-graph
//  reference types (FeatureRefs.swift). Every persistent reference must survive a
//  JSON encode/decode unchanged (it is stored as a JSON blob in the SwiftData
//  store) and be usable as a dictionary/set key.
//

import XCTest
import simd
@testable import openshape3d

final class FeatureRefsTests: XCTestCase {

    /// Encode → decode via JSON and assert the value is unchanged.
    private func roundTrip<T: Codable & Equatable>(
        _ value: T, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data)
        XCTAssertEqual(decoded, value, "round-trip mismatch", file: file, line: line)
    }

    private func sampleBodyRef() -> BodyRef {
        BodyRef(producer: FeatureID(), bodyID: BodyID())
    }

    private func planarSignature() -> FaceSignature {
        FaceSignature(
            kind: .planar,
            normal: SIMD3(0, 0, 1),
            centroid: SIMD3(1, 2, 3),
            area: 4.25,
            planeOffset: 0.5
        )
    }

    private func faceRef(_ role: FaceRole) -> FaceRef {
        FaceRef(
            body: sampleBodyRef(),
            creator: FeatureID(),
            role: role,
            signature: planarSignature()
        )
    }

    // MARK: - FeatureID

    func testFeatureIDRoundTrip() throws {
        try roundTrip(FeatureID())
        try roundTrip(FeatureID(raw: UUID()))
    }

    func testFeatureIDInitRawPreservesValue() {
        let uuid = UUID()
        XCTAssertEqual(FeatureID(raw: uuid).raw, uuid)
    }

    func testDistinctFeatureIDsAreUnequal() {
        XCTAssertNotEqual(FeatureID(), FeatureID())
    }

    // MARK: - BodyRef

    func testBodyRefRoundTrip() throws {
        try roundTrip(sampleBodyRef())
    }

    // MARK: - FaceRef (every FaceRole case)

    func testFaceRefRoundTripAllRoles() throws {
        let roles: [FaceRole] = [
            .boxFace(.px), .boxFace(.nx), .boxFace(.py),
            .boxFace(.ny), .boxFace(.pz), .boxFace(.nz),
            .cylinderSide,
            .cylinderCap(top: true), .cylinderCap(top: false),
            .sphereSurface,
            .extrudeStartCap,
            .extrudeEndCap,
            .extrudeWall(loopIndex: 0, edgeIndex: 0),
            .extrudeWall(loopIndex: 2, edgeIndex: 5),
            .derived(index: 7),
        ]
        for role in roles {
            try roundTrip(faceRef(role))
        }
    }

    func testFaceRefCylindricalSignatureRoundTrip() throws {
        let ref = FaceRef(
            body: sampleBodyRef(),
            creator: FeatureID(),
            role: .cylinderSide,
            signature: FaceSignature(
                kind: .cylindrical(radius: 2.5),
                normal: SIMD3(1, 0, 0),
                centroid: .zero,
                area: 9.0,
                planeOffset: -1.0
            )
        )
        try roundTrip(ref)
    }

    func testFaceRefIsHashable() {
        var set = Set<FaceRef>()
        set.insert(faceRef(.cylinderSide))
        set.insert(faceRef(.cylinderSide))          // distinct random ids -> distinct
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - FaceSignature

    func testFaceSignatureRoundTrip() throws {
        try roundTrip(planarSignature())
        try roundTrip(
            FaceSignature(
                kind: .cylindrical(radius: 3.14),
                normal: SIMD3(0, 1, 0),
                centroid: SIMD3(-1, -2, -3),
                area: 12.0,
                planeOffset: 0
            )
        )
    }

    // MARK: - ProfileRef

    func testProfileRefRoundTrip() throws {
        try roundTrip(
            ProfileRef(
                sketchID: SketchID(),
                entityIDs: [UUID(), UUID(), UUID()],
                holeEntityIDs: [[UUID()], [UUID(), UUID()]],
                seedPoint: SIMD2(1.5, -2.5)
            )
        )
    }

    func testProfileRefRoundTripEmptyAndNilSeed() throws {
        try roundTrip(
            ProfileRef(sketchID: SketchID(), entityIDs: [], holeEntityIDs: [], seedPoint: nil)
        )
    }

    // MARK: - PlaneRef (every Source case)

    func testPlaneRefRoundTripAllSources() throws {
        let sources: [PlaneRef.Source] = [
            .sketch(SketchID()),
            .construction(ConstructionPlaneID()),
            .ground,
            .explicit(.worldXY),
            .explicit(SketchPlane(origin: SIMD3(1, 2, 3), xAxis: SIMD3(0, 0, -1), yAxis: SIMD3(0, 1, 0))),
        ]
        for source in sources {
            try roundTrip(PlaneRef(source: source))
        }
    }

    // MARK: - AxisRef (every Source case)

    func testAxisRefRoundTrip() throws {
        try roundTrip(AxisRef(source: .sketchLine(SketchID(), UUID())))
        try roundTrip(AxisRef(source: .explicit(RevolveAxis(point: SIMD2(1, 2), direction: SIMD2(0, 1)))))
    }

    // MARK: - BooleanIntent (every Op case)

    func testBooleanIntentRoundTrip() throws {
        for op in [BooleanIntent.Op.newBody, .union, .subtract, .intersect] {
            try roundTrip(BooleanIntent(op: op, resolvedTargets: [sampleBodyRef(), sampleBodyRef()]))
        }
        try roundTrip(BooleanIntent(op: .newBody, resolvedTargets: []))
    }

    // MARK: - Expr

    func testExprRoundTrip() throws {
        try roundTrip(Expr(value: 12.5))
        try roundTrip(Expr(value: 3.0, formula: "a + b"))
    }

    func testExprDefaultFormulaIsNil() {
        XCTAssertNil(Expr(value: 1).formula)
    }

    /// tranche-1 stores only `.value`; a pre-formula JSON blob (no `formula`
    /// key) must still decode, defaulting `formula` to nil.
    func testExprDecodesWithoutFormulaKey() throws {
        let data = Data(#"{"value":7.5}"#.utf8)
        let decoded = try JSONDecoder().decode(Expr.self, from: data)
        XCTAssertEqual(decoded, Expr(value: 7.5))
    }

    // MARK: - PushPullMode

    func testPushPullModeRoundTrip() throws {
        try roundTrip(PushPullMode.planarAxial)
        try roundTrip(PushPullMode.cylinderRadial)
    }

    // MARK: - BoxFace

    func testBoxFaceRawValuesAndRoundTrip() throws {
        XCTAssertEqual(BoxFace.px.rawValue, 0)
        XCTAssertEqual(BoxFace.nz.rawValue, 5)
        for face in [BoxFace.px, .nx, .py, .ny, .pz, .nz] {
            try roundTrip(face)
        }
    }

    // MARK: - Conformance bridges for reused kernel types

    func testSketchPlaneHashableBridge() {
        var set = Set<SketchPlane>()
        set.insert(.worldXY)
        set.insert(.worldXY)
        set.insert(.worldYZ)
        XCTAssertEqual(set.count, 2)
    }

    func testRevolveAxisCodableRoundTrip() throws {
        try roundTrip(RevolveAxis(point: SIMD2(2, 3), direction: SIMD2(-1, 0)))
    }

    func testRevolveAxisHashableBridge() {
        var set = Set<RevolveAxis>()
        set.insert(RevolveAxis(point: SIMD2(0, 0), direction: SIMD2(1, 0)))
        set.insert(RevolveAxis(point: SIMD2(0, 0), direction: SIMD2(1, 0)))
        set.insert(RevolveAxis(point: SIMD2(0, 0), direction: SIMD2(0, 1)))
        XCTAssertEqual(set.count, 2)
    }
}
