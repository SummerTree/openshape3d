//
//  CameraTests.swift
//  openshape3dTests
//
//  A7: orthographic projection, standard-view poses, and orientation-cube
//  hit-testing.
//

import XCTest
import simd
@testable import openshape3d

@MainActor
final class CameraTests: XCTestCase {

    private let viewport = CGSize(width: 1024, height: 768)

    // MARK: - Orthographic projection

    func testOrthographicRaysAreParallel() {
        var camera = TurntableCamera()
        camera.projection = .orthographic

        let a = camera.ray(through: CGPoint(x: 100, y: 100), viewportSize: viewport)
        let b = camera.ray(through: CGPoint(x: 900, y: 700), viewportSize: viewport)

        // Parallel directions, distinct origins (rays slide on the near plane).
        XCTAssertGreaterThan(simd_dot(a.direction, b.direction), 0.9999)
        XCTAssertGreaterThan(simd_length(a.origin - b.origin), 0.1)
    }

    func testPerspectiveRaysDiverge() {
        let camera = TurntableCamera()
        let a = camera.ray(through: CGPoint(x: 100, y: 100), viewportSize: viewport)
        let b = camera.ray(through: CGPoint(x: 900, y: 700), viewportSize: viewport)
        XCTAssertLessThan(simd_dot(a.direction, b.direction), 0.999)
    }

    func testOrthographicCenterRayHitsTarget() {
        var camera = TurntableCamera()
        camera.target = SIMD3(1, 2, 3)
        camera.projection = .orthographic

        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let ray = camera.ray(through: center, viewportSize: viewport)
        // The central ray runs down the view axis through the target.
        let toTarget = camera.target - ray.origin
        let along = simd_dot(toTarget, ray.direction)
        let miss = simd_length(toTarget - ray.direction * along)
        XCTAssertLessThan(miss, 1e-2)
        XCTAssertGreaterThan(along, 0)
    }

    func testOrthographicMatchesPerspectiveScaleAtTarget() {
        var camera = TurntableCamera()
        camera.elevation = 0
        camera.projection = .orthographic
        let aspect = Float(viewport.width / viewport.height)
        let projection = camera.projectionMatrix(aspect: aspect)
        // A point at the target depth, one frustum-half-height up, lands at
        // NDC y = 1 — same as the perspective frustum at that depth.
        let halfHeight = camera.distance * tan(camera.fovY * 0.5)
        let view = camera.viewMatrix
        let world = camera.target + SIMD3(0, halfHeight, 0)
        let eye = view * SIMD4(world, 1)
        var clip = projection * eye
        clip /= clip.w
        XCTAssertEqual(clip.y, 1, accuracy: 1e-3)
    }

    // MARK: - Standard views

    func testStandardViewPoses() {
        let camera = TurntableCamera()

        let front = StandardView.front.applied(to: camera)
        XCTAssertEqual(front.azimuth, 0, accuracy: 1e-6)
        XCTAssertEqual(front.elevation, 0, accuracy: 1e-6)

        let right = StandardView.right.applied(to: camera)
        XCTAssertEqual(right.azimuth, .pi / 2, accuracy: 1e-6)

        // Top/bottom stop at the ±89° clamp (1° off a true plan view) and
        // square the azimuth to the nearest quadrant (the default 36° → 0).
        let top = StandardView.top.applied(to: camera)
        XCTAssertEqual(top.elevation, TurntableCamera.elevationLimit, accuracy: 1e-6)
        XCTAssertEqual(top.azimuth, StandardView.nearestQuadrant(camera.azimuth), accuracy: 1e-6)
        let bottom = StandardView.bottom.applied(to: camera)
        XCTAssertEqual(bottom.elevation, -TurntableCamera.elevationLimit, accuracy: 1e-6)

        let iso = StandardView.isometric.applied(to: camera)
        XCTAssertEqual(iso.azimuth, .pi / 5, accuracy: 1e-6)
        XCTAssertEqual(iso.elevation, .pi / 7, accuracy: 1e-6)

        // Pose keeps target/distance/projection.
        XCTAssertEqual(front.target, camera.target)
        XCTAssertEqual(front.distance, camera.distance)
        XCTAssertEqual(front.projection, camera.projection)
    }

