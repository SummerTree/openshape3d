//
//  PinnedMeasurementTests.swift
//  openshape3dTests
//
//  Measure (spec §16.3): the 3-Point Angle reading, pinned measurements'
//  values and label anchors, Pin/Unpin as undoable commands, and that pins
//  ride along in the .os3d archive (older archives without them still load).
//

import XCTest
import simd
@testable import openshape3d

final class PinnedMeasurementTests: XCTestCase {

    func testThreePointAngle() throws {
        let right = try XCTUnwrap(MeasureKit.angleDegrees(SIMD3(10, 0, 0), vertex: .zero, SIMD3(0, 0, 10)))
        XCTAssertEqual(right, 90, accuracy: 1e-9)
        let flat = try XCTUnwrap(MeasureKit.angleDegrees(SIMD3(-1, 0, 0), vertex: .zero, SIMD3(1, 0, 0)))
        XCTAssertEqual(flat, 180, accuracy: 1e-9)
        let sixty = try XCTUnwrap(MeasureKit.angleDegrees(SIMD3(1, 0, 0), vertex: .zero, SIMD3(0.5, sqrt(3) / 2, 0)))
        XCTAssertEqual(sixty, 60, accuracy: 1e-9)
        XCTAssertNil(MeasureKit.angleDegrees(.zero, vertex: .zero, SIMD3(1, 0, 0)), "A zero-length arm has no angle")
    }

    func testPinnedValuesAndAnchors() {
        let distance = PinnedMeasurement(kind: .distance, points: [SIMD3(0, 0, 0), SIMD3(3, 4, 0)])
        XCTAssertEqual(distance.value, 5, accuracy: 1e-12)
        XCTAssertEqual(distance.labelAnchor, SIMD3(1.5, 2, 0))
        XCTAssertEqual(distance.segments.count, 2)

        let angle = PinnedMeasurement(kind: .angle, points: [SIMD3(10, 0, 0), .zero, SIMD3(0, 10, 0)])
        XCTAssertEqual(angle.value, 90, accuracy: 1e-9)
        // Inside the angle, on its bisector.
        XCTAssertEqual(angle.labelAnchor.x, angle.labelAnchor.y, accuracy: 1e-9)
        XCTAssertGreaterThan(angle.labelAnchor.x, 0)
        XCTAssertEqual(angle.segments.count, 4)
    }

    func testPinAndUnpinUndo() {
        var document = DesignDocument()
        let a = PinnedMeasurement(kind: .distance, points: [.zero, SIMD3(1, 0, 0)])
        let b = PinnedMeasurement(kind: .angle, points: [SIMD3(1, 0, 0), .zero, SIMD3(0, 1, 0)])
        PinMeasurementCommand(measurement: a).apply(to: &document)
        PinMeasurementCommand(measurement: b).apply(to: &document)
        XCTAssertEqual(document.pinnedMeasurements.map(\.id), [a.id, b.id])

        let unpin = UnpinMeasurementCommand(measurement: a, index: 0)
        unpin.apply(to: &document)
        XCTAssertEqual(document.pinnedMeasurements.map(\.id), [b.id])
        unpin.revert(in: &document)
        XCTAssertEqual(document.pinnedMeasurements.map(\.id), [a.id, b.id], "Undo puts it back in place")
    }

    func testPinsTravelInTheArchive() throws {
        let pins = [PinnedMeasurement(kind: .distance, points: [.zero, SIMD3(0, 0, 25)])]
        var archive = ProjectArchive(name: "Pins")
        archive.pinnedMeasurements = try JSONEncoder().encode(pins)
        let data = try XCTUnwrap(archive.encoded())
        let decoded = try XCTUnwrap(ProjectArchive.decode(data))
        let back = try JSONDecoder().decode([PinnedMeasurement].self, from: XCTUnwrap(decoded.pinnedMeasurements))
        XCTAssertEqual(back, pins)

        // An archive written before pins existed has no such key.
        let old = try XCTUnwrap(ProjectArchive(name: "Old").encoded())
        XCTAssertNil(try XCTUnwrap(ProjectArchive.decode(old)).pinnedMeasurements)
    }
}
