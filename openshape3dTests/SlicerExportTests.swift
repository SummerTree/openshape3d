//
//  SlicerExportTests.swift
//  openshape3dTests
//
//  File ▸ Export to Slicer: the 3MF stands Z-up on the bed — lowest point on
//  z = 0, centred in x and y — whatever the design's own placement, and the
//  design itself is left alone.
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class SlicerExportTests: XCTestCase {

    private func box(width: Double, depth: Double, height: Double, at offset: SIMD3<Double>) -> Body {
        var transform = Transform3D()
        transform.translation = offset
        return Body(name: "Box", transform: transform,
                    euclidMesh: .primitive(.box(width: width, depth: depth, height: height)), revision: 1)
    }

    func testBodiesStandOnTheBedZUp() throws {
        // 10 wide (x), 20 deep (z), 4 tall (y), floating off to the side.
        let body = box(width: 10, depth: 20, height: 4, at: SIMD3(100, 5, -30))
        let placed = SlicerExport.placedOnBed([body])
        let b = try XCTUnwrap(SlicerExport.worldBounds(placed))
        XCTAssertEqual(b.min.z, 0, accuracy: 1e-6, "sits on the bed")
        XCTAssertEqual(b.max.z, 4, accuracy: 1e-6, "the app's height is the printer's Z")
        XCTAssertEqual(b.max.x - b.min.x, 10, accuracy: 1e-6)
        XCTAssertEqual(b.max.y - b.min.y, 20, accuracy: 1e-6, "the app's depth is the printer's Y")
        XCTAssertEqual(b.min.x + b.max.x, 0, accuracy: 1e-6, "centred")
        XCTAssertEqual(b.min.y + b.max.y, 0, accuracy: 1e-6)
        XCTAssertEqual(body.transform.translation, SIMD3(100, 5, -30), "the design is untouched")
    }

    func testSeveralBodiesKeepTheirArrangement() throws {
        let a = box(width: 4, depth: 4, height: 4, at: SIMD3(0, 0, 0))
        let b = box(width: 4, depth: 4, height: 8, at: SIMD3(20, 2, 0))
        let placed = SlicerExport.placedOnBed([a, b])
        let both = try XCTUnwrap(SlicerExport.worldBounds(placed))
        let first = try XCTUnwrap(SlicerExport.worldBounds([placed[0]]))
        let second = try XCTUnwrap(SlicerExport.worldBounds([placed[1]]))
        XCTAssertEqual(both.min.z, 0, accuracy: 1e-6)
        XCTAssertEqual(first.min.z, 0, accuracy: 1e-6, "the lower part sits on the bed")
        XCTAssertEqual(second.min.z, 2, accuracy: 1e-6, "the raised part keeps its 2 mm lift")
        XCTAssertEqual(second.min.x - first.min.x, 20, accuracy: 1e-6, "and its spacing")
    }

    func testThreeMFIsMillimetresOnTheBed() throws {
        let data = SlicerExport.threeMF(bodies: [box(width: 10, depth: 10, height: 6, at: SIMD3(0, -3, 0))])
        XCTAssertEqual(data.prefix(2), Data("PK".utf8), "a zip package")
        let xml = ThreeMFExporter.modelXML(bodies: SlicerExport.placedOnBed(
            [box(width: 10, depth: 10, height: 6, at: SIMD3(0, -3, 0))]))
        XCTAssertTrue(xml.contains("unit=\"millimeter\""))
        let zs = xml.components(separatedBy: "z=\"").dropFirst().compactMap { Double($0.prefix { $0 != "\"" }) }
        XCTAssertFalse(zs.isEmpty)
        XCTAssertEqual(zs.min() ?? -1, 0, accuracy: 1e-5)
        XCTAssertEqual(zs.max() ?? -1, 6, accuracy: 1e-5)
    }

    func testFileNameIsPathSafe() {
        XCTAssertEqual(SlicerExport.fileName(for: "Bracket v2"), "Bracket v2.3mf")
        XCTAssertEqual(SlicerExport.fileName(for: "a/b:c"), "a-b-c.3mf")
        XCTAssertEqual(SlicerExport.fileName(for: "  "), "Design.3mf")
    }
}
