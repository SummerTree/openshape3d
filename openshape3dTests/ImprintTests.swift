//
//  ImprintTests.swift
//  openshape3dTests
//
//  Imprint Edge (spec §4.17): a sketch's curves split a body's faces, the
//  split region picks as a face of its own and push/pulls as a boss or a
//  pocket, and the split survives a save (the mesh blob's region trailer).
//

import XCTest
import simd
@testable import openshape3d

final class ImprintTests: XCTestCase {

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private func body(_ spec: PrimitiveSpec) throws -> Body {
        let brep = try XCTUnwrap(OCCTKernel.primitiveShape(spec, placement: .identity))
        return try XCTUnwrap(STEPKit.body(from: brep, name: "b", revision: 1))
    }

    /// A sketch on the plane y = `top` (the ground plane's orientation),
    /// holding `entities`.
    private func topSketch(_ top: Double, _ entities: [SketchEntity], id: SketchID = SketchID()) -> Sketch {
        Sketch(id: id, plane: .offsetGround(y: top), entities: entities)
    }

    private func imprint(_ body: Body, _ sketch: Sketch) throws -> Body {
        let local = ImprintKit.bodyLocal(ImprintKit.segments(of: sketch), plane: sketch.plane,
                                         transform: body.transform)
        let (handle, _) = try OCCTKernel.imprintResultWithAncestry(
            try XCTUnwrap(body.brep), segments: local.segments, plane: local.plane).get()
        var out = body
        XCTAssertTrue(out.adoptBRep(handle, keepingFaceRegions: true))
        return out
    }

