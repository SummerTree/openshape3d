//
//  RotateAxisAlignTests.swift
//  openshape3dTests
//
//  Plan §B6: rotation about an arbitrary world axis line (spec §5.3) and the
//  sketch endpoint connectivity behind double-tap chain selection (§1.10).
//

import XCTest
import simd
@testable import openshape3d

final class RotateAxisAlignTests: XCTestCase {

    private func assertEqual(
        _ a: SIMD3<Double>, _ b: SIMD3<Double>, accuracy: Double = 1e-9,
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - Transform3D.rotated(byRadians:aboutAxisThrough:direction:)

    func testRotationAboutOffsetAxisOrbitsTheTranslation() {
        var transform = Transform3D.identity
        transform.translation = SIMD3(2, 0, 0)

        // 90° about the world Y axis through (1,0,0): the pivot at (2,0,0)
        // is offset (1,0,0) from the axis, which +Y-rotates onto (0,0,-1).
        let rotated = transform.rotated(
            byRadians: .pi / 2,
            aboutAxisThrough: SIMD3(1, 0, 0),
            direction: SIMD3(0, 1, 0)
        )

        assertEqual(rotated.translation, SIMD3(1, 0, -1),
                    "Rotation about a non-pivot axis must move the translation")
        // The orientation turns too: local +X now points down -Z.
        assertEqual(rotated.rotation.act(SIMD3(1, 0, 0)), SIMD3(0, 0, -1))
        XCTAssertEqual(rotated.scale, 1, accuracy: 1e-12)
    }

    func testRotationAboutAxisThroughPivotKeepsTranslation() {
        var transform = Transform3D.identity
        transform.translation = SIMD3(3, 2, -1)

        let rotated = transform.rotated(
            byRadians: 0.7,
            aboutAxisThrough: SIMD3(3, 2, -1),
            direction: SIMD3(0, 0, 5) // non-unit on purpose
        )

        assertEqual(rotated.translation, transform.translation,
                    "An axis through the pivot must not translate the body")
    }

    func testRotationRoundTripRestoresTransform() {
        var transform = Transform3D.identity
        transform.translation = SIMD3(1, 2, 3)
        transform.rotation = simd_quatd(angle: 0.4, axis: simd_normalize(SIMD3(1, 1, 0)))
        transform.scale = 2

        let axisPoint = SIMD3(-1.0, 0.5, 2.0)
        let axisDirection = simd_normalize(SIMD3(0.3, -1.0, 0.2))
        let there = transform.rotated(
            byRadians: 1.1, aboutAxisThrough: axisPoint, direction: axisDirection
        )
        let back = there.rotated(
            byRadians: -1.1, aboutAxisThrough: axisPoint, direction: axisDirection
        )

        assertEqual(back.translation, transform.translation)
        XCTAssertEqual(back.scale, transform.scale, accuracy: 1e-12)
        // Compare rotations by their action on basis vectors (sign-agnostic).
        assertEqual(back.rotation.act(SIMD3(1, 0, 0)), transform.rotation.act(SIMD3(1, 0, 0)))
        assertEqual(back.rotation.act(SIMD3(0, 1, 0)), transform.rotation.act(SIMD3(0, 1, 0)))
    }

    func testDegenerateAxisDirectionReturnsSelf() {
        var transform = Transform3D.identity
        transform.translation = SIMD3(1, 1, 1)
        let rotated = transform.rotated(
            byRadians: 1, aboutAxisThrough: .zero, direction: .zero
        )
        XCTAssertEqual(rotated, transform)
    }

    // MARK: - ProfileDetector.connectedEntityIDs (double-tap chain select)

    func testConnectedChainWalksSharedEndpoints() {
        let l1 = SketchEntity.line(id: UUID(), a: SIMD2(0, 0), b: SIMD2(1, 0))
        let l2 = SketchEntity.line(id: UUID(), a: SIMD2(1, 0), b: SIMD2(1, 1))
        let l3 = SketchEntity.line(id: UUID(), a: SIMD2(1, 1), b: SIMD2(0, 1))
        let island = SketchEntity.line(id: UUID(), a: SIMD2(5, 5), b: SIMD2(6, 5))
        let circle = SketchEntity.circle(id: UUID(), center: SIMD2(3, 3), radius: 1)
        let entities = [l1, l2, l3, island, circle]

        let chain = ProfileDetector.connectedEntityIDs(from: l1.id, in: entities)
        XCTAssertEqual(chain, [l1.id, l2.id, l3.id],
                       "The chain must include every endpoint-connected entity and nothing else")

        XCTAssertEqual(
            ProfileDetector.connectedEntityIDs(from: island.id, in: entities),
            [island.id],
            "A disconnected line is its own island"
        )
        XCTAssertEqual(
            ProfileDetector.connectedEntityIDs(from: circle.id, in: entities),
            [circle.id],
            "Closed entities have no endpoints to chain through"
        )
    }

    func testConnectedChainIncludesArcsJoinedAtEndpoints() {
        // Arc from (1,0) to (0,1) about the origin (radius 1) meets a line
        // that starts exactly at the arc's start point.
        let arc = SketchEntity.arc(
            id: UUID(), center: SIMD2(0, 0), radius: 1, startAngle: 0, endAngle: .pi / 2
        )
        let line = SketchEntity.line(id: UUID(), a: SIMD2(1, 0), b: SIMD2(2, 0))
        let far = SketchEntity.line(id: UUID(), a: SIMD2(9, 9), b: SIMD2(10, 9))

        let chain = ProfileDetector.connectedEntityIDs(from: line.id, in: [arc, line, far])
        XCTAssertEqual(chain, [arc.id, line.id],
                       "Arcs chain through their endpoints")
    }

    // MARK: - Undo titles (tranche polish: every transform tool names its step)

    func testTransformBodiesCommandTitleDefaultsToMoveAndAcceptsOverrides() {
        XCTAssertEqual(TransformBodiesCommand(before: [:], after: [:]).title, "Move")
        for title in ["Scale", "Rotate", "Translate", "Align"] {
            XCTAssertEqual(
                TransformBodiesCommand(title: title, before: [:], after: [:]).title,
                title,
                "Transform tools pass their own undo title"
            )
        }
    }
}
