//
//  RollbackCommandTests.swift
//  openshape3dTests
//
//  Task B1 (Tranche 5) proof: the rollback-marker bookkeeping on the pure
//  DocumentCommands. Every test operates on a plain `DesignDocument` VALUE and
//  drives `apply`/`revert` directly — no DocumentSession / ModelContainer (per
//  repo convention, session/SwiftData behavior is covered by UI tests).
//
//  Covered:
//    • AppendFeatureCommand inserts at the marker and advances it; revert undoes
//      both — and, with no marker, is byte-identical to a plain append.
//    • RemoveFeatureCommand decrements the marker when it drops an ACTIVE node;
//      revert restores the node AND the marker.
//    • SetRollbackCommand round-trips the marker value.
//

import XCTest
@testable import openshape3d

final class RollbackCommandTests: XCTestCase {

    // A trivial feature node; the kind is irrelevant to marker bookkeeping.
    private func node(_ name: String) -> FeatureNode {
        FeatureNode(
            name: name,
            kind: .primitive(spec: .box(width: 1, depth: 1, height: 1), placement: .identity),
            outputBodyIDs: [BodyID()]
        )
    }

    private func doc(_ nodes: [FeatureNode], rollbackIndex: Int?) -> DesignDocument {
        var d = DesignDocument()
        d.features = FeatureGraph(nodes: nodes, rollbackIndex: rollbackIndex)
        return d
    }

    // MARK: 1 — Append into a rolled-back graph inserts at the marker + advances it

    func testAppendWithRollbackInsertsAtMarkerAndAdvances() {
        let a = node("A"), b = node("B")
        var document = doc([a, b], rollbackIndex: 1)   // only A active
        let fresh = node("C")
        let cmd = AppendFeatureCommand(node: fresh)

        cmd.apply(to: &document)
        // Inserted at index 1 (the rollback point), marker advances 1 -> 2.
        XCTAssertEqual(document.features.nodes.map(\.name), ["A", "C", "B"])
        XCTAssertEqual(document.features.nodes[1].id, fresh.id)
        XCTAssertEqual(document.features.rollbackIndex, 2)

        cmd.revert(in: &document)
        // Node removed, marker pulled back 2 -> 1, order restored.
        XCTAssertEqual(document.features.nodes.map(\.name), ["A", "B"])
        XCTAssertEqual(document.features.rollbackIndex, 1)
    }

    // MARK: 2 — Append with no marker is byte-identical to a plain append

    func testAppendWithNilRollbackAppendsAtEnd() {
        let a = node("A"), b = node("B")
        var document = doc([a, b], rollbackIndex: nil)
        let fresh = node("C")
        let cmd = AppendFeatureCommand(node: fresh)

        cmd.apply(to: &document)
        XCTAssertEqual(document.features.nodes.map(\.name), ["A", "B", "C"])
        XCTAssertNil(document.features.rollbackIndex)

        cmd.revert(in: &document)
        XCTAssertEqual(document.features.nodes.map(\.name), ["A", "B"])
        XCTAssertNil(document.features.rollbackIndex)
    }

    // MARK: 3 — Remove of an ACTIVE node decrements the marker; revert restores both