    // MARK: - Orientation cube

    func testCubeTapOutsideRectMisses() {
        let camera = TurntableCamera()
        XCTAssertNil(OrientationCube.hitPose(
            at: CGPoint(x: 10, y: 10), camera: camera, viewSize: viewport
        ))
    }

    func testCubeCenterTapFromFrontHitsFrontFace() {
        var camera = TurntableCamera()
        camera.azimuth = 0
        camera.elevation = 0

        let rect = OrientationCube.rect(in: viewport)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let pose = OrientationCube.hitPose(at: center, camera: camera, viewSize: viewport)
        XCTAssertNotNil(pose)
        // Head-on already: the +Z face keeps the pose.
        XCTAssertEqual(pose?.azimuth ?? -1, 0, accuracy: 1e-4)
        XCTAssertEqual(pose?.elevation ?? -1, 0, accuracy: 1e-4)
    }

    func testCubeCornerTapSnapsToCornerView() {
        var camera = TurntableCamera()
        camera.azimuth = 0
        camera.elevation = 0

        // From the front view the top-right cube corner (+1,+1,+1) projects
        // toward the rect's top-right; probe a diagonal offset inside the
        // corner zone (|x|,|y| ≈ 0.8 of the half extent on the +Z face).
        let rect = OrientationCube.rect(in: viewport)
        let point = CGPoint(
            x: rect.midX + rect.width * 0.23,
            y: rect.midY - rect.height * 0.23
        )
        guard let pose = OrientationCube.hitPose(at: point, camera: camera, viewSize: viewport) else {
            return XCTFail("Corner tap should hit the cube")
        }
        let cornerElevation = asin(1 / sqrt(3.0))
        XCTAssertEqual(Double(pose.elevation), cornerElevation, accuracy: 1e-3)
        XCTAssertEqual(pose.azimuth, .pi / 4, accuracy: 1e-3)
    }

    func testCubeHitPoseIsIdempotent() {
        // Snapping to a face, then tapping the cube center again, returns the
        // same pose (the face is now head-on).
        var camera = TurntableCamera() // default iso-ish pose
        let rect = OrientationCube.rect(in: viewport)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let first = OrientationCube.hitPose(at: center, camera: camera, viewSize: viewport) else {
            return XCTFail("Center tap should hit the cube")
        }
        camera = first
        guard let second = OrientationCube.hitPose(at: center, camera: camera, viewSize: viewport) else {
            return XCTFail("Center tap should hit the cube after snapping")
        }
        XCTAssertEqual(second.azimuth, first.azimuth, accuracy: 1e-3)
        XCTAssertEqual(second.elevation, first.elevation, accuracy: 1e-3)
    }

    func testCubeSlabIntersection() {
        // Straight-on hit.
        let hit = OrientationCube.intersectCube(
            origin: SIMD3(0, 0, 4), direction: SIMD3(0, 0, -1)
        )
        XCTAssertEqual(hit?.z ?? 0, OrientationCube.halfExtent, accuracy: 1e-5)
        // Miss outside the slab.
        XCTAssertNil(OrientationCube.intersectCube(
            origin: SIMD3(3, 0, 4), direction: SIMD3(0, 0, -1)
        ))
    }

    // MARK: - Plan views end upright

    func testTopViewSquaresTheAzimuthToTheNearestQuadrant() {
        var cam = TurntableCamera()
        cam.azimuth = 36 * .pi / 180          // a stray orbit left the view rolled
        let top = StandardView.top.applied(to: cam)
        XCTAssertEqual(top.azimuth, 0, accuracy: 1e-6)
        XCTAssertEqual(top.elevation, TurntableCamera.elevationLimit, accuracy: 1e-6)
        cam.azimuth = 130 * .pi / 180
        XCTAssertEqual(StandardView.bottom.applied(to: cam).azimuth, .pi / 2, accuracy: 1e-6)
        cam.azimuth = -100 * .pi / 180
        XCTAssertEqual(StandardView.top.applied(to: cam).azimuth, -.pi / 2, accuracy: 1e-6)
    }
}
