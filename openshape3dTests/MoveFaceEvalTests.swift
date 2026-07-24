//
//  MoveFaceEvalTests.swift
//  openshape3dTests
//
//  Parametric replay of a face move (FeatureKind.moveFace). A box's +Z face is
//  sheared sideways; the persisted FaceRef + intrinsic (u,v,n) delta must
//  re-resolve and re-apply after the box is resized upstream — exactly like
//  push/pull, proving the move is associative rather than a one-shot mesh edit.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class MoveFaceEvalTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private func volume(_ body: Body) -> Double {
        MeasureKit.bodyVolume(body.render, scale: 1)
    }

    /// The planar face of `table` whose normal points most strongly +Z.
    private func plusZEntry(_ table: FaceTable) -> FaceTable.Entry? {
        table.entries
            .filter { if case .planar = $0.signature.kind { return true } else { return false } }
            .max { $0.signature.normal.z < $1.signature.normal.z }
    }

    private func boxSeedFaceRef(boxFeature: FeatureID, boxID: BodyID, depth: Double) throws -> FaceRef {
        let seed = FeatureGraph(nodes: [
            FeatureNode(id: boxFeature, name: "Box",
                        kind: .primitive(spec: .box(width: 10, depth: depth, height: 10),
                                         placement: .identity),
                        outputBodyIDs: [boxID]),
        ]).evaluate(sketches: [], planes: [], naming: SignatureNaming(),
                    nextRevision: RevisionSource().next)
        let table = try XCTUnwrap(seed.faceTables[boxID], "box has a face table")
        let entry = try XCTUnwrap(plusZEntry(table), "box has a +Z planar face")
        return FaceRef(body: BodyRef(producer: boxFeature, bodyID: boxID),
                       creator: boxFeature, role: entry.role, signature: entry.signature)
    }

    func testMoveFaceShearsBoxAndReplaysAfterUpstreamResize() throws {
        let boxFeature = FeatureID(), moveFeature = FeatureID()
        let boxID = BodyID()

        // A lateral delta in the face's own basis (u along basisX, no normal
        // component) shears the box — volume preserved.
        func graph(depth: Double, face: FaceRef) -> FeatureGraph {
            FeatureGraph(nodes: [
                FeatureNode(id: boxFeature, name: "Box",
                            kind: .primitive(spec: .box(width: 10, depth: depth, height: 10),
                                             placement: .identity),
                            outputBodyIDs: [boxID]),
                FeatureNode(id: moveFeature, name: "Move Face",
                            kind: .moveFace(face: face, delta: PointWrapper(SIMD3(3, 0, 0))),
                            outputBodyIDs: []),
            ])
        }

        let faceRef = try boxSeedFaceRef(boxFeature: boxFeature, boxID: boxID, depth: 10)

        // Shear the depth-10 box.
        let r1 = graph(depth: 10, face: faceRef).evaluate(
            sketches: [], planes: [], naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNil(r1.errors[moveFeature], "move-face must resolve and run: \(r1.errors)")
        let b1 = try XCTUnwrap(r1.bodies.first { $0.id == boxID })
        XCTAssertTrue(b1.euclidMesh().isWatertight, "a sheared box stays watertight")
        XCTAssertEqual(volume(b1), 1000, accuracy: 1000 * 0.02,
                       "a lateral (tangent) face move shears the solid — volume unchanged")

        // EDIT upstream: grow the box depth to 15. The persisted +Z FaceRef must
        // still resolve against the rebuilt box and re-apply the same shear.
        let r2 = graph(depth: 15, face: faceRef).evaluate(
            sketches: [], planes: [], naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNil(r2.errors[moveFeature],
                     "the +Z FaceRef must resolve on the bigger box (topological naming)")
        let b2 = try XCTUnwrap(r2.bodies.first { $0.id == boxID })
        XCTAssertTrue(b2.euclidMesh().isWatertight)
        XCTAssertEqual(volume(b2), 10 * 15 * 10, accuracy: 10 * 15 * 10 * 0.02,
                       "the shear replayed onto the resized box — bigger, still volume-preserving")
        XCTAssertGreaterThan(volume(b2), volume(b1),
                             "the downstream move rebuilt onto the larger upstream box")
        XCTAssertEqual(b1.id, b2.id, "the body keeps its identity across the parametric rebuild")
    }
}
