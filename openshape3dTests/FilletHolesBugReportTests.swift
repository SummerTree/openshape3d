//
//  FilletHolesBugReportTests.swift
//  openshape3dTests
//
//  Bug report a6fea315 (2026-09-27, iPad, 1.3 build 3): "When applying
//  fillet to one edge, the mesh breaks. There are some holes in it now."
//  The attached design is committed whole as an `.os3d` fixture and replayed
//  through the feature graph exactly as the app rebuilds it on open:
//  Extrude (block with a hole) → Push/Pull (a wall pushed in through the
//  hole) → Revolve → Union → Fillet.
//
//  Cause: the face push/pull always produced a MESH, dropping the block's
//  B-rep for good. The union and the fillet after it therefore ran on the
//  Euclid mesh path, whose swept blend tool met the faceted rim
//  near-tangentially and left 19 inside-out triangles and 3 open edges — a
//  long sliver hole in the rounded wall, identical to the mesh the user
//  saved. A push/pull on an analytic body now stays analytic
//  (`OCCTKernel.pushPullResult`), so the whole chain runs in OCCT and the
//  fillet comes out a valid, closed solid.
//

import XCTest
import simd
@testable import openshape3d

final class FilletHolesBugReportTests: XCTestCase {

    private static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/bugreport-a6fea315-fillet.os3d")

    private final class RevisionSource {
        private var value: UInt64 = 0
        func next() -> UInt64 { value += 1; return value }
    }

    private struct Design {
        var graph: FeatureGraph
        var sketches: [Sketch]
        var planes: [ConstructionPlane]
    }

    private func loadDesign() throws -> Design {
        let data = try Data(contentsOf: Self.fixture)
        let archive = try XCTUnwrap(ProjectArchive.decode(data))
        let nodes = try archive.features.sorted { $0.orderIndex < $1.orderIndex }.map { record in
            FeatureNode(
                id: FeatureID(raw: record.id), name: record.name,
                kind: try XCTUnwrap(decodeFeatureKind(record.kind)), suppressed: record.suppressed,
                outputBodyIDs: decodeBodyIDs(record.outputBodyIDs) ?? [])
        }
        let sketches = try archive.sketches.map { try JSONDecoder().decode(Sketch.self, from: $0.data) }
        let planes = try archive.planes.map { try JSONDecoder().decode(ConstructionPlane.self, from: $0.data) }
        return Design(graph: FeatureGraph(nodes: nodes), sketches: sketches, planes: planes)
    }

    private func evaluate(_ design: Design, through count: Int? = nil) -> EvalResult {
        var graph = design.graph
        graph.rollbackIndex = count
        return graph.evaluate(sketches: design.sketches, planes: design.planes,
                              naming: SignatureNaming(), nextRevision: RevisionSource().next)
    }

    func testThePushPullKeepsTheBlockAnalytic() throws {
        let design = try loadDesign()
        XCTAssertEqual(design.graph.nodes.map(\.name),
                       ["Extrude", "Push/Pull", "Revolve", "Union", "Fillet"])
        let result = evaluate(design, through: 2)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let block = try XCTUnwrap(result.bodies.first)
        let brep = try XCTUnwrap(block.brep, "a push/pull on a B-rep body must keep the B-rep")
        XCTAssertTrue(OCCTKernel.healthReport(for: brep).isValid)
        // The same solid the mesh path made: the wall pushed 1.5 into the
        // 5×3×2 block, through the centre of its Ø2 hole — half the volume.
        XCTAssertEqual(OCCTKernel.volume(brep), 11.859, accuracy: 0.01)
    }

    func testTheFilletBuildsAClosedSolidWithoutHoles() throws {
        let design = try loadDesign()
        let fillet = try XCTUnwrap(design.graph.nodes.last).id
        let union = evaluate(design, through: 4)
        XCTAssertNotNil(try XCTUnwrap(union.bodies.first).brep, "the union stays analytic too")

        let result = evaluate(design)
        XCTAssertNil(result.errors[fillet], "\(result.errors)")
        XCTAssertEqual(result.bodies.count, 1)
        let body = try XCTUnwrap(result.bodies.first)
        let brep = try XCTUnwrap(body.brep, "the fillet ran in OCCT, not on the mesh path")
        let health = OCCTKernel.healthReport(for: brep)
        XCTAssertTrue(health.isValid, health.findingsSummary)
        let defects = RenderDefects.count(body.render)
        XCTAssertEqual(defects.open, 0, "open edges render as holes")
        XCTAssertEqual(defects.flipped, 0, "inside-out triangles render as holes")
        // A fillet removes material, and only a little of it.
        let before = OCCTKernel.volume(try XCTUnwrap(union.bodies.first?.brep))
        let after = OCCTKernel.volume(brep)
        XCTAssertLessThan(after, before)
        XCTAssertGreaterThan(after, before * 0.9)
    }
}
