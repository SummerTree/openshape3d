//
//  MoveFaceKernelTests.swift
//  openshape3dTests
//
//  KernelOps.moveFace: the general Shapr3D "Move" on a face. Translating a
//  face's vertices by a 3D delta deforms the solid — a lateral move shears a
//  box into a parallelepiped (volume preserved), a normal move thickens it
//  (volume grows by faceArea·distance, matching push/pull).
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class MoveFaceKernelTests: XCTestCase {

    /// First triangle whose (CCW) normal points along `target`.
    private func seedTriangle(in mesh: RenderMesh, normal target: SIMD3<Float>) -> Int? {
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[t * 3])]
            let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
            let n = simd_normalize(simd_cross(b - a, c - a))
            if simd_dot(n, target) > 0.999 { return t }
        }
        return nil
    }

    /// Extract the +Y (top) planar face of `mesh`.
    private func topFace(of mesh: Euclid.Mesh) throws -> PlanarFace {
        let render = EuclidBridge.renderMesh(from: mesh)
        let seed = try XCTUnwrap(seedTriangle(in: render, normal: SIMD3(0, 1, 0)),
                                 "box has a +Y triangle")
        return try XCTUnwrap(FaceTopology.planarFace(in: render, seedTriangle: seed),
                             "+Y face is planar")
    }

    private func volume(_ mesh: Euclid.Mesh) -> Double {
        MeasureKit.bodyVolume(EuclidBridge.renderMesh(from: mesh), scale: 1)
    }

    private func aabb(_ mesh: Euclid.Mesh) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        EuclidBridge.renderMesh(from: mesh).localAABB
    }

    // .box(width→X=4, depth→Z=6, height→Y=4): X∈[-2,2], Y∈[0,4], Z∈[-3,3].
    // Top (+Y) face at y=4, area = X·Z = 24.
    private func makeBox() -> Euclid.Mesh {
        Euclid.Mesh.primitive(.box(width: 4, depth: 6, height: 4))
    }

    /// Sliding the top face sideways shears the box into a parallelepiped: the
    /// top slab translates, the walls skew to follow, the base holds, and the
    /// volume is unchanged (a shear preserves volume).
    func testLateralMoveShearsBoxAndPreservesVolume() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        let before = aabb(box)
        let beforeVolume = volume(box)

        let result = KernelOps.moveFace(mesh: box, face: top, delta: SIMD3(2, 0, 0))

        XCTAssertFalse(result.polygons.isEmpty)
        XCTAssertTrue(result.isWatertight, "A sheared solid must stay watertight")
        XCTAssertEqual(volume(result), beforeVolume, accuracy: beforeVolume * 0.01,
                       "A lateral face move shears the solid — volume is unchanged")

        let after = aabb(result)
        XCTAssertEqual(after.max.x, before.max.x + 2, accuracy: 0.02,
                       "The top face slid +2 in X, so the far corner reaches x=4")
        XCTAssertEqual(after.min.x, before.min.x, accuracy: 0.02,
                       "The base did not move")
        XCTAssertEqual(after.min.y, before.min.y, accuracy: 0.02)
        XCTAssertEqual(after.max.y, before.max.y, accuracy: 0.02, "Height unchanged")
    }

    /// A user-DRAWN box (sketch rect → extrude) has different mesh topology than
    /// a primitive box — the top cap and side walls come from separate kernel
    /// steps. The lateral face move must still shear it (walls follow, volume
    /// preserved), or a drawn box would "move the face without shearing".
    func testLateralMoveShearsAnExtrudedBox() throws {
        let rect = Profile(
            loop: [SIMD2(-2, -2), SIMD2(2, -2), SIMD2(2, 2), SIMD2(-2, 2)],
            kind: .polygonal, sourceEntityIDs: [])
        // Extrude on the ground plane (+Y normal): a 4×4×4 box, y∈[0,4].
        let box = KernelOps.extrude(
            profile: rect, holes: [], in: .ground, distance: 4, symmetric: false)
        XCTAssertFalse(box.polygons.isEmpty, "extrude produced a solid")
        let top = try topFace(of: box)
        let beforeVolume = volume(box)
        let beforeMaxX = aabb(box).max.x

        let result = KernelOps.moveFace(mesh: box, face: top, delta: SIMD3(2, 0, 0))

        XCTAssertTrue(result.isWatertight, "A sheared drawn box must stay watertight")
        XCTAssertEqual(volume(result), beforeVolume, accuracy: beforeVolume * 0.02,
                       "A lateral face move shears the drawn box — volume unchanged")
        XCTAssertEqual(aabb(result).max.x, beforeMaxX + 2, accuracy: 0.1,
                       "The top face slid +2 in X (the walls followed — it sheared)")
        XCTAssertEqual(aabb(result).min.y, aabb(box).min.y, accuracy: 0.05, "base held")
    }

    /// Moving the top face along its own normal thickens the box, exactly like a
    /// positive push/pull: volume grows by faceArea · distance.
    func testNormalMoveThickensLikePushPull() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        let beforeVolume = volume(box)

        let result = KernelOps.moveFace(mesh: box, face: top, delta: SIMD3(0, 2, 0))

        XCTAssertTrue(result.isWatertight)
        XCTAssertEqual(volume(result) - beforeVolume, 24 * 2, accuracy: 24 * 2 * 0.02,
                       "Top face area (24) × 2 = +48")
        XCTAssertEqual(aabb(result).max.y, 6, accuracy: 0.02, "Top rose from y=4 to y=6")
    }

    func testZeroDeltaReturnsMeshUnchanged() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        let result = KernelOps.moveFace(mesh: box, face: top, delta: .zero)
        XCTAssertEqual(volume(result), volume(box), accuracy: 1e-9)
    }

    // MARK: - Scale face (taper)

    /// Scaling the top face DOWN about its centre tapers the box into a frustum:
    /// the top shrinks, the walls slope in, the base holds, the height is kept.
    func testUniformScaleDownTapersBoxIntoFrustum() throws {
        let box = makeBox()                 // 4(X) × 6(Z) × 4(Y), top area 24
        let top = try topFace(of: box)

        let result = KernelOps.scaleFace(mesh: box, face: top, factor: 0.5)

        XCTAssertTrue(result.isWatertight, "A tapered box (frustum) stays watertight")
        // Frustum: V = (h/3)(A_b + A_t + √(A_b·A_t)) = (4/3)(24 + 6 + 12) = 56.
        XCTAssertEqual(volume(result), 56, accuracy: 56 * 0.03,
                       "top face scaled ×0.5 → frustum volume 56")
        XCTAssertEqual(aabb(result).min.y, aabb(box).min.y, accuracy: 0.02, "base held")
        XCTAssertEqual(aabb(result).max.y, aabb(box).max.y, accuracy: 0.02, "height unchanged")
    }

    /// Scaling the top face UP flares it out past the base (top wider than base).
    func testUniformScaleUpFlaresTopBeyondBase() throws {
        let box = makeBox()
        let top = try topFace(of: box)

        let result = KernelOps.scaleFace(mesh: box, face: top, factor: 1.5)

        XCTAssertTrue(result.isWatertight)
        // Top X half-extent 2 × 1.5 = 3, so the flared top reaches x = 3 (> base 2).
        XCTAssertEqual(aabb(result).max.x, 3, accuracy: 0.1, "flared top reaches past the base")
        XCTAssertGreaterThan(volume(result), volume(box), "a flared frustum has more volume")
    }

    func testScaleFactorOneIsNoOp() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        XCTAssertEqual(volume(KernelOps.scaleFace(mesh: box, face: top, factor: 1)),
                       volume(box), accuracy: 1e-9)
    }

    // MARK: - Rotate face (tilt / twist)

    /// Tilting the top face about an IN-PLANE axis (world Z, ⟂ the +Y normal)
    /// through its centre turns the box into a slanted solid: one side of the top
    /// rises, the other drops by the same amount, the base holds. (Volume dips a
    /// little — the tilted face foreshortens, so its footprint shrinks and the
    /// walls slope inward — so we bound it rather than claim it's preserved.)
    func testTiltTopFaceAboutInPlaneAxisSlantsTheSolid() throws {
        let box = makeBox()                 // 4(X) × 6(Z) × 4(Y), volume 96
        let top = try topFace(of: box)
        let beforeVolume = volume(box)

        // +30° about world Z through the top centroid (0,4,0): the x=+2 rim rises
        // to y = 4 + 2·sin30° = 5, the x=−2 rim drops to y = 3.
        let result = KernelOps.rotateFace(
            mesh: box, face: top, angle: .pi / 6, axis: SIMD3(0, 0, 1))

        XCTAssertFalse(result.polygons.isEmpty)
        XCTAssertTrue(result.isWatertight, "A tilted solid must stay watertight")
        XCTAssertEqual(aabb(result).max.y, 5, accuracy: 0.05,
                       "the +2 rim rose to y = 4 + 2·sin30° = 5")
        XCTAssertEqual(aabb(result).min.y, 0, accuracy: 0.02, "the base held at y=0")
        XCTAssertLessThan(volume(result), beforeVolume,
                          "the tilted top foreshortens, so the solid loses a little volume")
        XCTAssertGreaterThan(volume(result), beforeVolume * 0.85,
                             "but only a little — it's a tilt, not a collapse")
    }

    /// Twisting the top face about its own normal (+Y) leaves it planar but
    /// rotates it relative to the base — the walls become ruled. It must stay a
    /// watertight solid (the mesh is triangulated so no wall quad goes non-planar).
    func testTwistTopFaceAboutNormalStaysWatertight() throws {
        let box = makeBox()
        let top = try topFace(of: box)

        let result = KernelOps.rotateFace(
            mesh: box, face: top, angle: .pi / 6, axis: SIMD3(0, 1, 0))

        XCTAssertFalse(result.polygons.isEmpty)
        XCTAssertTrue(result.isWatertight, "A twisted solid stays watertight")
        XCTAssertEqual(aabb(result).max.y, aabb(box).max.y, accuracy: 0.02,
                       "twisting in-plane keeps the top height")
    }

    /// Count rendered triangles whose stored shading normal disagrees with their
    /// geometric winding — these mis-light and read as dark "holes" in the walls.
    private func wrongNormalTriangleCount(_ mesh: Euclid.Mesh) -> Int {
        let render = EuclidBridge.renderMesh(from: mesh)
        var wrong = 0
        for t in 0..<render.triangleCount {
            let ia = Int(render.indices[t * 3]), ib = Int(render.indices[t * 3 + 1]), ic = Int(render.indices[t * 3 + 2])
            let a = render.positions[ia], b = render.positions[ib], c = render.positions[ic]
            let wind = simd_cross(b - a, c - a)
            guard simd_length(wind) > 1e-9 else { continue }
            let vn = render.normals[ia] + render.normals[ib] + render.normals[ic]
            if simd_dot(simd_normalize(wind), simd_normalize(vn)) < 0 { wrong += 1 }
        }
        return wrong
    }

    /// Regression for the reported "holes in the walls": a face rotation must
    /// leave EVERY rendered triangle's shading normal agreeing with its winding,
    /// across tilt AND twist and a wide angle range. Before the flat-normal fix,
    /// deformed wall triangles wore the tilted face normal and mis-lit as holes.
    func testRotateFaceNeverProducesWrongNormalTriangles() throws {
        for degrees in stride(from: -80.0, through: 80.0, by: 20.0) where abs(degrees) > 1 {
            let angle = degrees * Double.pi / 180
            for axis in [SIMD3<Double>(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)] {
                let box = makeBox()
                let top = try topFace(of: box)
                let result = KernelOps.rotateFace(mesh: box, face: top, angle: angle, axis: axis)
                XCTAssertTrue(result.isWatertight, "watertight at \(degrees)° about \(axis)")
                XCTAssertEqual(wrongNormalTriangleCount(result), 0,
                               "mis-lit (hole) triangles at \(degrees)° about \(axis)")
            }
        }
    }

    /// A modest twist's ruled side walls must shade SMOOTHLY, not as two flat
    /// half-triangle "facets". Smoothing welds the diagonal vertices to a single
    /// averaged normal, so a twisted box renders with fewer unique (position,
    /// normal) render vertices than the same box flat-shaded per triangle.
    func testTwistSmoothsRuledWallsInsteadOfFacetingThem() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        let twisted = KernelOps.rotateFace(mesh: box, face: top, angle: 20.0 * .pi / 180,
                                           axis: SIMD3(0, 1, 0))
        let render = EuclidBridge.renderMesh(from: twisted)
        XCTAssertTrue(twisted.isWatertight)

        // A shared diagonal vertex carries ONE smoothed normal (welds to a single
        // render vertex) rather than two flat ones. Count render vertices whose
        // stored normal disagrees with any incident triangle's flat winding-normal
        // by a hard-edge amount: on a smoothed wall there should be very few, and
        // the smoothed normals must still all point outward (no holes).
        XCTAssertEqual(wrongNormalTriangleCount(twisted), 0, "no mis-lit walls")

        // Smoothing must actually have run: at least some wall vertex normal is a
        // blend (differs from its triangle's flat normal) rather than pure-flat.
        var blended = 0
        for t in 0..<render.triangleCount {
            let ia = Int(render.indices[t * 3]), ib = Int(render.indices[t * 3 + 1]), ic = Int(render.indices[t * 3 + 2])
            let a = render.positions[ia], b = render.positions[ib], c = render.positions[ic]
            let flat = simd_normalize(simd_cross(b - a, c - a))
            for i in [ia, ib, ic] where simd_dot(simd_normalize(render.normals[i]), flat) < 0.9995 {
                blended += 1
            }
        }
        XCTAssertGreaterThan(blended, 0, "the ruled walls were smoothed, not left faceted")
    }

    /// Rotating the top face about its OWN NORMAL must produce a real screw
    /// TWIST, not two big triangular facets per wall. In a true twist every
    /// cross-section is the original rectangle rotated by its share of the angle,
    /// so the area is constant at every height → the VOLUME is exactly preserved
    /// and the height is unchanged. (The old ruled 2-triangle wall lost volume:
    /// its cross-sections were pinched quads, not rotated rectangles.)
    func testTwistAboutNormalIsAScrewThatPreservesVolume() throws {
        let box = makeBox()                 // 4(X) × 6(Z) × 4(Y), volume 96
        let top = try topFace(of: box)
        let before = volume(box)

        let twisted = KernelOps.rotateFace(mesh: box, face: top, angle: .pi / 4,
                                           axis: SIMD3(0, 1, 0))

        XCTAssertTrue(twisted.isWatertight, "a twisted prism stays watertight")
        // An ideal screw preserves volume exactly; the tessellated one loses a
        // little because the band chords cut inside the true surface, so allow a
        // small margin rather than claiming it is exact.
        XCTAssertEqual(volume(twisted), before, accuracy: before * 0.02,
                       "a screw twist keeps every cross-section congruent — volume preserved")
        XCTAssertEqual(aabb(twisted).min.y, 0, accuracy: 0.02, "base held")
        XCTAssertEqual(aabb(twisted).max.y, 4, accuracy: 0.02, "height unchanged")
        XCTAssertEqual(wrongNormalTriangleCount(twisted), 0, "no mis-lit walls")

        // The walls must actually be subdivided — a 45° twist as 2 triangles per
        // wall is exactly the "extra facets" bug. Expect many more than the box's
        // 12 triangles.
        let tris = EuclidBridge.renderMesh(from: twisted).triangleCount
        XCTAssertGreaterThan(tris, 100, "walls subdivided into a smooth screw (got \(tris))")
    }

    /// A TILT (in-plane axis) must stay a clean planar wedge — it must NOT get the
    /// twist's subdivision, or a simple slant would balloon into a curved bend.
    func testTiltStaysPlanarAndUnsubdivided() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        let tilted = KernelOps.rotateFace(mesh: box, face: top, angle: .pi / 6,
                                          axis: SIMD3(0, 0, 1))
        let tris = EuclidBridge.renderMesh(from: tilted).triangleCount
        XCTAssertLessThan(tris, 40, "a tilt stays a simple wedge (got \(tris) triangles)")
    }

    /// The Rotate tool stays live, so a user twists the SAME face repeatedly.
    /// Subdivision must not compound: a triangle lying wholly on the face rotates
    /// rigidly and is never re-subdivided, so the count settles instead of
    /// exploding (it used to square each pass — 256 → 65 536 triangles).
    func testRepeatedTwistsDoNotExplodeTriangleCount() throws {
        var mesh = makeBox()
        var counts: [Int] = []
        for _ in 0..<4 {
            let top = try topFace(of: mesh)
            mesh = KernelOps.rotateFace(mesh: mesh, face: top, angle: .pi / 6,
                                        axis: SIMD3(0, 1, 0))
            XCTAssertTrue(mesh.isWatertight, "each successive twist stays watertight")
            counts.append(EuclidBridge.renderMesh(from: mesh).triangleCount)
        }
        // The subdivision budget trades resolution for a bound: once the mesh is
        // dense the grid coarsens (eventually to n = 1), so the count PLATEAUS
        // instead of compounding. Without it this reached 37 708 and climbing.
        XCTAssertLessThan(counts.last!, 20_000,
                          "repeated twists stay bounded, got \(counts)")
        XCTAssertEqual(Double(counts[3]), Double(counts[2]), accuracy: Double(counts[2]) * 0.1,
                       "growth has plateaued rather than compounding, got \(counts)")
    }

    /// The reported "the twist is not smooth": the subdivision rows were being
    /// DRAWN as feature edges, banding the wall. The overlay draws an edge where
    /// two triangles meet above ~20°, so a smooth screw must keep essentially all
    /// its interior seams below that — only the box's own 12 corners (subdivided
    /// into segments, now helical) may show.
    ///
    /// This is what caught the fan tessellation: converging strips on one corner
    /// folded against each other at up to 140°, so 69% of all edges were drawn.
    func testTwistDrawsOnlyTheBoxesRealEdgesNotEveryBand() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        let twisted = KernelOps.rotateFace(mesh: box, face: top, angle: .pi / 2,
                                           axis: SIMD3(0, 1, 0))
        let render = EuclidBridge.renderMesh(from: twisted)
        XCTAssertTrue(twisted.isWatertight)

        var edgeNormals = [String: [SIMD3<Float>]]()
        func key(_ p: SIMD3<Float>) -> String {
            let inv: Float = 1e5
            return "\(Int32((p.x * inv).rounded())),\(Int32((p.y * inv).rounded())),\(Int32((p.z * inv).rounded()))"
        }
        for t in 0..<render.triangleCount {
            let pts = (0..<3).map { render.positions[Int(render.indices[t * 3 + $0])] }
            let cr = simd_cross(pts[1] - pts[0], pts[2] - pts[0])
            guard simd_length(cr) > 1e-12 else { continue }
            let nrm = simd_normalize(cr)
            for e in 0..<3 {
                let k1 = key(pts[e]), k2 = key(pts[(e + 1) % 3])
                edgeNormals[k1 < k2 ? k1 + "|" + k2 : k2 + "|" + k1, default: []].append(nrm)
            }
        }
        var unpaired = 0, drawn = 0
        for (_, ns) in edgeNormals {
            if ns.count == 1 { unpaired += 1; continue }
            guard ns.count == 2 else { continue }
            let d = Double(simd_dot(ns[0], ns[1]))
            if acos(min(max(d, -1), 1)) * 180 / .pi > 20 { drawn += 1 }
        }
        XCTAssertEqual(unpaired, 0, "no unpaired edges — a seam gap draws as a boundary line")
        // The box's 12 edges, each subdivided into at most n segments, is the
        // legitimate budget; anything beyond that is banding.
        let n = 12
        XCTAssertLessThanOrEqual(drawn, 12 * n,
                                 "only the box's own corners may draw, got \(drawn) of \(edgeNormals.count)")
        XCTAssertLessThan(Double(drawn) / Double(edgeNormals.count), 0.1,
                          "the vast majority of seams must be smooth, got \(drawn)/\(edgeNormals.count)")
    }

    func testRotateZeroAngleIsNoOp() throws {
        let box = makeBox()
        let top = try topFace(of: box)
        XCTAssertEqual(volume(KernelOps.rotateFace(mesh: box, face: top, angle: 0,
                                                   axis: SIMD3(0, 0, 1))),
                       volume(box), accuracy: 1e-9)
    }
}
