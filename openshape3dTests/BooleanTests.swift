//
//  BooleanTests.swift
//  openshape3dTests
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class BooleanTests: XCTestCase {

    private func makeBody(_ spec: PrimitiveSpec, at translation: SIMD3<Double>) -> Body {
        var transform = Transform3D.identity
        transform.translation = translation
        return Body(
            name: spec.displayName,
            transform: transform,
            primitive: spec,
            euclidMesh: .primitive(spec),
            revision: 1
        )
    }

    func testSubtractCutsPocket() {
        let slab = makeBody(.box(width: 8, depth: 8, height: 2), at: .zero)
        // Cylinder overlapping the slab's top face — cuts a blind pocket.
        let punch = makeBody(.cylinder(radius: 1.5, height: 4), at: SIMD3(0, 1, 0))

        let result = KernelOps.boolean(.subtract, target: slab, tool: punch)
        XCTAssertFalse(result.polygons.isEmpty)
        XCTAssertTrue(result.isWatertight)

        // Outer AABB unchanged; pocket adds inner geometry.
        let aabb = EuclidBridge.renderMesh(from: result).localAABB
        XCTAssertEqual(aabb.min.x, -4, accuracy: 1e-3)
        XCTAssertEqual(aabb.max.y, 2, accuracy: 1e-3)
        let plain = EuclidBridge.renderMesh(from: slab.euclidMesh())
        XCTAssertGreaterThan(
            EuclidBridge.renderMesh(from: result).triangleCount,
            plain.triangleCount
        )
    }

    func testUnionMergesBodies() {
        let a = makeBody(.box(width: 4, depth: 4, height: 4), at: .zero)
        let b = makeBody(.box(width: 4, depth: 4, height: 4), at: SIMD3(2, 0, 0))

        let result = KernelOps.boolean(.union, target: a, tool: b)
        XCTAssertTrue(result.isWatertight)
        let aabb = EuclidBridge.renderMesh(from: result).localAABB
        XCTAssertEqual(aabb.min.x, -2, accuracy: 1e-3)
        XCTAssertEqual(aabb.max.x, 4, accuracy: 1e-3, "Union spans both boxes")
    }

    func testIntersectKeepsOverlap() {
        let a = makeBody(.box(width: 4, depth: 4, height: 4), at: .zero)
        let b = makeBody(.box(width: 4, depth: 4, height: 4), at: SIMD3(2, 0, 0))

        let result = KernelOps.boolean(.intersect, target: a, tool: b)
        XCTAssertTrue(result.isWatertight)
        let aabb = EuclidBridge.renderMesh(from: result).localAABB
        XCTAssertEqual(aabb.min.x, 0, accuracy: 1e-3)
        XCTAssertEqual(aabb.max.x, 2, accuracy: 1e-3, "Intersection is the overlap slab")
    }

    func testCompositeCommandAppliesAndRevertsAsOneStep() {
        var document = DesignDocument()
        let a = makeBody(.box(width: 2, depth: 2, height: 2), at: .zero)
        let b = makeBody(.box(width: 2, depth: 2, height: 2), at: SIMD3(5, 0, 0))
        document.bodies = [a, b]

        // Multi-body cut shape: one ReplaceBodyCommand per body, one step.
        func shrunk(_ body: Body) -> Body {
            Body(
                id: body.id, name: body.name, transform: body.transform,
                primitive: nil,
                euclidMesh: .primitive(.box(width: 1, depth: 1, height: 1)),
                revision: 0
            )
        }
        let composite = CompositeCommand(title: "Extrude", commands: [
            ReplaceBodyCommand(title: "Extrude", before: a, after: shrunk(a)),
            ReplaceBodyCommand(title: "Extrude", before: b, after: shrunk(b)),
        ])

        composite.apply(to: &document)
        XCTAssertEqual(document.bodies.count, 2)
        XCTAssertNil(document.bodies[0].primitive, "Both bodies replaced")
        XCTAssertNil(document.bodies[1].primitive)

        composite.revert(in: &document)
        XCTAssertNotNil(document.body(with: a.id)?.primitive, "Both bodies restored")
        XCTAssertNotNil(document.body(with: b.id)?.primitive)
    }

    func testBooleanCommandUndoRestoresBothBodies() {
        var document = DesignDocument()
        let a = makeBody(.box(width: 4, depth: 4, height: 4), at: .zero)
        let b = makeBody(.cylinder(radius: 1, height: 6), at: SIMD3(1, 0, 0))
        document.bodies = [a, b]

        let mesh = KernelOps.boolean(.subtract, target: a, tool: b)
        let result = Body(
            id: a.id, name: a.name, transform: .identity,
            primitive: nil, euclidMesh: mesh, revision: 0
        )
        let command = BooleanCommand(
            kind: .subtract, targetBefore: a, toolIndex: 1, toolBefore: b, result: result
        )

        command.apply(to: &document)
        XCTAssertEqual(document.bodies.count, 1)
        XCTAssertNil(document.bodies[0].primitive, "Result is baked")

        command.revert(in: &document)
        XCTAssertEqual(document.bodies.count, 2)
        XCTAssertEqual(document.bodies[1].id, b.id, "Tool restored at its index")
        XCTAssertNotNil(document.body(with: a.id)?.primitive, "Target restored as primitive")
    }
}
