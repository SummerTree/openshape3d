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

    /// Mean vertex x of a body's render mesh — the geometric center for the
    /// symmetric solids these tests build (box/ring), enough to check a reflection.
    private func centroidX(_ body: Body) -> Double {
        let xs = body.render.positions.map { Double($0.x) }
        return xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
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

    // MARK: 4b — reordering a node before the one it depends on surfaces a broken
    // ref (History drag-to-reorder error surfacing), no crash.

    func testMovingBooleanBeforeExtrudeBreaksItsToolRef() throws {
        let h = Handles()
        let sketches = [rectSketch(id: h.sketchID, entityID: h.rectEntity,
                                   min: SIMD2(-2, -2), max: SIMD2(2, 2))]
        let faceRef = try captureFaceRef(h: h, sketches: sketches, extrudeDistance: 12)

        var graph = buildGraph(h: h, extrudeDistance: 12, face: faceRef)
        // Move the subtract (consumes the extrude's tool body) to BEFORE the
        // extrude — the same reorder a History drag would produce.
        let boolIdx = try XCTUnwrap(graph.index(of: h.booleanFeature))
        let node = graph.nodes.remove(at: boolIdx)
        let extrudeIdx = try XCTUnwrap(graph.index(of: h.extrudeFeature))
        graph.nodes.insert(node, at: extrudeIdx) // now the boolean evaluates first

        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)

        // The subtract can't resolve its tool (extrude not yet built) → broken ref.
        switch result.errors[h.booleanFeature] {
        case .brokenRef: break
        default: XCTFail("out-of-order subtract should report a broken ref, got \(String(describing: result.errors[h.booleanFeature]))")
        }
        // No crash; the box still exists.
        XCTAssertTrue(result.bodies.contains { $0.id == h.boxID })
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

    // MARK: Tranche 2 — revolve / sweep / loft / mirror

    /// (1) A 360° revolve of an OFF-AXIS rectangle → a watertight rectangular ring.
    func testRevolveOffAxisRectMakesWatertightRing() throws {
        let revolveFeature = FeatureID()
        let bodyID = BodyID()
        let sketchID = SketchID(), rectEntity = UUID(), axisEntity = UUID()
        // Rect on the +x side of the axis (x∈[2,4], y∈[-1,1], area 4); the axis is
        // a vertical sketch line at x=0. resolveAxis(.sketchLine) is exercised here.
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .rect(id: rectEntity, min: SIMD2(2, -1), max: SIMD2(4, 1)),
            .line(id: axisEntity, a: SIMD2(0, -5), b: SIMD2(0, 5)),
        ])
        let graph = FeatureGraph(nodes: [
            FeatureNode(id: revolveFeature, name: "Revolve",
                kind: .revolve(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [rectEntity],
                                        holeEntityIDs: [], seedPoint: SIMD2(3, 0)),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    axis: AxisRef(source: .sketchLine(sketchID, axisEntity)),
                    angle: Expr(value: 360),
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [bodyID]),
        ])
        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNil(result.errors[revolveFeature], "revolve must evaluate: \(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        XCTAssertTrue(body.euclidMesh().isWatertight, "revolved ring must be watertight")
        XCTAssertEqual(body.transform, .identity, "eval emits an identity transform")
        // Pappus: V = 2π·R_centroid·A = 2π·3·4 = 24π (48-slice lathe → ~0.3% low).
        XCTAssertEqual(volume(body), 24 * .pi, accuracy: 24 * .pi * 0.02)
    }

    /// A profile that CROSSES the axis → empty kernel mesh → `.emptyGeometry`, no crash.
    func testRevolveAcrossAxisReportsEmptyGeometry() throws {
        let revolveFeature = FeatureID()
        let bodyID = BodyID()
        let sketchID = SketchID(), rectEntity = UUID()
        // Rect straddles x=0 (x∈[-2,2]) — KernelOps.revolve rejects it.
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .rect(id: rectEntity, min: SIMD2(-2, -1), max: SIMD2(2, 1)),
        ])
        let graph = FeatureGraph(nodes: [
            FeatureNode(id: revolveFeature, name: "Revolve",
                kind: .revolve(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [rectEntity],
                                        holeEntityIDs: [], seedPoint: .zero),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    axis: AxisRef(source: .explicit(RevolveAxis(point: .zero, direction: SIMD2(0, 1)))),
                    angle: Expr(value: 360),
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [bodyID]),
        ])
        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertEqual(result.errors[revolveFeature], .emptyGeometry)
        XCTAssertTrue(result.bodies.isEmpty, "no body is emitted for an axis-crossing revolve")
    }

    /// (2) A sweep of a rect along a straight 3-point spine → a watertight prism.
    func testSweepRectAlongStraightSpineMakesWatertightPrism() throws {
        let sweepFeature = FeatureID()
        let bodyID = BodyID()
        let sketchID = SketchID(), rectEntity = UUID()
        // 2×2 rect on the world XY plane; straight 3-point spine climbing +z by 10.
        let sketch = Sketch(id: sketchID, name: "S", plane: .worldXY,
                            entities: [.rect(id: rectEntity, min: SIMD2(-1, -1), max: SIMD2(1, 1))])
        let graph = FeatureGraph(nodes: [
            FeatureNode(id: sweepFeature, name: "Sweep",
                kind: .sweep(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [rectEntity],
                                        holeEntityIDs: [], seedPoint: .zero),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    spine: [PointWrapper(SIMD3(0, 0, 0)), PointWrapper(SIMD3(0, 0, 5)),
                            PointWrapper(SIMD3(0, 0, 10))],
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    helix: nil),
                outputBodyIDs: [bodyID]),
        ])
        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNil(result.errors[sweepFeature], "sweep must evaluate: \(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        XCTAssertTrue(body.euclidMesh().isWatertight, "swept prism must be watertight")
        XCTAssertEqual(body.transform, .identity)
        XCTAssertEqual(volume(body), 2 * 2 * 10, accuracy: 1e-2)
    }

    /// (3) A loft between two parallel rect sections → watertight; 1 section errors.
    func testLoftTwoParallelRectsIsWatertightAndNeedsTwoSections() throws {
        let loftFeature = FeatureID(), oneLoftFeature = FeatureID()
        let bodyID = BodyID(), oneBodyID = BodyID()
        let sketchAID = SketchID(), sketchBID = SketchID()
        let rectA = UUID(), rectB = UUID()
        // Two 4×4 squares on parallel planes 10 apart → a 4×4×10 box (V = 160).
        let sketchA = Sketch(id: sketchAID, name: "A", plane: .worldXY,
                             entities: [.rect(id: rectA, min: SIMD2(-2, -2), max: SIMD2(2, 2))])
        let planeB = SketchPlane(origin: SIMD3(0, 0, 10), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        let sketchB = Sketch(id: sketchBID, name: "B", plane: planeB,
                             entities: [.rect(id: rectB, min: SIMD2(-2, -2), max: SIMD2(2, 2))])

        func sectionRef(_ sid: SketchID, _ e: UUID) -> ProfileRef {
            ProfileRef(sketchID: sid, entityIDs: [e], holeEntityIDs: [], seedPoint: .zero)
        }

        let graph = FeatureGraph(nodes: [
            FeatureNode(id: loftFeature, name: "Loft",
                kind: .loft(sections: [sectionRef(sketchAID, rectA), sectionRef(sketchBID, rectB)],
                            boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [bodyID]),
        ])
        let result = graph.evaluate(sketches: [sketchA, sketchB], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNil(result.errors[loftFeature], "2-section loft must evaluate: \(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        XCTAssertTrue(body.euclidMesh().isWatertight, "lofted solid must be watertight")
        XCTAssertEqual(volume(body), 4 * 4 * 10, accuracy: 4 * 4 * 10 * 0.02)

        // A single-section loft is under-specified → error, no crash, no body.
        let single = FeatureGraph(nodes: [
            FeatureNode(id: oneLoftFeature, name: "Loft1",
                kind: .loft(sections: [sectionRef(sketchAID, rectA)],
                            boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [oneBodyID]),
        ])
        let singleResult = single.evaluate(sketches: [sketchA, sketchB], planes: [],
                                            naming: SignatureNaming(), nextRevision: RevisionSource().next)
        switch singleResult.errors[oneLoftFeature] {
        case .brokenRef, .emptyGeometry: break
        default: XCTFail("1-section loft must error, got \(String(describing: singleResult.errors[oneLoftFeature]))")
        }
        XCTAssertTrue(singleResult.bodies.isEmpty, "a 1-section loft emits no body")
    }

    func testLoftWithUnresolvableMiddleSectionErrorsInsteadOfLoftingSubset() throws {
        // A 3-section loft A→B→C where B's sketch is deleted must surface a
        // broken-ref (like revolve/sweep), NOT silently loft A→C into the body.
        let loftFeature = FeatureID()
        let bodyID = BodyID()
        let sketchAID = SketchID(), missingID = SketchID(), sketchCID = SketchID()
        let rectA = UUID(), missingEntity = UUID(), rectC = UUID()
        let sketchA = Sketch(id: sketchAID, name: "A", plane: .worldXY,
                             entities: [.rect(id: rectA, min: SIMD2(-2, -2), max: SIMD2(2, 2))])
        let planeC = SketchPlane(origin: SIMD3(0, 0, 20), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0))
        let sketchC = Sketch(id: sketchCID, name: "C", plane: planeC,
                             entities: [.rect(id: rectC, min: SIMD2(-2, -2), max: SIMD2(2, 2))])
        func sectionRef(_ sid: SketchID, _ e: UUID) -> ProfileRef {
            ProfileRef(sketchID: sid, entityIDs: [e], holeEntityIDs: [], seedPoint: .zero)
        }
        let graph = FeatureGraph(nodes: [
            FeatureNode(id: loftFeature, name: "Loft",
                kind: .loft(sections: [sectionRef(sketchAID, rectA),
                                       sectionRef(missingID, missingEntity),   // deleted middle
                                       sectionRef(sketchCID, rectC)],
                            boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [bodyID]),
        ])
        // Only A and C are supplied — B's sketch is gone.
        let result = graph.evaluate(sketches: [sketchA, sketchC], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        switch result.errors[loftFeature] {
        case .brokenRef: break
        default: XCTFail("unresolvable middle section must brokenRef, got \(String(describing: result.errors[loftFeature]))")
        }
        XCTAssertNil(result.bodies.first { $0.id == bodyID },
                     "a partially-broken loft emits NO body, not a silently-different A→C solid")
    }

    func testReevaluatingWithAnEditedSketchRebuildsTheDependentBody() throws {
        // Associativity engine: an extrude references sketch S by entity id. When
        // S's rectangle is resized (SAME entity id) and the SAME graph is
        // re-evaluated against the new sketch, the dependent body must rebuild to
        // the new size — this is what rebuildForSketchChange relies on.
        let extrudeFeature = FeatureID()
        let bodyID = BodyID()
        let sketchID = SketchID(), rectEntity = UUID()
        func graph() -> FeatureGraph {
            FeatureGraph(nodes: [
                FeatureNode(id: extrudeFeature, name: "Extrude",
                    kind: .extrude(
                        profile: ProfileRef(sketchID: sketchID, entityIDs: [rectEntity],
                                            holeEntityIDs: [], seedPoint: .zero),
                        plane: PlaneRef(source: .sketch(sketchID)),
                        distance: Expr(value: 5), symmetric: false,
                        boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                        extraProfiles: []),
                    outputBodyIDs: [bodyID]),
            ])
        }
        let small = [rectSketch(id: sketchID, entityID: rectEntity,
                                min: SIMD2(-2, -2), max: SIMD2(2, 2))]   // 4×4 → V = 80
        let big = [rectSketch(id: sketchID, entityID: rectEntity,
                              min: SIMD2(-3, -3), max: SIMD2(3, 3))]     // 6×6 → V = 180

        let r1 = graph().evaluate(sketches: small, planes: [],
                                  naming: SignatureNaming(), nextRevision: RevisionSource().next)
        let b1 = try XCTUnwrap(r1.bodies.first { $0.id == bodyID })
        XCTAssertEqual(volume(b1), 4 * 4 * 5, accuracy: 1e-2)

        // Same graph, edited sketch (same entity id): body rebuilds larger, id stable.
        let r2 = graph().evaluate(sketches: big, planes: [],
                                  naming: SignatureNaming(), nextRevision: RevisionSource().next)
        let b2 = try XCTUnwrap(r2.bodies.first { $0.id == bodyID })
        XCTAssertEqual(volume(b2), 6 * 6 * 5, accuracy: 1e-2)
        XCTAssertEqual(b1.id, b2.id, "the dependent body keeps its identity across a sketch-driven rebuild")
    }

    /// (4) A mirror of an off-origin box across the world YZ plane (x=0): a fresh
    /// watertight body whose centroid x is negated; the source is kept.
    func testMirrorOffOriginBoxAcrossYZNegatesCentroidX() throws {
        let boxFeature = FeatureID(), mirrorFeature = FeatureID()
        let boxID = BodyID(), mirrorID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(id: boxFeature, name: "Box",
                kind: .primitive(spec: .box(width: 4, depth: 4, height: 4),
                                 placement: Transform3D(translation: SIMD3(20, 0, 0))),
                outputBodyIDs: [boxID]),
            FeatureNode(id: mirrorFeature, name: "Mirror",
                kind: .mirror(body: BodyRef(producer: boxFeature, bodyID: boxID),
                              plane: PlaneRef(source: .explicit(.worldYZ)),
                              keepOriginal: true),
                outputBodyIDs: [mirrorID]),
        ])
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNil(result.errors[mirrorFeature], "mirror must evaluate: \(result.errors)")
        // keepOriginal ⇒ the source stays AND the mirror is added (fresh BodyID).
        XCTAssertEqual(Set(result.bodies.map(\.id)), [boxID, mirrorID])
        let source = try XCTUnwrap(result.bodies.first { $0.id == boxID })
        let mirror = try XCTUnwrap(result.bodies.first { $0.id == mirrorID })
        XCTAssertNotEqual(source.id, mirror.id, "the mirror gets its own output BodyID")
        XCTAssertTrue(mirror.euclidMesh().isWatertight, "mirrored body must be watertight")
        XCTAssertEqual(mirror.transform, .identity)
        XCTAssertEqual(centroidX(source), 20, accuracy: 1e-3)
        XCTAssertEqual(centroidX(mirror), -20, accuracy: 1e-3, "centroid x is reflected across x=0")
    }

    /// (5) referencedSketchIDs unions the profile / plane / axis sketches per kind.
    func testReferencedSketchIDsCoversProfilePlaneAxis() {
        let sA = SketchID(), sB = SketchID(), sC = SketchID()
        let e = UUID(), axisE = UUID()

        let revolve = FeatureNode(id: FeatureID(), name: "R",
            kind: .revolve(
                profile: ProfileRef(sketchID: sA, entityIDs: [e], holeEntityIDs: [], seedPoint: nil),
                plane: PlaneRef(source: .sketch(sB)),
                axis: AxisRef(source: .sketchLine(sC, axisE)),
                angle: Expr(value: 360),
                boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
            outputBodyIDs: [BodyID()])
        XCTAssertEqual(revolve.referencedSketchIDs, [sA, sB, sC])

        let sweep = FeatureNode(id: FeatureID(), name: "S",
            kind: .sweep(
                profile: ProfileRef(sketchID: sA, entityIDs: [e], holeEntityIDs: [], seedPoint: nil),
                plane: PlaneRef(source: .sketch(sB)),
                spine: [PointWrapper(.zero)],
                boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                helix: nil),
            outputBodyIDs: [BodyID()])
        XCTAssertEqual(sweep.referencedSketchIDs, [sA, sB])

        let loft = FeatureNode(id: FeatureID(), name: "L",
            kind: .loft(
                sections: [ProfileRef(sketchID: sA, entityIDs: [e], holeEntityIDs: [], seedPoint: nil),
                           ProfileRef(sketchID: sB, entityIDs: [e], holeEntityIDs: [], seedPoint: nil)],
                boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
            outputBodyIDs: [BodyID()])
        XCTAssertEqual(loft.referencedSketchIDs, [sA, sB])
    }

    /// (6) Edit a revolve's angle 360°→180° and re-evaluate: geometry changes,
    /// the revolve's output BodyID stays stable across the rebuild.
    func testEditingRevolveAngleRebuildsWithStableBodyID() throws {
        let boxFeature = FeatureID(), revolveFeature = FeatureID()
        let boxID = BodyID(), revolveID = BodyID()
        let sketchID = SketchID(), rectEntity = UUID(), axisEntity = UUID()
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .rect(id: rectEntity, min: SIMD2(2, -1), max: SIMD2(4, 1)),
            .line(id: axisEntity, a: SIMD2(0, -5), b: SIMD2(0, 5)),
        ])
        func graph(angle: Double) -> FeatureGraph {
            FeatureGraph(nodes: [
                FeatureNode(id: boxFeature, name: "Box",
                    kind: .primitive(spec: .box(width: 2, depth: 2, height: 2), placement: .identity),
                    outputBodyIDs: [boxID]),
                FeatureNode(id: revolveFeature, name: "Revolve",
                    kind: .revolve(
                        profile: ProfileRef(sketchID: sketchID, entityIDs: [rectEntity],
                                            holeEntityIDs: [], seedPoint: SIMD2(3, 0)),
                        plane: PlaneRef(source: .sketch(sketchID)),
                        axis: AxisRef(source: .sketchLine(sketchID, axisEntity)),
                        angle: Expr(value: angle),
                        boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                    outputBodyIDs: [revolveID]),
            ])
        }

        let full = graph(angle: 360).evaluate(sketches: [sketch], planes: [],
            naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNil(full.errors[revolveFeature], "\(full.errors)")
        let fullBody = try XCTUnwrap(full.bodies.first { $0.id == revolveID })
        let fullVolume = volume(fullBody)

        // EDIT: half the sweep.
        let half = graph(angle: 180).evaluate(sketches: [sketch], planes: [],
            naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertNil(half.errors[revolveFeature], "\(half.errors)")
        let halfBody = try XCTUnwrap(half.bodies.first { $0.id == revolveID })

        XCTAssertTrue(halfBody.euclidMesh().isWatertight, "the 180° wedge must be watertight")
        // The revolve BodyID is reused on rebuild, never re-minted.
        XCTAssertEqual(halfBody.id, revolveID)
        XCTAssertEqual(fullBody.id, halfBody.id)
        // Geometry actually changed: half the angle ≈ half the ring volume.
        XCTAssertEqual(volume(halfBody), fullVolume / 2, accuracy: fullVolume * 0.05)
        XCTAssertLessThan(volume(halfBody), fullVolume - 1, "the downstream body must rebuild")
    }

    // MARK: Tranche 4 — pattern (linear / circular body patterns)

    /// Build a graph: a box (10³ at the origin) then a pattern of that box with
    /// `spec` writing into `copyIDs`.
    private func patternGraph(
        boxFeature: FeatureID, boxID: BodyID,
        patternFeature: FeatureID, copyIDs: [BodyID],
        spec: PatternSpec
    ) -> FeatureGraph {
        FeatureGraph(nodes: [
            FeatureNode(id: boxFeature, name: "Box",
                        kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                         placement: .identity),
                        outputBodyIDs: [boxID]),
            FeatureNode(id: patternFeature, name: "Pattern",
                        kind: .pattern(body: BodyRef(producer: boxFeature, bodyID: boxID),
                                       spec: spec),
                        outputBodyIDs: copyIDs),
        ])
    }

    /// (1) Linear pattern, count 3, spacing 10 along +X → 2 copies at x=10 and
    /// x=20; each watertight; the source is unchanged; the copy BodyIDs are the
    /// supplied (stable) ids.
    func testLinearPatternEmitsWatertightCopiesAndKeepsSource() throws {
        let boxFeature = FeatureID(), patternFeature = FeatureID()
        let boxID = BodyID()
        let copyA = BodyID(), copyB = BodyID()
        let spec = PatternSpec(kind: .linear, axis: SIMD3(1, 0, 0), count: 3,
                               spacing: 10, rotateInstances: true)
        let graph = patternGraph(boxFeature: boxFeature, boxID: boxID,
                                 patternFeature: patternFeature, copyIDs: [copyA, copyB],
                                 spec: spec)
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)

        XCTAssertNil(result.errors[patternFeature], "pattern must evaluate: \(result.errors)")
        // Source + 2 copies, exactly the supplied ids.
        XCTAssertEqual(Set(result.bodies.map(\.id)), [boxID, copyA, copyB])

        let source = try XCTUnwrap(result.bodies.first { $0.id == boxID })
        XCTAssertEqual(source.transform, .identity, "the source body stays put")
        XCTAssertEqual(volume(source), 1000, accuracy: 1e-3)

        let a = try XCTUnwrap(result.bodies.first { $0.id == copyA })
        let b = try XCTUnwrap(result.bodies.first { $0.id == copyB })
        XCTAssertEqual(a.transform.translation.x, 10, accuracy: 1e-9, "first copy at x=10")
        XCTAssertEqual(b.transform.translation.x, 20, accuracy: 1e-9, "second copy at x=20")
        // Copies reuse the source's local mesh → same watertight box volume.
        XCTAssertTrue(a.euclidMesh().isWatertight)
        XCTAssertTrue(b.euclidMesh().isWatertight)
        XCTAssertEqual(volume(a), 1000, accuracy: 1e-3)
        XCTAssertEqual(volume(b), 1000, accuracy: 1e-3)
    }

    /// (2) Editing the spec (count 3 → 4) with an extra supplied outputBodyID
    /// emits 3 copies at x=10, 20, 30.
    func testLinearPatternCountFourEmitsThreeCopies() throws {
        let boxFeature = FeatureID(), patternFeature = FeatureID()
        let boxID = BodyID()
        let ids = [BodyID(), BodyID(), BodyID()]
        let spec = PatternSpec(kind: .linear, axis: SIMD3(1, 0, 0), count: 4, spacing: 10)
        let graph = patternGraph(boxFeature: boxFeature, boxID: boxID,
                                 patternFeature: patternFeature, copyIDs: ids, spec: spec)
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)

        XCTAssertNil(result.errors[patternFeature], "\(result.errors)")
        XCTAssertEqual(Set(result.bodies.map(\.id)), Set([boxID] + ids))
        let xs = ids.map { id in
            (result.bodies.first { $0.id == id })?.transform.translation.x ?? .nan
        }.sorted()
        XCTAssertEqual(xs, [10, 20, 30], "three copies at x=10,20,30")
    }

    /// (3) Circular pattern, count 4 over a full 2π turn about +Z → 3 copies,
    /// each watertight and rotated by π/2, π, 3π/2 about the axis.
    func testCircularPatternEmitsThreeRotatedCopies() throws {
        let boxFeature = FeatureID(), patternFeature = FeatureID()
        let boxID = BodyID()
        let ids = [BodyID(), BodyID(), BodyID()]
        let spec = PatternSpec(kind: .circular, axis: SIMD3(0, 0, 1), count: 4,
                               totalAngle: 2 * .pi, rotateInstances: true)
        let graph = patternGraph(boxFeature: boxFeature, boxID: boxID,
                                 patternFeature: patternFeature, copyIDs: ids, spec: spec)
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)

        XCTAssertNil(result.errors[patternFeature], "\(result.errors)")
        XCTAssertEqual(Set(result.bodies.map(\.id)), Set([boxID] + ids))
        // Full turn over count=4 → adjacent step π/2; copies at π/2, π, 3π/2.
        let angles = ids.map { id -> Double in
            let body = result.bodies.first { $0.id == id }!
            return body.transform.rotation.angle
        }
        for (copyIndex, angle) in angles.enumerated() {
            let body = try XCTUnwrap(result.bodies.first { $0.id == ids[copyIndex] })
            XCTAssertTrue(body.euclidMesh().isWatertight, "circular copy must be watertight")
            XCTAssertNotEqual(angle, 0, accuracy: 1e-9, "each copy is actually rotated")
        }
        // At least one copy is a quarter turn (π/2) — proves the step is correct.
        XCTAssertTrue(angles.contains { abs($0 - .pi / 2) < 1e-6 },
                      "one copy is rotated a quarter turn about the axis")
    }

    /// (4) A pattern node with NO supplied outputBodyIDs emits no copies and does
    /// not crash — eval never mints ids.
    func testPatternWithNoOutputIDsEmitsNoCopies() throws {
        let boxFeature = FeatureID(), patternFeature = FeatureID()
        let boxID = BodyID()
        let spec = PatternSpec(kind: .linear, axis: SIMD3(1, 0, 0), count: 3, spacing: 10)
        let graph = patternGraph(boxFeature: boxFeature, boxID: boxID,
                                 patternFeature: patternFeature, copyIDs: [], spec: spec)
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)

        XCTAssertNil(result.errors[patternFeature], "empty outputBodyIDs is not an error")
        XCTAssertEqual(result.bodies.map(\.id), [boxID], "only the source body survives")
    }

    /// (5) A pattern whose source BodyRef cannot be resolved → `.brokenRef`, no crash.
    func testPatternWithMissingSourceReportsBrokenRef() throws {
        let patternFeature = FeatureID()
        let missing = BodyID(), copyID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(id: patternFeature, name: "Pattern",
                        kind: .pattern(body: BodyRef(producer: FeatureID(), bodyID: missing),
                                       spec: PatternSpec(kind: .linear, axis: SIMD3(1, 0, 0),
                                                         count: 3, spacing: 10)),
                        outputBodyIDs: [copyID]),
        ])
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)

        switch result.errors[patternFeature] {
        case .brokenRef: break
        default: XCTFail("missing source must brokenRef, got \(String(describing: result.errors[patternFeature]))")
        }
        XCTAssertTrue(result.bodies.isEmpty, "no body is emitted for a broken pattern source")
    }

    /// (6) EditFeatureOutputsCommand (the pattern count-edit command) swaps BOTH
    /// kind and outputBodyIDs consistently across apply / undo / REDO — carrying
    /// explicit before/after so redo never restores a stale output set (the
    /// tranche-3 variable-redo bug class).
    func testEditFeatureOutputsCommandIsConsistentAcrossRedo() {
        let patternFeature = FeatureID()
        let boxFeature = FeatureID(), boxID = BodyID()
        let copyA = BodyID(), copyB = BodyID(), copyC = BodyID()
        let bodyRef = BodyRef(producer: boxFeature, bodyID: boxID)
        let beforeSpec = PatternSpec(kind: .linear, axis: SIMD3(1, 0, 0), count: 3, spacing: 10)
        let afterSpec = PatternSpec(kind: .linear, axis: SIMD3(1, 0, 0), count: 4, spacing: 10)

        var doc = DesignDocument()
        doc.features = FeatureGraph(nodes: [
            FeatureNode(id: patternFeature, name: "Pattern",
                        kind: .pattern(body: bodyRef, spec: beforeSpec),
                        outputBodyIDs: [copyA, copyB]),   // count 3 → 2 copies
        ])
        let cmd = EditFeatureOutputsCommand(
            featureID: patternFeature,
            beforeKind: .pattern(body: bodyRef, spec: beforeSpec),
            afterKind: .pattern(body: bodyRef, spec: afterSpec),
            beforeOutputs: [copyA, copyB],
            afterOutputs: [copyA, copyB, copyC])          // grown to 3 copies

        func spec(_ d: DesignDocument) -> PatternSpec? {
            if case let .pattern(_, s)? = d.features.node(patternFeature)?.kind { return s }
            return nil
        }

        cmd.apply(to: &doc)
        XCTAssertEqual(spec(doc)?.count, 4)
        XCTAssertEqual(doc.features.node(patternFeature)?.outputBodyIDs, [copyA, copyB, copyC])
        cmd.revert(in: &doc)
        XCTAssertEqual(spec(doc)?.count, 3)
        XCTAssertEqual(doc.features.node(patternFeature)?.outputBodyIDs, [copyA, copyB])
        cmd.apply(to: &doc)   // redo
        XCTAssertEqual(spec(doc)?.count, 4, "redo restores the new count")
        XCTAssertEqual(doc.features.node(patternFeature)?.outputBodyIDs, [copyA, copyB, copyC],
                       "redo restores the grown output set (not a stale snapshot)")
    }

    // MARK: Tranche 5 — rollback (active-prefix replay)

    /// Node ids/handles for the 3-node rollback fixture:
    ///   box (10³ new body) → extrude (4×4×5 = 80 new body) → pushPull (box +Z out 2).
    private struct RollbackHandles {
        let boxFeature = FeatureID()
        let extrudeFeature = FeatureID()
        let pushFeature = FeatureID()
        let boxID = BodyID()
        let extrudeID = BodyID()
        let sketchID = SketchID()
        let rectEntity = UUID()
    }

    /// box → extrude(NEW body) → pushPull(box's +Z face out by 2). Three nodes,
    /// each producing/modifying a body, so the rollback slice is observable body-by-body.
    private func rollbackGraph(h: RollbackHandles, face faceRef: FaceRef) -> FeatureGraph {
        FeatureGraph(nodes: [
            FeatureNode(id: h.boxFeature, name: "Box",
                        kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                         placement: .identity),
                        outputBodyIDs: [h.boxID]),
            FeatureNode(id: h.extrudeFeature, name: "Extrude",
                        kind: .extrude(
                            profile: ProfileRef(sketchID: h.sketchID, entityIDs: [h.rectEntity],
                                                holeEntityIDs: [], seedPoint: .zero),
                            plane: PlaneRef(source: .sketch(h.sketchID)),
                            distance: Expr(value: 5), symmetric: false,
                            boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                            extraProfiles: []),
                        outputBodyIDs: [h.extrudeID]),
            FeatureNode(id: h.pushFeature, name: "PushPull",
                        kind: .pushPull(face: faceRef, distance: Expr(value: 2), mode: .planarAxial),
                        outputBodyIDs: []),
        ])
    }

    /// The box's +Z FaceRef (face at z=5), captured against a box-only evaluation.
    private func rollbackFaceRef(h: RollbackHandles) throws -> FaceRef {
        let seed = FeatureGraph(nodes: [
            FeatureNode(id: h.boxFeature, name: "Box",
                        kind: .primitive(spec: .box(width: 10, depth: 10, height: 10),
                                         placement: .identity),
                        outputBodyIDs: [h.boxID]),
        ]).evaluate(sketches: [], planes: [], naming: SignatureNaming(),
                    nextRevision: RevisionSource().next)
        let table = try XCTUnwrap(seed.faceTables[h.boxID])
        let entry = try XCTUnwrap(plusZEntry(table))
        return FaceRef(body: BodyRef(producer: h.boxFeature, bodyID: h.boxID),
                       creator: h.boxFeature, role: entry.role, signature: entry.signature)
    }

    /// (1) rollbackIndex = nil → every node replays: box is pushed (1000+200) and
    /// the extrude's new body (80) is present.
    func testRollbackNilEvaluatesAllNodes() throws {
        let h = RollbackHandles()
        let sketches = [rectSketch(id: h.sketchID, entityID: h.rectEntity,
                                   min: SIMD2(-2, -2), max: SIMD2(2, 2))]
        let faceRef = try rollbackFaceRef(h: h)
        var graph = rollbackGraph(h: h, face: faceRef)
        graph.rollbackIndex = nil

        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertTrue(result.errors.isEmpty, "no node should error: \(result.errors)")
        XCTAssertEqual(Set(result.bodies.map(\.id)), [h.boxID, h.extrudeID])
        let box = try XCTUnwrap(result.bodies.first { $0.id == h.boxID })
        XCTAssertEqual(volume(box), 1000 + 200, accuracy: 1e-2, "box was pushed by the 3rd node")
        let extrude = try XCTUnwrap(result.bodies.first { $0.id == h.extrudeID })
        XCTAssertEqual(volume(extrude), 4 * 4 * 5, accuracy: 1e-2)
    }

    /// (2) rollbackIndex = 2 → only the first 2 nodes replay; the pushPull is
    /// rolled back, so the box is NOT modified. The produced geometry must match
    /// evaluating a genuine 2-node (box + extrude) graph.
    func testRollbackToTwoSkipsThirdNodeMatchingTwoNodeGraph() throws {
        let h = RollbackHandles()
        let sketches = [rectSketch(id: h.sketchID, entityID: h.rectEntity,
                                   min: SIMD2(-2, -2), max: SIMD2(2, 2))]
        let faceRef = try rollbackFaceRef(h: h)

        var graph = rollbackGraph(h: h, face: faceRef)
        graph.rollbackIndex = 2
        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)

        // The pushPull did not run: no error recorded and the box is the raw 10³.
        XCTAssertNil(result.errors[h.pushFeature], "rolled-back node is not evaluated → no error")
        XCTAssertEqual(Set(result.bodies.map(\.id)), [h.boxID, h.extrudeID])
        let box = try XCTUnwrap(result.bodies.first { $0.id == h.boxID })
        XCTAssertEqual(volume(box), 1000, accuracy: 1e-2, "the +Z face push was rolled back")

        // Byte-for-geometry equivalent to a graph that only has the first 2 nodes.
        var twoNode = graph
        twoNode.rollbackIndex = nil
        twoNode.nodes = Array(graph.nodes.prefix(2))
        let twoResult = twoNode.evaluate(sketches: sketches, planes: [],
                                         naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertEqual(Set(twoResult.bodies.map(\.id)), Set(result.bodies.map(\.id)),
                       "rollback-2 yields the same body set as a real 2-node graph")
        for id in Set(result.bodies.map(\.id)) {
            let a = try XCTUnwrap(result.bodies.first { $0.id == id })
            let b = try XCTUnwrap(twoResult.bodies.first { $0.id == id })
            XCTAssertEqual(volume(a), volume(b), accuracy: 1e-6,
                           "rollback-2 geometry matches the 2-node graph for body \(id)")
        }
    }

    /// (3) rollbackIndex = 0 → the active prefix is empty → no bodies at all.
    func testRollbackToZeroProducesNoBodies() throws {
        let h = RollbackHandles()
        let sketches = [rectSketch(id: h.sketchID, entityID: h.rectEntity,
                                   min: SIMD2(-2, -2), max: SIMD2(2, 2))]
        let faceRef = try rollbackFaceRef(h: h)
        var graph = rollbackGraph(h: h, face: faceRef)
        graph.rollbackIndex = 0

        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertTrue(result.bodies.isEmpty, "rollbackIndex 0 → nothing evaluates")
        XCTAssertTrue(result.errors.isEmpty, "no node ran, so no node errored")
    }

    /// (4) rollbackIndex beyond the node count is clamped by `prefix` → identical
    /// to `nil` (all nodes), no crash.
    func testRollbackBeyondCountIsClampedLikeNil() throws {
        let h = RollbackHandles()
        let sketches = [rectSketch(id: h.sketchID, entityID: h.rectEntity,
                                   min: SIMD2(-2, -2), max: SIMD2(2, 2))]
        let faceRef = try rollbackFaceRef(h: h)
        var graph = rollbackGraph(h: h, face: faceRef)
        graph.rollbackIndex = 99   // way past the 3 nodes

        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertTrue(result.errors.isEmpty, "out-of-range marker must not error: \(result.errors)")
        XCTAssertEqual(Set(result.bodies.map(\.id)), [h.boxID, h.extrudeID])
        let box = try XCTUnwrap(result.bodies.first { $0.id == h.boxID })
        XCTAssertEqual(volume(box), 1000 + 200, accuracy: 1e-2,
                       "an over-count marker replays every node, exactly like nil")
    }

    /// (5) suppression and rollback COMPOSE: with all nodes in the active prefix
    /// (rollbackIndex = 3) a suppressed node inside that prefix is still skipped.
    func testSuppressedNodeInsideActivePrefixIsStillSkipped() throws {
        let h = RollbackHandles()
        let sketches = [rectSketch(id: h.sketchID, entityID: h.rectEntity,
                                   min: SIMD2(-2, -2), max: SIMD2(2, 2))]
        let faceRef = try rollbackFaceRef(h: h)
        var graph = rollbackGraph(h: h, face: faceRef)
        graph.rollbackIndex = 3   // every node active…
        // …but suppress the extrude (node index 1), which sits INSIDE the prefix.
        let idx = try XCTUnwrap(graph.index(of: h.extrudeFeature))
        graph.nodes[idx].suppressed = true

        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(), nextRevision: RevisionSource().next)
        XCTAssertTrue(result.errors.isEmpty, "no node should error: \(result.errors)")
        // The suppressed extrude produced no body; the box still ran and was pushed.
        XCTAssertEqual(Set(result.bodies.map(\.id)), [h.boxID],
                       "the suppressed node is skipped even though it is in the active prefix")
        let box = try XCTUnwrap(result.bodies.first { $0.id == h.boxID })
        XCTAssertEqual(volume(box), 1000 + 200, accuracy: 1e-2,
                       "the pushPull (active, unsuppressed) still ran on the box")
    }

    // MARK: - Back-compat

    /// Documents saved before helical sweeps existed carry no `helix` key
    /// anywhere; they must still decode, as the polyline sweep they were.
    func testASweepSavedBeforeHelicesDecodesWithNoHelix() throws {
        let sketchID = SketchID(), entity = UUID(), bodyID = BodyID()
        let node = FeatureNode(name: "Sweep",
            kind: .sweep(
                profile: ProfileRef(sketchID: sketchID, entityIDs: [entity],
                                    holeEntityIDs: [], seedPoint: .zero),
                plane: PlaneRef(source: .sketch(sketchID)),
                spine: [PointWrapper(SIMD3(0, 0, 0)), PointWrapper(SIMD3(0, 0, 10))],
                boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                helix: HelixSpec(axisPoint: .zero, axisDirection: SIMD3(0, 0, 1),
                                 referenceDirection: SIMD3(1, 0, 0),
                                 radius: 5, pitch: 2, turns: 3)),
            outputBodyIDs: [bodyID])
        let encoded = try JSONEncoder().encode(node)
        XCTAssertTrue(try XCTUnwrap(String(data: encoded, encoding: .utf8)).contains("\"helix\""),
                      "the helix is written when present")
        guard case let .sweep(_, _, _, _, kept) = try JSONDecoder().decode(FeatureNode.self, from: encoded).kind else {
            return XCTFail("round trip lost the sweep")
        }
        XCTAssertEqual(kept?.turns, 3, "a helix round-trips")

        // A pre-helix document: the same node with every `helix` key removed, wherever it sits.
        func stripped(_ any: Any) -> Any {
            if let dict = any as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, value) in dict where key != "helix" { out[key] = stripped(value) }
                return out
            }
            if let array = any as? [Any] { return array.map(stripped) }
            return any
        }
        let legacy = try JSONSerialization.data(
            withJSONObject: stripped(JSONSerialization.jsonObject(with: encoded)))
        let decoded = try JSONDecoder().decode(FeatureNode.self, from: legacy)
        guard case let .sweep(_, _, spine, _, helix) = decoded.kind else {
            return XCTFail("a pre-helix sweep failed to decode: \(decoded.kind)")
        }
        XCTAssertNil(helix)
        XCTAssertEqual(spine.count, 2, "the polyline spine is what it always was")
        XCTAssertEqual(decoded.outputBodyIDs, [bodyID])
    }
}
