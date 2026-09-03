//
//  RebuildPlannerTests.swift
//  openshape3dTests
//
//  The rebuild diff — skip-unchanged replace, add, delete-consumed, metadata
//  preservation, leading commands — as pure values (docs/OFF_MAIN_EVAL_DESIGN.md
//  slice 0). Until the planner was extracted these semantics were exercised
//  only by the 46-minute UI suite, because DocumentSession needs SwiftData.
//

import XCTest
import simd
@testable import openshape3d

@MainActor
final class RebuildPlannerTests: XCTestCase {

    /// A minimal stand-in for the session's rebuild loop: one document, one
    /// memo, revisions minted from the DOCUMENT's counter (as the session
    /// does, so replay-minted and apply-minted revisions never collide),
    /// commands applied, memo adopted to the applied bodies.
    @MainActor
    private final class MiniSession {
        var doc = DesignDocument()
        var cache = EvalCache()

        @discardableResult
        func rebuild(_ graph: FeatureGraph, leading: [DocumentCommand] = [],
                     sketches: [Sketch]) -> RebuildPlan {
            let plan = RebuildPlanner.plan(
                editedGraph: graph, previousGraph: doc.features, document: doc,
                sketches: sketches, planes: [], naming: SignatureNaming(),
                cache: &cache, nextRevision: { self.doc.nextRevision() },
                leadingCommands: leading, title: "Rebuild")
            for command in plan.commands { command.apply(to: &doc) }
            doc.features = graph
            cache.adopt(Dictionary(uniqueKeysWithValues: doc.bodies.map { ($0.id, $0) }),
                        order: doc.features.nodes.map(\.id))
            return plan
        }
    }

    private struct Fixture {
        let sketchA = SketchID(), sketchB = SketchID()
        let rectA = UUID(), rectB = UUID()
        let nodeA = FeatureID(), nodeB = FeatureID(), nodeU = FeatureID()
        let bodyA = BodyID(), bodyB = BodyID()

        var sketches: [Sketch] {
            [Sketch(id: sketchA, name: "A", plane: .ground, entities: [
                .rect(id: rectA, min: SIMD2(0, 0), max: SIMD2(10, 10))]),
             Sketch(id: sketchB, name: "B", plane: .ground, entities: [
                .rect(id: rectB, min: SIMD2(5, 5), max: SIMD2(15, 15))])]
        }

        func extrude(_ id: FeatureID, sketch: SketchID, rect: UUID, body: BodyID,
                     distance: Double, seed: SIMD2<Double>) -> FeatureNode {
            FeatureNode(id: id, name: "E", kind: .extrude(
                profile: ProfileRef(sketchID: sketch, entityIDs: [rect],
                                    holeEntityIDs: [], seedPoint: seed),
                plane: PlaneRef(source: .sketch(sketch)), distance: Expr(value: distance),
                symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                extraProfiles: []), outputBodyIDs: [body])
        }

        func graph(distanceA: Double = 10, distanceB: Double = 10,
                   withB: Bool = true, withUnion: Bool = false) -> FeatureGraph {
            var nodes = [extrude(nodeA, sketch: sketchA, rect: rectA, body: bodyA,
                                 distance: distanceA, seed: SIMD2(2, 2))]
            if withB {
                nodes.append(extrude(nodeB, sketch: sketchB, rect: rectB, body: bodyB,
                                     distance: distanceB, seed: SIMD2(10, 10)))
            }
            if withUnion {
                nodes.append(FeatureNode(id: nodeU, name: "U", kind: .boolean(
                    kind: .union, target: BodyRef(producer: nodeA, bodyID: bodyA),
                    tools: [BodyRef(producer: nodeB, bodyID: bodyB)]), outputBodyIDs: [bodyA]))
            }
            return FeatureGraph(nodes: nodes)
        }
    }

    private func kinds(_ plan: RebuildPlan) -> (add: Int, replace: Int, delete: Int, edit: Int) {
        (plan.commands.filter { $0 is AddBodyCommand }.count,
         plan.commands.filter { $0 is ReplaceBodyCommand }.count,
         plan.commands.filter { $0 is DeleteBodiesCommand }.count,
         plan.commands.filter { $0 is EditFeatureCommand }.count)
    }

    func testFreshDocumentAddsEveryProducedBody() {
        let f = Fixture(), s = MiniSession()
        let plan = s.rebuild(f.graph(), sketches: f.sketches)
        XCTAssertEqual(kinds(plan).add, 2)
        XCTAssertEqual(kinds(plan).replace, 0); XCTAssertEqual(kinds(plan).delete, 0)
        XCTAssertEqual(s.doc.bodies.count, 2)
        XCTAssertEqual(Set(plan.resultBodyIDs), [f.bodyA, f.bodyB])
        XCTAssertTrue(plan.errors.isEmpty)
    }