    /// The +Y planar face containing the triangle whose centroid is nearest
    /// `point` (x, z) among the top triangles.
    private func topFace(of body: Body, near point: SIMD2<Float>) throws -> PlanarFace {
        let mesh = body.render
        var best: (d: Float, t: Int)?
        let top = mesh.localAABB.max.y
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[3 * t])]
            let b = mesh.positions[Int(mesh.indices[3 * t + 1])]
            let c = mesh.positions[Int(mesh.indices[3 * t + 2])]
            let n = simd_normalize(simd_cross(b - a, c - a))
            guard n.y > 0.999, abs(a.y - top) < 1e-4 else { continue }
            let centroid = (a + b + c) / 3
            let d = simd_distance(SIMD2(centroid.x, centroid.z), point)
            if d < (best?.d ?? .infinity) { best = (d, t) }
        }
        let seed = try XCTUnwrap(best?.t)
        return try XCTUnwrap(FaceTopology.planarFace(in: mesh, seedTriangle: seed))
    }

    private func area(_ face: PlanarFace, in mesh: RenderMesh) -> Double {
        face.triangles.reduce(0) { sum, t in
            let a = mesh.positions[Int(mesh.indices[3 * t])]
            let b = mesh.positions[Int(mesh.indices[3 * t + 1])]
            let c = mesh.positions[Int(mesh.indices[3 * t + 2])]
            return sum + Double(simd_length(simd_cross(b - a, c - a))) / 2
        }
    }

    // MARK: - Curves

    func testSketchCurvesBecomeExactSegments() {
        let construction = UUID()
        var sketch = topSketch(0, [
            .circle(id: UUID(), center: SIMD2(1, 2), radius: 3),
            .line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(5, 0)),
            .arc(id: UUID(), center: .zero, radius: 2, startAngle: 0, endAngle: .pi / 2),
            .rect(id: UUID(), min: SIMD2(-1, -1), max: SIMD2(1, 1)),
            .spline(id: UUID(), points: [SIMD2(0, 0), SIMD2(1, 1), SIMD2(2, 0)], closed: false),
            .line(id: construction, a: SIMD2(9, 9), b: SIMD2(8, 8)),
        ])
        sketch.constructionEntityIDs = [construction]
        let segments = ImprintKit.segments(of: sketch)
        XCTAssertEqual(segments.count, 2 + 1 + 1 + 4 + 1, "construction geometry is not imprinted")
        XCTAssertEqual(segments.filter { $0.mid != nil }.count, 3, "circle halves and the arc stay arcs")
        XCTAssertEqual(segments.filter { $0.controlPoints != nil }.count, 1, "the spline stays one curve")
        let arc = segments[3]
        XCTAssertEqual(arc.end.x, 0, accuracy: 1e-12)
        XCTAssertEqual(arc.end.y, 2, accuracy: 1e-12)
    }

    func testCurvesFollowTheBodyIntoItsFrame() {
        var transform = Transform3D()
        transform.translation = SIMD3(10, 0, 0)
        transform.rotation = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 1, 0))
        transform.scale = 2
        let plane = SketchPlane.offsetGround(y: 4)
        let segments = [Profile.Segment(start: SIMD2(10, 0), end: SIMD2(14, 0))]
        let local = ImprintKit.bodyLocal(segments, plane: plane, transform: transform)
        // A world point on the curve maps to the body-local point the matrix
        // carries back onto it.
        let world = plane.toWorld(SIMD2(14, 0))
        let localPoint = local.plane.toWorld(local.segments[0].end)
        let back = transform.matrix * SIMD4(localPoint, 1)
        XCTAssertEqual(simd_distance(SIMD3(back.x, back.y, back.z), world), 0, accuracy: 1e-9)
    }

    // MARK: - Kernel

    func testACircleSplitsTheTopFace() throws {
        let box = try body(.box(width: 10, depth: 10, height: 10))
        let top = Double(box.render.localAABB.max.y)
        let before = OCCTKernel.faceTypeCounts(try XCTUnwrap(box.brep)).planar
        let stamped = try imprint(box, topSketch(top, [.circle(id: UUID(), center: .zero, radius: 2)]))
        XCTAssertEqual(OCCTKernel.faceTypeCounts(try XCTUnwrap(stamped.brep)).planar, before + 1)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(stamped.brep)), 1000, accuracy: 1e-6)
        XCTAssertNotNil(stamped.render.validFaceRegions)

        // The disc picks as its own face; the rest of the top as a ring.
        let disc = try topFace(of: stamped, near: .zero)
        XCTAssertEqual(area(disc, in: stamped.render), .pi * 4, accuracy: 0.1)
        let ring = try topFace(of: stamped, near: SIMD2(4.5, 4.5))
        XCTAssertEqual(area(ring, in: stamped.render), 100 - .pi * 4, accuracy: 0.1)
        XCTAssertEqual(ring.holes.count, 1)

        // The imprinted circle draws as an edge.
        let length = { (body: Body) -> Double in
            let s = body.edges.segments
            return stride(from: 0, to: s.count, by: 2).reduce(0) { $0 + Double(simd_distance(s[$1], s[$1 + 1])) }
        }
        XCTAssertEqual(length(stamped) - length(box), 2 * .pi * 2, accuracy: 0.1)
    }

    func testAnImprintedRegionPullsAndPushes() throws {
        let box = try body(.box(width: 10, depth: 10, height: 10))
        let top = Double(box.render.localAABB.max.y)
        let stamped = try imprint(box, topSketch(top, [.circle(id: UUID(), center: .zero, radius: 2)]))
        let disc = try topFace(of: stamped, near: .zero)
        let brep = try XCTUnwrap(stamped.brep)

        let tool = try OCCTKernel.pushPullResult(brep, face: disc, render: stamped.render, distance: 3).get()
        XCTAssertEqual(OCCTKernel.volume(tool), 1000 + .pi * 4 * 3, accuracy: 1e-3, "a boss")
        XCTAssertGreaterThanOrEqual(OCCTKernel.faceTypeCounts(tool).cylindrical, 1, "with a round wall")

        let pocket = try OCCTKernel.pushPullResult(brep, face: disc, render: stamped.render, distance: -3).get()
        XCTAssertEqual(OCCTKernel.volume(pocket), 1000 - .pi * 4 * 3, accuracy: 1e-3,
                       "a pocket, not the whole top sliced off")
    }

    /// Pushing one face of a stepped part in moves that face only — the
    /// taller step beside it stays whole.
    func testPushingInLeavesANeighbouringStepAlone() throws {
        let base = try XCTUnwrap(OCCTKernel.primitiveShape(.box(width: 20, depth: 10, height: 10),
                                                          placement: .identity))
        var up = Transform3D()
        up.translation = SIMD3(-5, 10, 0)
        let step = try XCTUnwrap(OCCTKernel.primitiveShape(.box(width: 10, depth: 10, height: 10),
                                                          placement: up))
        let part = try XCTUnwrap(OCCTKernel.boolean(base, step, op: 0))
        let body = try XCTUnwrap(STEPKit.body(from: part, name: "p", revision: 1))
        XCTAssertEqual(OCCTKernel.volume(part), 3000, accuracy: 1e-6)

        // The lower top face: +Y, on the right half.
        let mesh = body.render
        var seed: Int?
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[3 * t])]
            let b = mesh.positions[Int(mesh.indices[3 * t + 1])]
            let c = mesh.positions[Int(mesh.indices[3 * t + 2])]
            let n = simd_normalize(simd_cross(b - a, c - a))
            if n.y > 0.999, (a.x + b.x + c.x) / 3 > 1, a.y < mesh.localAABB.max.y - 1 { seed = t; break }
        }
        let face = try XCTUnwrap(FaceTopology.planarFace(in: mesh, seedTriangle: try XCTUnwrap(seed)))
        let pushed = try OCCTKernel.pushPullResult(part, face: face, render: mesh, distance: -2).get()
        XCTAssertEqual(OCCTKernel.volume(pushed), 3000 - 10 * 10 * 2, accuracy: 1e-6)
    }

    func testCurvesOffTheBodyAreRefused() throws {
        let box = try body(.box(width: 10, depth: 10, height: 10))
        let sketch = topSketch(50, [.circle(id: UUID(), center: .zero, radius: 2)])
        let local = ImprintKit.bodyLocal(ImprintKit.segments(of: sketch), plane: sketch.plane,
                                         transform: box.transform)
        guard case .failure(.noTargetMatched) = OCCTKernel.imprintResultWithAncestry(
            try XCTUnwrap(box.brep), segments: local.segments, plane: local.plane) else {
            return XCTFail("a sketch above the body divides nothing")
        }
    }

    // MARK: - Feature graph

    func testImprintThenPushPullReplays() throws {
        let boxFeature = FeatureID(), imprintFeature = FeatureID(), pullFeature = FeatureID()
        let boxID = BodyID(), sketchID = SketchID()
        let boxNode = FeatureNode(id: boxFeature, name: "Box",
                                  kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                                   placement: .identity),
                                  outputBodyIDs: [boxID])
        let boxRef = BodyRef(producer: boxFeature, bodyID: boxID)
        let imprintNode = FeatureNode(id: imprintFeature, name: "Imprint",
                                      kind: .imprint(body: boxRef, sketches: [sketchID]),
                                      outputBodyIDs: [])
        let plain = FeatureGraph(nodes: [boxNode])
            .evaluate(sketches: [], planes: [], naming: SignatureNaming(), nextRevision: RevisionSource().next)
        let top = Double(try XCTUnwrap(plain.bodies.first).render.localAABB.max.y)
        func sketches(radius: Double) -> [Sketch] {
            [topSketch(top, [.circle(id: UUID(), center: SIMD2(1, 0), radius: radius)], id: sketchID)]
        }

        let stamped = FeatureGraph(nodes: [boxNode, imprintNode])
            .evaluate(sketches: sketches(radius: 2), planes: [], naming: SignatureNaming(),
                      nextRevision: RevisionSource().next)
        XCTAssertTrue(stamped.errors.isEmpty, "\(stamped.errors)")
        XCTAssertTrue(imprintNode.referencedSketchIDs.contains(sketchID))
        let table = try XCTUnwrap(stamped.faceTables[boxID])
        let disc = try XCTUnwrap(table.entries.first {
            $0.signature.normal.y > 0.99 && abs($0.signature.area - .pi * 4) < 0.1
        }, "the disc is a face of its own")
        let ref = FaceRef(body: boxRef, creator: imprintFeature, role: disc.role, signature: disc.signature)

        let graph = FeatureGraph(nodes: [
            boxNode, imprintNode,
            FeatureNode(id: pullFeature, name: "Pull",
                        kind: .pushPull(face: ref, distance: Expr(value: 4), mode: .planarAxial),
                        outputBodyIDs: []),
        ])
        let pulled = graph.evaluate(sketches: sketches(radius: 2), planes: [], naming: SignatureNaming(),
                                    nextRevision: RevisionSource().next)
        XCTAssertTrue(pulled.errors.isEmpty, "\(pulled.errors)")
        let body = try XCTUnwrap(pulled.bodies.first)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(body.brep)), 1000 + .pi * 4 * 4, accuracy: 1e-3)
    }

    func testImprintNeedsTheSketchOnTheBody() {
        let boxFeature = FeatureID(), imprintFeature = FeatureID()
        let boxID = BodyID(), sketchID = SketchID()
        let result = FeatureGraph(nodes: [
            FeatureNode(id: boxFeature, name: "Box",
                        kind: .primitive(spec: .box(width: 10, depth: 10, height: 10), placement: .identity),
                        outputBodyIDs: [boxID]),
            FeatureNode(id: imprintFeature, name: "Imprint",
                        kind: .imprint(body: BodyRef(producer: boxFeature, bodyID: boxID), sketches: [sketchID]),
                        outputBodyIDs: []),
        ]).evaluate(sketches: [topSketch(40, [.circle(id: UUID(), center: .zero, radius: 2)], id: sketchID)],
                    planes: [], naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNotNil(result.errors[imprintFeature])
        XCTAssertEqual(result.bodies.count, 1, "the body survives a failed imprint")
    }

    // MARK: - Persistence

    func testFaceRegionsSurviveTheMeshBlob() throws {
        let box = try body(.box(width: 10, depth: 10, height: 10))
        let stamped = try imprint(box, topSketch(Double(box.render.localAABB.max.y),
                                                 [.circle(id: UUID(), center: .zero, radius: 2)]))
        let decoded = try MeshBlob.decode(MeshBlob.encode(stamped.render))
        XCTAssertEqual(decoded, stamped.render)
        XCTAssertNotNil(decoded.faceRegions)
        // A plain mesh stays a plain blob.
        let plain = try MeshBlob.decode(MeshBlob.encode(box.render))
        XCTAssertNil(plain.faceRegions)
        XCTAssertEqual(MeshBlob.encode(box.render).count, 16 + box.render.positions.count * 24
                       + box.render.indices.count * 4)
    }
}
