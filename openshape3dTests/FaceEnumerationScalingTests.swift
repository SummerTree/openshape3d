//
//  FaceEnumerationScalingTests.swift
//  openshape3dTests
//
//  `FaceTopology.enumerateFaces` was O(n²) in the triangle count, and it made
//  an ordinary modelling operation hang: revolving a circle produced a torus
//  whose `faceTable` took ~65 SECONDS. Found while giving revolve a B-rep, but
//  entirely pre-existing — the mesh path had always done this.
//
//  Two compounding causes, both fixed:
//
//  1. `planarFace`, `smoothRegion` and `cylindricalFace` each rebuilt the whole
//     edge→triangle map, and `enumerateFaces` calls them once per unclaimed
//     triangle. Sharing one map took 65 s → 41 s.
//  2. `cylindricalFace` floods the entire SMOOTH COMPONENT before deciding
//     whether a cylinder fits. A torus is one smooth component of 4,608
//     triangles that no cylinder fits, so the old code flooded all of them once
//     per seed, 2,304 times over. The verdict cannot differ between seeds in
//     one component, so one refusal now settles it for the whole component:
//     41 s → 96 ms.
//
//  The grouping these tests pin matters as much as the timing. Face
//  enumeration feeds topological naming, so if this refactor had changed WHICH
//  triangles group into a face, every stored FaceRef in every saved document
//  would resolve differently — a silent, unbounded regression. The counts below
//  are the guard against that.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class FaceEnumerationScalingTests: XCTestCase {

    private func torusMesh() throws -> Euclid.Mesh {
        let sketchID = SketchID(), circleID = UUID()
        let sketch = Sketch(id: sketchID, plane: .ground, entities: [
            .circle(id: circleID, center: SIMD2(10, 0), radius: 2),
        ])
        let profile = try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first)
        return KernelOps.revolve(profile: profile, holes: [], in: .ground,
                                 axis: RevolveAxis(point: .zero, direction: SIMD2(0, 1)),
                                 angle: 360)
    }

    /// The headline. A generous ceiling: the point is to catch a return to
    /// quadratic behaviour, not to police tens of milliseconds. It was 65,000 ms.
    func testEnumeratingATorusIsNotQuadratic() throws {
        let mesh = try torusMesh()
        let body = Body(id: BodyID(), name: "t", transform: .identity,
                        primitive: nil, euclidMesh: mesh, revision: 1)
        XCTAssertEqual(body.render.indices.count / 3, 4608, "fixture shape changed")

        let started = ProcessInfo.processInfo.systemUptime
        let table = SignatureNaming().faceTable(for: body, createdBy: FeatureID(),
                                                scheme: .revolve)
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertLessThan(elapsed, 5.0,
                          "face enumeration has gone quadratic again — this took "
                          + "~65 s before the edge map and the cylinder-fit "
                          + "verdict were shared")
        XCTAssertEqual(table.entries.count, 2304,
                       "the GROUPING must be unchanged: naming resolves stored "
                       + "FaceRefs against these entries, so a different count "
                       + "silently invalidates saved documents")
    }

    /// A box still enumerates as exactly six planar faces.
    func testABoxIsStillSixPlanarFaces() {
        let mesh = Euclid.Mesh.cube(center: Vector(0, 0, 0), size: Vector(10, 10, 10))
        let result = FaceTopology.enumerateFaces(in: EuclidBridge.renderMesh(from: mesh))
        XCTAssertEqual(result.planar.count, 6)
        XCTAssertEqual(result.cylindrical.count, 0)
    }

    /// A cylinder still enumerates as two caps plus ONE cylindrical wall — the
    /// case the memoisation could most easily have broken, since it turns on
    /// whether a cylinder fit is attempted at all.
    func testACylinderIsStillTwoCapsAndOneWall() throws {
        let brep = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 5, height: 12), placement: .identity))
        let body = try XCTUnwrap(STEPKit.body(from: brep, name: "c", revision: 1))
        let result = FaceTopology.enumerateFaces(in: body.render)
        XCTAssertEqual(result.cylindrical.count, 1, "one analytic wall")
        XCTAssertEqual(result.planar.count, 2, "two caps")
    }

    /// The public per-seed entry points still work standalone — they build
    /// their own edge map when none is shared, and 30-odd callers rely on that.
    func testThePerSeedEntryPointsStillWorkWithoutASharedMap() {
        let mesh = Euclid.Mesh.cube(center: Vector(0, 0, 0), size: Vector(4, 4, 4))
        let render = EuclidBridge.renderMesh(from: mesh)
        XCTAssertNotNil(FaceTopology.planarFace(in: render, seedTriangle: 0))
        XCTAssertNotNil(FaceTopology.smoothRegion(in: render, seedTriangle: 0))
    }
}
