//
//  STLExportTests.swift
//  openshape3dTests
//

import XCTest
import simd
@testable import openshape3d

final class STLExportTests: XCTestCase {

    func testBinarySTLLayoutAndTriangleCount() {
        let body = Body(
            name: "Box",
            transform: .identity,
            primitive: .box(width: 2, depth: 2, height: 2),
            euclidMesh: .primitive(.box(width: 2, depth: 2, height: 2)),
            revision: 1
        )
        let data = STLExporter.binarySTL(bodies: [body])

        // Binary STL: 80-byte header + u32 count + 50 bytes per triangle.
        XCTAssertGreaterThan(data.count, 84)
        let count = data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian
        }
        XCTAssertEqual(Int(count), 12, "A box exports 12 triangles")
        XCTAssertEqual(data.count, 84 + Int(count) * 50, "Exact binary STL size")
    }

    func testTransformIsBaked() {
        var transform = Transform3D.identity
        transform.translation = SIMD3(100, 0, 0)
        let body = Body(
            name: "Box",
            transform: transform,
            primitive: .box(width: 2, depth: 2, height: 2),
            euclidMesh: .primitive(.box(width: 2, depth: 2, height: 2)),
            revision: 1
        )
        let data = STLExporter.binarySTL(bodies: [body])

        // First vertex X of the first triangle: header(80) + count(4) +
        // normal(12) → vertex1 at offset 96.
        let x = data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 96, as: Float.self)
        }
        XCTAssertGreaterThan(x, 90, "Translated body should export near x=100")
    }

    func testMultipleBodiesMerge() {
        func makeBody(_ x: Double) -> Body {
            var transform = Transform3D.identity
            transform.translation = SIMD3(x, 0, 0)
            return Body(
                name: "Box",
                transform: transform,
                primitive: .box(width: 1, depth: 1, height: 1),
                euclidMesh: .primitive(.box(width: 1, depth: 1, height: 1)),
                revision: 1
            )
        }
        let data = STLExporter.binarySTL(bodies: [makeBody(0), makeBody(5)])
        let count = data.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self).littleEndian
        }
        XCTAssertEqual(Int(count), 24, "Two boxes export 24 triangles")
    }
}
