//
//  SplitPatternFlowTests.swift
//  openshape3dTests
//
//  Split/Pattern UI flows (plan §B3/§B5): pattern-transform composition onto
//  body transforms, and the composite command shapes the flows commit
//  (Split = ReplaceBody + AddBody, Pattern = count−1 AddBody).
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class SplitPatternFlowTests: XCTestCase {

    // MARK: - composedPatternTransform

    func testComposedLinearTransformTranslatesThePivot() {
        var base = Transform3D.identity
        base.translation = SIMD3(1, 2, 3)
        let deltas = PatternKit.linearTransforms(
            direction: SIMD3(1, 0, 0), spacing: 5, count: 3
        )
        let second = EditorViewModel.composedPatternTransform(deltas[1], base: base)
        XCTAssertEqual(second.translation.x, 6, accuracy: 1e-9)
        XCTAssertEqual(second.translation.y, 2, accuracy: 1e-9)
        XCTAssertEqual(second.translation.z, 3, accuracy: 1e-9)
    }

    func testComposedCircularTransformMatchesWorldPointComposition() {
        var base = Transform3D.identity
        base.translation = SIMD3(4, 0, 1)
        base.rotation = simd_quatd(angle: 0.4, axis: SIMD3(0, 0, 1))
        base.scale = 2

        let transforms = PatternKit.circularTransforms(
            center: .zero,
            axis: SIMD3(0, 1, 0),
            count: 4,
            totalAngle: 2 * .pi,
            rotateInstances: true
        )
        let localPoint = SIMD3<Double>(0.3, -0.7, 1.1)
        for t in transforms {
            let composed = EditorViewModel.composedPatternTransform(t, base: base)
            let direct = t.rotation.act(base.applying(to: localPoint)) + t.translation
            let viaComposed = composed.applying(to: localPoint)
            XCTAssertEqual(viaComposed.x, direct.x, accuracy: 1e-9)
            XCTAssertEqual(viaComposed.y, direct.y, accuracy: 1e-9)
            XCTAssertEqual(viaComposed.z, direct.z, accuracy: 1e-9)
        }
    }

    // MARK: - Split composite (ReplaceBody + AddBody)

    func testSplitCompositeAppliesAndRevertsAsOneStep() {
        var document = DesignDocument()
        let box = Body(
            name: "Box",
            primitive: .box(width: 4, depth: 4, height: 4),
            euclidMesh: .primitive(.box(width: 4, depth: 4, height: 4)),
            revision: document.nextRevision()
        )
        document.bodies.append(box)

        let halves = KernelOps.split(body: box.euclidMesh(), byPlane: .worldYZ)
        XCTAssertFalse(halves.kept.polygons.isEmpty)
        XCTAssertFalse(halves.other.polygons.isEmpty)

        // Halves are named "<name> A" / "<name> B" (performSplit convention).
        let first = Body(
            id: box.id, name: document.uniqueBodyName(base: "\(box.name) A"),
            transform: .identity,
            primitive: nil, euclidMesh: halves.kept, revision: 0
        )
        let second = Body(
            name: document.uniqueBodyName(base: "\(box.name) B"),
            euclidMesh: halves.other,
            revision: document.nextRevision()
        )
        let split = CompositeCommand(title: "Split", commands: [
            ReplaceBodyCommand(title: "Split", before: box, after: first),
            AddBodyCommand(body: second, title: "Split"),
        ])

        split.apply(to: &document)
        XCTAssertEqual(document.bodies.count, 2)
        XCTAssertEqual(document.bodies.map(\.name), ["Box A", "Box B"])
        XCTAssertNil(document.bodies[0].primitive, "Split bakes the primitive away")

        split.revert(in: &document)
        XCTAssertEqual(document.bodies.count, 1)
        XCTAssertEqual(document.bodies[0].name, "Box")
        XCTAssertNotNil(document.bodies[0].primitive, "Undo restores the original body")
    }

    // MARK: - Pattern composite (count−1 AddBody)

    func testPatternCompositeAddsAndRevertsAllCopies() {
        var document = DesignDocument()
        let box = Body(
            name: "Box",
            euclidMesh: .primitive(.box(width: 4, depth: 4, height: 4)),
            revision: document.nextRevision()
        )
        document.bodies.append(box)

        var naming = document
        var commands: [DocumentCommand] = []
        for t in PatternKit.linearTransforms(
            direction: SIMD3(1, 0, 0), spacing: 6, count: 3
        ).dropFirst() {
            let copy = Body(
                id: BodyID(),
                name: naming.uniqueBodyName(base: box.name),
                transform: EditorViewModel.composedPatternTransform(t, base: box.transform),
                primitive: box.primitive,
                render: box.render,
                revision: naming.nextRevision()
            )
            naming.bodies.append(copy)
            commands.append(AddBodyCommand(body: copy, title: "Pattern"))
        }
        let pattern = CompositeCommand(title: "Pattern", commands: commands)

        pattern.apply(to: &document)
        XCTAssertEqual(document.bodies.count, 3)
        XCTAssertEqual(document.bodies.map(\.name), ["Box", "Box 2", "Box 3"])
        XCTAssertEqual(document.bodies[1].transform.translation.x, 6, accuracy: 1e-9)
        XCTAssertEqual(document.bodies[2].transform.translation.x, 12, accuracy: 1e-9)

        pattern.revert(in: &document)
        XCTAssertEqual(document.bodies.count, 1)
        XCTAssertEqual(document.bodies[0].name, "Box")
    }
}