    /// The memo + skip-unchanged, pinned purely: an identical rebuild after
    /// adoption produces NO commands at all — no replace, no re-mint.
    func testUnchangedRebuildProducesNoCommands() {
        let f = Fixture(), s = MiniSession()
        s.rebuild(f.graph(), sketches: f.sketches)
        let revisions = s.doc.bodies.map(\.meshRevision)
        let plan = s.rebuild(f.graph(), sketches: f.sketches)
        XCTAssertTrue(plan.commands.isEmpty, "nothing changed: nothing to perform")
        XCTAssertEqual(s.cache.lastSkipped, 2); XCTAssertEqual(s.cache.lastRan, 0)
        XCTAssertEqual(s.doc.bodies.map(\.meshRevision), revisions, "revisions untouched")
    }

    func testEditingOneNodeReplacesOnlyItsBody() throws {
        let f = Fixture(), s = MiniSession()
        s.rebuild(f.graph(), sketches: f.sketches)
        let before = try XCTUnwrap(s.doc.body(with: f.bodyB))
        let plan = s.rebuild(f.graph(distanceB: 20), sketches: f.sketches)
        XCTAssertEqual(kinds(plan).replace, 1); XCTAssertEqual(kinds(plan).add, 0)
        let replace = try XCTUnwrap(plan.commands.first { $0 is ReplaceBodyCommand } as? ReplaceBodyCommand)
        XCTAssertEqual(replace.after.id, f.bodyB)
        let after = try XCTUnwrap(s.doc.body(with: f.bodyB))
        XCTAssertGreaterThan(MeasureKit.volume(of: after), MeasureKit.volume(of: before))
        XCTAssertNotEqual(after.meshRevision, before.meshRevision)
    }

    func testRemovingANodeDeletesItsOrphanedBody() throws {
        let f = Fixture(), s = MiniSession()
        s.rebuild(f.graph(), sketches: f.sketches)
        let plan = s.rebuild(f.graph(withB: false), sketches: f.sketches)
        XCTAssertEqual(kinds(plan).delete, 1)
        let delete = try XCTUnwrap(plan.commands.first { $0 is DeleteBodiesCommand } as? DeleteBodiesCommand)
        XCTAssertEqual(delete.removed.map(\.body.id), [f.bodyB])
        XCTAssertEqual(s.doc.bodies.map(\.id), [f.bodyA])
        XCTAssertEqual(kinds(plan).replace, 0, "A was untouched (spliced)")
    }

    /// A boolean consumes its tool: on a fresh document only the target is
    /// added; editing the tool afterwards replaces the target (the union
    /// re-ran) and never tries to delete a tool that was never in the document.
    func testConsumedToolNeverReachesTheDocument() throws {
        let f = Fixture(), s = MiniSession()
        let first = s.rebuild(f.graph(withUnion: true), sketches: f.sketches)
        XCTAssertEqual(kinds(first).add, 1); XCTAssertEqual(kinds(first).delete, 0)
        XCTAssertEqual(s.doc.bodies.map(\.id), [f.bodyA])
        let edited = s.rebuild(f.graph(distanceB: 20, withUnion: true), sketches: f.sketches)
        XCTAssertEqual(kinds(edited).replace, 1); XCTAssertEqual(kinds(edited).add, 0)
        XCTAssertEqual(kinds(edited).delete, 0)
    }

    func testReplacePreservesUserMetadata() throws {
        let f = Fixture(), s = MiniSession()
        s.rebuild(f.graph(), sketches: f.sketches)
        let i = try XCTUnwrap(s.doc.bodyIndex(of: f.bodyA))
        s.doc.bodies[i].name = "Custom name"
        s.doc.bodies[i].isHidden = true
        let plan = s.rebuild(f.graph(distanceA: 20), sketches: f.sketches)
        let replace = try XCTUnwrap(plan.commands.first { $0 is ReplaceBodyCommand } as? ReplaceBodyCommand)
        XCTAssertEqual(replace.after.name, "Custom name")
        XCTAssertTrue(replace.after.isHidden)
    }

    /// Leading commands come first and, on their own, make the plan
    /// non-empty — an edit that changes no geometry still records itself.
    func testLeadingCommandsComeFirstEvenWhenGeometryIsUnchanged() throws {
        let f = Fixture(), s = MiniSession()
        s.rebuild(f.graph(), sketches: f.sketches)
        let node = try XCTUnwrap(f.graph().node(f.nodeA))
        let edit = EditFeatureCommand(featureID: f.nodeA, before: node.kind, after: node.kind)
        let plan = s.rebuild(f.graph(), leading: [edit], sketches: f.sketches)
        XCTAssertEqual(plan.commands.count, 1)
        XCTAssertTrue(plan.commands[0] is EditFeatureCommand)
    }
}