    func testRemoveActiveNodeDecrementsMarkerAndRevertRestores() {
        let a = node("A"), b = node("B"), c = node("C")
        var document = doc([a, b, c], rollbackIndex: 2)   // A,B active; C rolled back
        let cmd = RemoveFeatureCommand(index: 0, node: a, beforeRollback: 2)

        cmd.apply(to: &document)
        // A (index 0 < 2) dropped -> marker 2 -> 1.
        XCTAssertEqual(document.features.nodes.map(\.name), ["B", "C"])
        XCTAssertEqual(document.features.rollbackIndex, 1)

        cmd.revert(in: &document)
        // A re-inserted at index 0, marker back to 2.
        XCTAssertEqual(document.features.nodes.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(document.features.nodes[0].id, a.id)
        XCTAssertEqual(document.features.rollbackIndex, 2)
    }

    // A removed node at/after the marker leaves it untouched (bonus symmetry check).
    func testRemoveRolledBackNodeLeavesMarkerUnchanged() {
        let a = node("A"), b = node("B"), c = node("C")
        var document = doc([a, b, c], rollbackIndex: 2)   // C (index 2) is rolled back
        let cmd = RemoveFeatureCommand(index: 2, node: c, beforeRollback: 2)

        cmd.apply(to: &document)
        XCTAssertEqual(document.features.rollbackIndex, 2, "removing a node >= marker keeps it")
        cmd.revert(in: &document)
        XCTAssertEqual(document.features.rollbackIndex, 2)
        XCTAssertEqual(document.features.nodes.map(\.name), ["A", "B", "C"])
    }

    // BOUNDARY: removing the LAST ACTIVE node (index == marker - 1). apply
    // decrements the marker; revert must restore it EXACTLY (recomputing
    // `index < cut` against the decremented marker would wrongly leave it short,
    // silently rolling the restored node back).
    func testRemoveLastActiveNodeRevertRestoresMarkerExactly() {
        let a = node("A"), b = node("B")
        var document = doc([a, b], rollbackIndex: 1)   // A active (last active, index 0); B rolled back
        let cmd = RemoveFeatureCommand(index: 0, node: a, beforeRollback: 1)

        cmd.apply(to: &document)
        XCTAssertEqual(document.features.nodes.map(\.name), ["B"])
        XCTAssertEqual(document.features.rollbackIndex, 0, "the only active node dropped → marker 0")

        cmd.revert(in: &document)
        XCTAssertEqual(document.features.nodes.map(\.name), ["A", "B"])
        XCTAssertEqual(document.features.rollbackIndex, 1,
                       "revert restores the marker so A is active again (not rolled back)")

        cmd.apply(to: &document)   // redo stays consistent
        XCTAssertEqual(document.features.rollbackIndex, 0)
    }

    // MARK: 4 — SetRollbackCommand round-trips the marker value

    func testSetRollbackCommandRoundTrips() {
        let a = node("A"), b = node("B")
        var document = doc([a, b], rollbackIndex: nil)
        let cmd = SetRollbackCommand(before: nil, after: 1)
        XCTAssertEqual(cmd.title, "Roll Back")

        cmd.apply(to: &document)
        XCTAssertEqual(document.features.rollbackIndex, 1)

        cmd.revert(in: &document)
        XCTAssertNil(document.features.rollbackIndex)

        // Clearing the marker (return to latest) is the same command with after nil.
        let clear = SetRollbackCommand(before: 1, after: nil)
        XCTAssertEqual(clear.title, "Return to Latest")
        document.features.rollbackIndex = 1
        clear.apply(to: &document)
        XCTAssertNil(document.features.rollbackIndex)
        clear.revert(in: &document)
        XCTAssertEqual(document.features.rollbackIndex, 1)
    }

    // MARK: 4 — MoveFeatureCommand reorders and reverts symmetrically

    func testMoveFeatureReordersAndRevertRestores() {
        let a = node("A"), b = node("B"), c = node("C")
        var document = doc([a, b, c], rollbackIndex: nil)

        // Move A (0) to the end.
        let toEnd = MoveFeatureCommand(featureID: a.id, from: 0, to: 2)
        toEnd.apply(to: &document)
        XCTAssertEqual(document.features.nodes.map(\.name), ["B", "C", "A"])
        toEnd.revert(in: &document)
        XCTAssertEqual(document.features.nodes.map(\.name), ["A", "B", "C"])

        // Move C (2) to the front.
        let toFront = MoveFeatureCommand(featureID: c.id, from: 2, to: 0)
        toFront.apply(to: &document)
        XCTAssertEqual(document.features.nodes.map(\.name), ["C", "A", "B"])
        toFront.revert(in: &document)
        XCTAssertEqual(document.features.nodes.map(\.name), ["A", "B", "C"])
    }

    // MARK: 5 — A reorder leaves the (positional) rollback marker COUNT unchanged

    func testMoveFeatureLeavesRollbackMarkerUnchanged() {
        let a = node("A"), b = node("B"), c = node("C")
        var document = doc([a, b, c], rollbackIndex: 2) // A, B active

        let cmd = MoveFeatureCommand(featureID: c.id, from: 2, to: 0)
        cmd.apply(to: &document)
        XCTAssertEqual(document.features.nodes.map(\.name), ["C", "A", "B"])
        XCTAssertEqual(document.features.rollbackIndex, 2, "reorder is positional; marker count is unchanged")

        cmd.revert(in: &document)
        XCTAssertEqual(document.features.nodes.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(document.features.rollbackIndex, 2)
    }
}
