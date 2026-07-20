//
//  FeatureGraphEvalTests.swift
//  openshape3dTests
//
//  Task B1 proof: the feature-graph replay engine (FeatureGraph.evaluate).
//
//  The canonical tranche-1 pipeline is built programmatically —
//      primitive box → extrude a rect profile as a NEW body → boolean subtract
//      → push/pull a planar face outward —
//  then an upstream parameter (the extrude distance) is edited and the graph is
//  re-evaluated. The asserts prove:
//    • the whole downstream chain rebuilds to fresh, watertight geometry,
//    • the push/pull's persisted FaceRef STILL RESOLVES to the rebuilt +Z face
//      (topological naming end-to-end),
//    • the feature-owned BodyIDs are reused across the rebuild (identity), and
//    • suppressing a step makes its dependents error/skip without crashing.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class FeatureGraphEvalTests: XCTestCase {

    // MARK: Fixtures

    /// A monotonically-increasing revision source, like `DesignDocument.nextRevision`.
    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    /// A ground-plane sketch holding one axis-aligned rectangle (the extrude
    /// profile). Sketch-local (x, y) maps to world (x, 0, -y) on `.ground`.
    private func rectSketch(id: SketchID, entityID: UUID,
                            min lo: SIMD2<Double>, max hi: SIMD2<Double>) -> Sketch {
        Sketch(id: id, name: "S", plane: .ground,
               entities: [.rect(id: entityID, min: lo, max: hi)])
    }

    private func volume(_ body: Body) -> Double {
        MeasureKit.bodyVolume(body.render, scale: 1)
    }

    /// The single planar face of `table` whose normal points most strongly +Z.
    private func plusZEntry(_ table: FaceTable) -> FaceTable.Entry? {
        table.entries
            .filter { if case .planar = $0.signature.kind { return true } else { return false } }
            .max { $0.signature.normal.z < $1.signature.normal.z }
    }

    // MARK: Graph builder

    /// Node ids reused across the edit/suppress variants.
    private struct Handles {
        let boxFeature = FeatureID()
        let extrudeFeature = FeatureID()
        let booleanFeature = FeatureID()
        let pushPullFeature = FeatureID()
        let boxID = BodyID()
        let toolID = BodyID()
        let sketchID = SketchID()
        let rectEntity = UUID()
    }

    /// Build the box → extrude(new body) → subtract chain (no push/pull yet) so a
    /// FaceRef can be captured against the live geometry, then append push/pull.
    private func buildGraph(h: Handles, extrudeDistance: Double,
                            face faceRef: FaceRef) -> FeatureGraph {
        FeatureGraph(nodes: [
            FeatureNode(
                id: h.boxFeature, name: "Box",
                kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                 placement: .identity),
                outputBodyIDs: [h.boxID]),
            FeatureNode(
                id: h.extrudeFeature, name: "Extrude",
                kind: .extrude(
                    profile: ProfileRef(sketchID: h.sketchID, entityIDs: [h.rectEntity],
                                        holeEntityIDs: [], seedPoint: .zero),
                    plane: PlaneRef(source: .sketch(h.sketchID)),
                    distance: Expr(value: extrudeDistance),
                    symmetric: false,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: []),
                outputBodyIDs: [h.toolID]),
            FeatureNode(
                id: h.booleanFeature, name: "Subtract",
                kind: .boolean(
                    kind: .subtract,
                    target: BodyRef(producer: h.boxFeature, bodyID: h.boxID),
                    tools: [BodyRef(producer: h.extrudeFeature, bodyID: h.toolID)]),
                outputBodyIDs: []),
            FeatureNode(
                id: h.pushPullFeature, name: "PushPull",
                kind: .pushPull(face: faceRef, distance: Expr(value: 2), mode: .planarAxial),
                outputBodyIDs: []),
        ])
    }

    /// Everything up to (and including) the subtract, so we can read the boolean
    /// result's +Z face and mint a FaceRef the way a commit would.
    private func captureFaceRef(h: Handles, sketches: [Sketch],
                                extrudeDistance: Double) throws -> FaceRef {
        let partial = FeatureGraph(nodes: [
            FeatureNode(id: h.boxFeature, name: "Box",
                        kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                         placement: .identity),
                        outputBodyIDs: [h.boxID]),
            FeatureNode(id: h.extrudeFeature, name: "Extrude",
                        kind: .extrude(
                            profile: ProfileRef(sketchID: h.sketchID, entityIDs: [h.rectEntity],
                                                holeEntityIDs: [], seedPoint: .zero),
                            plane: PlaneRef(source: .sketch(h.sketchID)),
                            distance: Expr(value: extrudeDistance), symmetric: false,
                            boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                            extraProfiles: []),
                        outputBodyIDs: [h.toolID]),
            FeatureNode(id: h.booleanFeature, name: "Subtract",
                        kind: .boolean(
                            kind: .subtract,
                            target: BodyRef(producer: h.boxFeature, bodyID: h.boxID),
                            tools: [BodyRef(producer: h.extrudeFeature, bodyID: h.toolID)]),
                        outputBodyIDs: []),
        ])
        let rev = RevisionSource()
        let result = partial.evaluate(sketches: sketches, planes: [],
                                      naming: SignatureNaming(), nextRevision: rev.next)
        XCTAssertTrue(result.errors.isEmpty, "partial chain must build cleanly")
        let table = try XCTUnwrap(result.faceTables[h.boxID], "boolean result has a face table")
        let entry = try XCTUnwrap(plusZEntry(table), "boolean result has a +Z planar face")
        return FaceRef(
            body: BodyRef(producer: h.boxFeature, bodyID: h.boxID),
            creator: h.boxFeature, role: entry.role, signature: entry.signature)
    }

    // MARK: 1 — full pipeline builds

    func testFullPipelineBuildsOneWatertightBody() throws {
        let h = Handles()
        let sketches = [rectSketch(id: h.sketchID, entityID: h.rectEntity,
                                   min: SIMD2(-2, -2), max: SIMD2(2, 2))]
        let faceRef = try captureFaceRef(h: h, sketches: sketches, extrudeDistance: 12)
        let graph = buildGraph(h: h, extrudeDistance: 12, face: faceRef)

        let rev = RevisionSource()
        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(), nextRevision: rev.next)

        XCTAssertTrue(result.errors.isEmpty, "no node should error: \(result.errors)")
        XCTAssertEqual(result.bodies.count, 1, "subtract consumes the tool body → one body left")

        let body = try XCTUnwrap(result.bodies.first)
        XCTAssertEqual(body.id, h.boxID, "the surviving body keeps the box's BodyID")
        XCTAssertTrue(body.euclidMesh().isWatertight, "final solid must be watertight")

        // box(1000) − through-tunnel(4×4×10 = 160) + outward pull(+Z face 100 × 2 = 200).
        XCTAssertEqual(volume(body), 1000 - 160 + 200, accuracy: 1e-2)
    }

    // MARK: 2 — edit a step → downstream rebuilds, FaceRef still resolves

    func testEditingExtrudeDistanceRebuildsDownstreamAndFaceStillResolves() throws {
        let h = Handles()
        let sketches = [rectSketch(id: h.sketchID, entityID: h.rectEntity,
                                   min: SIMD2(-2, -2), max: SIMD2(2, 2))]
        // FaceRef captured against the distance-12 geometry (a through-tunnel).
        let faceRef = try captureFaceRef(h: h, sketches: sketches, extrudeDistance: 12)

        let before = buildGraph(h: h, extrudeDistance: 12, face: faceRef)
        let beforeResult = before.evaluate(sketches: sketches, planes: [],
                                           naming: SignatureNaming(), nextRevision: RevisionSource().next)
        let beforeBody = try XCTUnwrap(beforeResult.bodies.first)
        let beforeVolume = volume(beforeBody)

        // EDIT: the extrude now stops halfway (blind pocket, not a through-tunnel).
        let after = buildGraph(h: h, extrudeDistance: 6, face: faceRef)
        let afterResult = after.evaluate(sketches: sketches, planes: [],
                                         naming: SignatureNaming(), nextRevision: RevisionSource().next)

        // The push/pull did NOT error → its persisted FaceRef resolved against the
        // rebuilt boolean geometry (topological naming survived the upstream edit).
        XCTAssertNil(afterResult.errors[h.pushPullFeature],
                     "push/pull FaceRef must still resolve after the edit")
        XCTAssertTrue(afterResult.errors.isEmpty, "no node should error: \(afterResult.errors)")

        let afterBody = try XCTUnwrap(afterResult.bodies.first)
        XCTAssertTrue(afterBody.euclidMesh().isWatertight)

        // Geometry actually changed: box(1000) − pocket(4×4×6 = 96) + pull(200).
        XCTAssertEqual(volume(afterBody), 1000 - 96 + 200, accuracy: 1e-2)
        XCTAssertNotEqual(beforeVolume, volume(afterBody), accuracy: 1.0,
                          "the downstream body must rebuild to different geometry")

        // Fresh mesh revisions so the GPU cache invalidates on rebuild.
        XCTAssertGreaterThan(afterBody.meshRevision, 0)
    }

    // MARK: 3 — identity: feature-owned BodyIDs survive the edit

    func testFeatureOwnedBodyIDsAreStableAcrossRebuild() throws {
        let h = Handles()
        let sketches = [rectSketch(id: h.sketchID, entityID: h.rectEntity,
                                   min: SIMD2(-2, -2), max: SIMD2(2, 2))]
        let faceRef = try captureFaceRef(h: h, sketches: sketches, extrudeDistance: 12)

        let before = buildGraph(h: h, extrudeDistance: 12, face: faceRef)
            .evaluate(sketches: sketches, planes: [], naming: SignatureNaming(),
                      nextRevision: RevisionSource().next)
        let after = buildGraph(h: h, extrudeDistance: 6, face: faceRef)
            .evaluate(sketches: sketches, planes: [], naming: SignatureNaming(),
                      nextRevision: RevisionSource().next)

        XCTAssertEqual(Set(before.bodies.map(\.id)), Set(after.bodies.map(\.id)),
                       "BodyIDs must be reused on rebuild, never re-minted")
        XCTAssertEqual(Set(after.bodies.map(\.id)), [h.boxID])
    }

    // MARK: 4 — suppress a step: dependents error/skip, no crash

    func testSuppressingExtrudeBreaksDependentsWithoutCrashing() throws {
        let h = Handles()
        let sketches = [rectSketch(id: h.sketchID, entityID: h.rectEntity,
                                   min: SIMD2(-2, -2), max: SIMD2(2, 2))]
        let faceRef = try captureFaceRef(h: h, sketches: sketches, extrudeDistance: 12)

        var graph = buildGraph(h: h, extrudeDistance: 12, face: faceRef)
        // Suppress the extrude → its tool body is never produced.
        let idx = try XCTUnwrap(graph.index(of: h.extrudeFeature))
        graph.nodes[idx].suppressed = true

        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)

        // The boolean depends on the suppressed extrude's output → broken ref.
        switch result.errors[h.booleanFeature] {
        case .brokenRef: break
        default: XCTFail("subtract should report a broken tool ref, got \(String(describing: result.errors[h.booleanFeature]))")
        }
        // The suppressed node itself is skipped silently (not an error).
        XCTAssertNil(result.errors[h.extrudeFeature])

        // Nothing crashed and the box still exists (push/pull ran on the plain box).
        let body = try XCTUnwrap(result.bodies.first(where: { $0.id == h.boxID }))
        XCTAssertTrue(body.euclidMesh().isWatertight)
    }

    // MARK: 5 — bonus: the +Z face FOLLOWS a resized box (canonical naming proof)

    func testPlusZFaceResolvesToMovedFaceAfterBoxResize() throws {
        // Box only, +Z pull — edit the box height so the +Z face literally moves
        // from z=5 to z=7.5, and prove the FaceRef captured at z=5 still resolves.
        let boxFeature = FeatureID()
        let pushFeature = FeatureID()
        let boxID = BodyID()

        func graph(size: Double, face: FaceRef) -> FeatureGraph {
            FeatureGraph(nodes: [
                FeatureNode(id: boxFeature, name: "Box",
                            kind: .primitive(spec: .box(width: 10, depth: size, height: 10),
                                             placement: .identity),
                            outputBodyIDs: [boxID]),
                FeatureNode(id: pushFeature, name: "PushPull",
                            kind: .pushPull(face: face, distance: Expr(value: 2), mode: .planarAxial),
                            outputBodyIDs: []),
            ])
        }

        // Capture the +Z face of the depth-10 box (face at z=5).
        let seed = FeatureGraph(nodes: [
            FeatureNode(id: boxFeature, name: "Box",
                        kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                         placement: .identity),
                        outputBodyIDs: [boxID]),
        ]).evaluate(sketches: [], planes: [], naming: SignatureNaming(),
                    nextRevision: RevisionSource().next)
        let table = try XCTUnwrap(seed.faceTables[boxID])
        let entry = try XCTUnwrap(plusZEntry(table))
        XCTAssertEqual(entry.signature.centroid.z, 5, accuracy: 1e-6, "depth-10 box +Z face at z=5")
        let faceRef = FaceRef(body: BodyRef(producer: boxFeature, bodyID: boxID),
                              creator: boxFeature, role: entry.role, signature: entry.signature)

        // Grow the box depth to 15 → the +Z face is now at z=7.5.
        let grown = graph(size: 15, face: faceRef)
            .evaluate(sketches: [], planes: [], naming: SignatureNaming(),
                      nextRevision: RevisionSource().next)
        XCTAssertNil(grown.errors[pushFeature], "the +Z FaceRef must resolve on the bigger box")
        let body = try XCTUnwrap(grown.bodies.first)
        // box(10×15×10 = 1500) + outward pull(+Z face 10×10 = 100 × 2 = 200).
        XCTAssertEqual(volume(body), 1500 + 200, accuracy: 1e-3)
        XCTAssertTrue(body.euclidMesh().isWatertight)
    }

    func testInlineSubtractExtrudeThroughCoplanarFaceStaysWatertight() throws {
        // Box 10³ centered at origin (y: -5…5). An extrude-cut (INLINE subtract,
        // op == .subtract) from the ground plane up by 5 lands the tool's top cap
        // exactly COPLANAR with the box top face — the flush-cut case. evalExtrude
        // must cut with the padded overlap tool (like the live extrude-cut), so
        // the notch stays watertight with the exact volume; a bare flush prism
        // leaves a hanging wall / non-watertight seam on the coplanar face.
        let boxFeature = FeatureID(), cutFeature = FeatureID()
        let boxID = BodyID()
        let sketchID = SketchID(), rectEntity = UUID()
        let sketch = rectSketch(id: sketchID, entityID: rectEntity,
                                min: SIMD2(-1, -1), max: SIMD2(1, 1))

        let graph = FeatureGraph(nodes: [
            FeatureNode(id: boxFeature, name: "Box",
                        kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                         placement: .identity),
                        outputBodyIDs: [boxID]),
            FeatureNode(id: cutFeature, name: "Cut",
                        kind: .extrude(
                            profile: ProfileRef(sketchID: sketchID, entityIDs: [rectEntity],
                                                holeEntityIDs: [], seedPoint: .zero),
                            plane: PlaneRef(source: .sketch(sketchID)),
                            distance: Expr(value: 5), symmetric: false,
                            boolean: BooleanIntent(
                                op: .subtract,
                                resolvedTargets: [BodyRef(producer: boxFeature, bodyID: boxID)]),
                            extraProfiles: []),
                        outputBodyIDs: []),
        ])

        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertTrue(result.errors.isEmpty, "coplanar cut chain must build cleanly: \(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == boxID })
        XCTAssertTrue(body.euclidMesh().isWatertight,
                      "a coplanar through-cut must stay watertight (padded overlap tool)")
        // 1000 − (2×2 footprint × 5 height) = 980. The ~0.002 pad is negligible.
        XCTAssertEqual(volume(body), 1000 - 20, accuracy: 1e-1)
    }

    func testEvalEmitsWorldSpaceMeshWithIdentityTransform() throws {
        // An OFF-ORIGIN extrude: eval must bake the world position into the MESH
        // and leave the body transform IDENTITY. DocumentSession.performRebuild
        // relies on this — it must not carry the live body's pivot transform onto
        // the rebuilt world-space mesh (that double-offset bug shifted off-origin
        // bodies by ~2× on every parametric edit). This locks the contract.
        let extrudeFeature = FeatureID()
        let bodyID = BodyID()
        let sketchID = SketchID(), rectEntity = UUID()
        // Sketch-local (x, y) → world (x, 0, -y): a rect at x∈[48,52] sits at
        // world x≈50, far from the origin.
        let sketch = rectSketch(id: sketchID, entityID: rectEntity,
                                min: SIMD2(48, -1), max: SIMD2(52, 1))
        let graph = FeatureGraph(nodes: [
            FeatureNode(id: extrudeFeature, name: "Extrude",
                        kind: .extrude(
                            profile: ProfileRef(sketchID: sketchID, entityIDs: [rectEntity],
                                                holeEntityIDs: [], seedPoint: SIMD2(50, 0)),
                            plane: PlaneRef(source: .sketch(sketchID)),
                            distance: Expr(value: 4), symmetric: false,
                            boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                            extraProfiles: []),
                        outputBodyIDs: [bodyID]),
        ])
        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNil(result.errors[extrudeFeature], "off-origin extrude must evaluate: \(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })

        // The transform is identity — world position lives in the mesh.
        XCTAssertEqual(body.transform, .identity, "eval emits an identity transform")
        // The mesh itself is at world x≈50 (not localized around the origin).
        let xs = body.render.positions.map { $0.x }
        let meanX = xs.reduce(0, +) / Float(xs.count)
        XCTAssertEqual(meanX, 50, accuracy: 0.5, "eval bakes the world position into the mesh")
    }
}
