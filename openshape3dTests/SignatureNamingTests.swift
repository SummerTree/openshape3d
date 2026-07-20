//
//  SignatureNamingTests.swift
//  openshape3dTests
//
//  Task A2 — geometric topological naming. Proves that a persisted `FaceRef`
//  re-resolves to the correct face after the owning feature is rebuilt with
//  different parameters (the whole point of topological naming), and that a face
//  which no longer exists resolves to nil rather than snapping to a wrong face.
//
//  Scoring weights under test (SignatureNaming):
//    wNormal = 0.5, wCentroid = 0.3, wArea = 0.2  (base score, sums to 1.0)
//    roleBoost = 0.2, resolveThreshold = 0.6
//  A face whose normal is orthogonal to the target caps at 0.5 < 0.6, so it can
//  never resolve; an aligned face ranges [0.5, 1.0].
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class SignatureNamingTests: XCTestCase {

    private let naming = SignatureNaming()

    private func boxBody(_ size: Double, revision: UInt64 = 0) -> Body {
        Body(
            name: "Box",
            euclidMesh: .primitive(.box(width: size, depth: size, height: size)),
            revision: revision
        )
    }

    private func boxScheme(_ size: Double) -> FaceScheme {
        .primitive(.box(width: size, depth: size, height: size))
    }

    private func signature(_ table: FaceTable, role: FaceRole) -> FaceSignature? {
        table.entries.first { $0.role == role }?.signature
    }

    private func faceRef(_ role: FaceRole, _ sig: FaceSignature, on body: Body) -> FaceRef {
        let creator = FeatureID()
        return FaceRef(
            body: BodyRef(producer: creator, bodyID: body.id),
            creator: creator, role: role, signature: sig
        )
    }

    // MARK: - faceTable labels all six box faces

    func testFaceTableLabelsSixBoxFaces() {
        let box = boxBody(10)
        let table = naming.faceTable(for: box, createdBy: FeatureID(), scheme: boxScheme(10))

        XCTAssertEqual(table.entries.count, 6, "A box has six faces")
        let roles = Set(table.entries.map(\.role))
        XCTAssertEqual(
            roles,
            Set([.boxFace(.px), .boxFace(.nx), .boxFace(.py),
                 .boxFace(.ny), .boxFace(.pz), .boxFace(.nz)]),
            "Each of the six ±axis faces is labelled exactly once"
        )
        // Every entry is planar with area = 10×10 = 100.
        for entry in table.entries {
            XCTAssertEqual(entry.signature.kind, .planar)
            XCTAssertEqual(entry.signature.area, 100, accuracy: 0.1)
        }
    }

    // MARK: - resolve returns the +Z face (highest centroid.z)

    func testResolvePlusZReturnsTopmostZFace() {
        let box = boxBody(10)
        let table = naming.faceTable(for: box, createdBy: FeatureID(), scheme: boxScheme(10))
        let pz = try! XCTUnwrap(signature(table, role: .boxFace(.pz)))

        // The recorded +Z signature really is the +Z face at z = depth/2 = 5.
        XCTAssertEqual(pz.normal.z, 1, accuracy: 1e-4)
        XCTAssertEqual(pz.centroid.z, 5, accuracy: 1e-4)

        let ref = faceRef(.boxFace(.pz), pz, on: box)
        let resolved = try! XCTUnwrap(naming.resolve(ref, in: box, table: table))
        let planar = try! XCTUnwrap(resolved.planar)

        XCTAssertEqual(planar.normal.z, 1, accuracy: 1e-3, "resolves to a +Z-facing face")
        XCTAssertEqual(planar.origin.z, 5, accuracy: 1e-3, "the +Z face is the one at max z")
        // Exact-match resolve → maximum confidence.
        XCTAssertEqual(resolved.confidence, 1, accuracy: 1e-6)
    }

    // MARK: - CRITICAL PROOF: the +Z FaceRef survives a rebuild to a larger box

    func testPlusZRefSurvivesRebuildToLargerBox() {
        // Capture the +Z FaceRef from a size-10 box.
        let small = boxBody(10)
        let smallTable = naming.faceTable(for: small, createdBy: FeatureID(), scheme: boxScheme(10))
        let pz = try! XCTUnwrap(signature(smallTable, role: .boxFace(.pz)))
        let ref = faceRef(.boxFace(.pz), pz, on: small)

        // Rebuild the box LARGER (size 20). Same FaceRef, new body + new table.
        let large = boxBody(20, revision: 1)
        let largeTable = naming.faceTable(for: large, createdBy: FeatureID(), scheme: boxScheme(20))

        let resolved = try! XCTUnwrap(
            naming.resolve(ref, in: large, table: largeTable),
            "the +Z face must still resolve after the rebuild"
        )
        let planar = try! XCTUnwrap(resolved.planar)

        // It is STILL the +Z face — now higher and larger — never a side face.
        XCTAssertGreaterThan(planar.normal.z, 0.99,
                             "resolved to +Z, not a side face")
        XCTAssertEqual(planar.origin.z, 10, accuracy: 1e-2,
                       "the now-larger +Z face sits at z = 20/2 = 10")
        XCTAssertGreaterThanOrEqual(resolved.confidence, 0.6)

        // Sanity: the same ref against the small box still lands at z = 5.
        let control = try! XCTUnwrap(naming.resolve(ref, in: small, table: smallTable))
        XCTAssertEqual(try! XCTUnwrap(control.planar).origin.z, 5, accuracy: 1e-3)
    }

    // MARK: - A face that no longer exists resolves to nil

    func testRemovedFaceResolvesToNil() {
        // A +Z FaceRef from a box.
        let box = boxBody(10)
        let table = naming.faceTable(for: box, createdBy: FeatureID(), scheme: boxScheme(10))
        let pz = try! XCTUnwrap(signature(table, role: .boxFace(.pz)))
        let ref = faceRef(.boxFace(.pz), pz, on: box)

        // Resolve it in a body that has NO +Z-facing face: a Y-axis cylinder
        // (its faces point ±Y or are the curved side, whose signature normal is
        // the Y axis). Every candidate is orthogonal to +Z → capped below the
        // 0.6 threshold → resolve yields nil instead of snapping to a side.
        let cylinder = Body(
            name: "Cyl",
            euclidMesh: .primitive(.cylinder(radius: 6, height: 12)),
            revision: 2
        )
        XCTAssertNil(naming.resolve(ref, in: cylinder, table: nil),
                     "the referenced +Z face does not exist here → nil")
    }

    // MARK: - Bonus: resolve is robust to a hole punched in the face

    func testResolveSurvivesHolePunchedInFace() {
        // Slab 8×8×2 (y ∈ [0, 2]); capture its top (+Y) face.
        let slab = Body(
            name: "Slab",
            euclidMesh: .primitive(.box(width: 8, depth: 8, height: 2)),
            revision: 0
        )
        let table = naming.faceTable(
            for: slab, createdBy: FeatureID(), scheme: .primitive(.box(width: 8, depth: 8, height: 2))
        )
        let py = try! XCTUnwrap(signature(table, role: .boxFace(.py)))
        let ref = faceRef(.boxFace(.py), py, on: slab)

        // Punch a through-hole; the top face survives with a bore hole.
        let punch = Euclid.Mesh.cylinder(radius: 1.5, height: 6, slices: 48)
            .translated(by: Vector(0, 1, 0))
        let cut = Euclid.Mesh.primitive(.box(width: 8, depth: 8, height: 2))
            .subtracting(punch)
            .makeWatertight()
        let holed = Body(name: "Holed", euclidMesh: cut, revision: 1)

        let resolved = try! XCTUnwrap(naming.resolve(ref, in: holed, table: nil))
        let planar = try! XCTUnwrap(resolved.planar)
        XCTAssertGreaterThan(planar.normal.y, 0.99, "still the top face despite the hole")
        XCTAssertEqual(planar.holes.count, 1, "the resolved face carries the bore hole")
    }
}
