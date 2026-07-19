//
//  IO2Tests.swift
//  openshape3dTests
//
//  Interchange breadth (plan B14 kernel half): GLB structural validation,
//  DXF export → import round-trips, malformed-DXF resilience, and a
//  no-crash/if-supported check for USDZ via ModelIO.
//

import XCTest
import simd
@testable import openshape3d

final class IO2Tests: XCTestCase {

    private func makeBox(size: Double = 2, at x: Double = 0, name: String = "Box") -> Body {
        var transform = Transform3D.identity
        transform.translation = SIMD3(x, 0, 0)
        return Body(
            name: name,
            transform: transform,
            primitive: .box(width: size, depth: size, height: size),
            euclidMesh: .primitive(.box(width: size, depth: size, height: size)),
            revision: 1
        )
    }

    // MARK: - GLB

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    func testGLBContainerAndJSONStructure() throws {
        let a = makeBox(name: "A")
        let b = makeBox(at: 10, name: "B")
        let glb = GLBExporter.glb(bodies: [a, b])

        // Container header.
        XCTAssertEqual(u32(glb, 0), 0x46546C67, "glTF magic")
        XCTAssertEqual(u32(glb, 4), 2, "container version")
        XCTAssertEqual(Int(u32(glb, 8)), glb.count, "declared total length")

        // JSON chunk.
        let jsonLength = Int(u32(glb, 12))
        XCTAssertEqual(u32(glb, 16), 0x4E4F534A, "JSON chunk type")
        XCTAssertEqual(jsonLength % 4, 0, "JSON chunk padded to 4 bytes")
        let jsonData = glb.subdata(in: 20..<(20 + jsonLength))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        )

        // BIN chunk directly follows and closes the file.
        let binHeader = 20 + jsonLength
        let binLength = Int(u32(glb, binHeader))
        XCTAssertEqual(u32(glb, binHeader + 4), 0x004E4942, "BIN chunk type")
        XCTAssertEqual(binHeader + 8 + binLength, glb.count)
        XCTAssertEqual(binLength % 4, 0, "BIN chunk padded to 4 bytes")

        // Asset / scene graph.
        let asset = try XCTUnwrap(json["asset"] as? [String: Any])
        XCTAssertEqual(asset["version"] as? String, "2.0")
        let scenes = try XCTUnwrap(json["scenes"] as? [[String: Any]])
        XCTAssertEqual(scenes.count, 1)
        XCTAssertEqual(try XCTUnwrap(scenes[0]["nodes"] as? [Int]), [0, 1])
        XCTAssertEqual(json["scene"] as? Int, 0)
        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.map { $0["name"] as? String }, ["A", "B"])
        XCTAssertEqual(nodes.map { $0["mesh"] as? Int }, [0, 1])

        // Meshes reference accessors that match the source buffers.
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        XCTAssertEqual(meshes.count, 2)
        XCTAssertEqual(accessors.count, 6, "position/normal/index accessor per body")
        for (index, body) in [a, b].enumerated() {
            let primitives = try XCTUnwrap(meshes[index]["primitives"] as? [[String: Any]])
            XCTAssertEqual(primitives.count, 1)
            let primitive = primitives[0]
            XCTAssertEqual(primitive["mode"] as? Int, 4)
            XCTAssertEqual(primitive["material"] as? Int, 0)
            let attributes = try XCTUnwrap(primitive["attributes"] as? [String: Int])
            let position = accessors[try XCTUnwrap(attributes["POSITION"])]
            let normal = accessors[try XCTUnwrap(attributes["NORMAL"])]
            let indices = accessors[try XCTUnwrap(primitive["indices"] as? Int)]
            XCTAssertEqual(position["count"] as? Int, body.render.positions.count)
            XCTAssertEqual(position["type"] as? String, "VEC3")
            XCTAssertEqual(position["componentType"] as? Int, 5126)
            XCTAssertEqual(try XCTUnwrap(position["min"] as? [Double]).count, 3)
            XCTAssertEqual(try XCTUnwrap(position["max"] as? [Double]).count, 3)
            XCTAssertEqual(normal["count"] as? Int, body.render.normals.count)
            XCTAssertEqual(indices["count"] as? Int, body.render.indices.count)
            XCTAssertEqual(indices["componentType"] as? Int, 5125)
            XCTAssertEqual(indices["type"] as? String, "SCALAR")
        }

        // BufferViews: aligned, in-bounds, non-overlapping is implied by size sum.
        let bufferViews = try XCTUnwrap(json["bufferViews"] as? [[String: Any]])
        XCTAssertEqual(bufferViews.count, 6)
        for view in bufferViews {
            let offset = try XCTUnwrap(view["byteOffset"] as? Int)
            let length = try XCTUnwrap(view["byteLength"] as? Int)
            XCTAssertEqual(offset % 4, 0, "bufferView byteOffset 4-byte aligned")
            XCTAssertLessThanOrEqual(offset + length, binLength)
            XCTAssertEqual(view["buffer"] as? Int, 0)
        }

        let buffers = try XCTUnwrap(json["buffers"] as? [[String: Any]])
        XCTAssertEqual(buffers.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(buffers[0]["byteLength"] as? Int), binLength)

        // Material with pbrMetallicRoughness baseColor.
        let materials = try XCTUnwrap(json["materials"] as? [[String: Any]])
        let pbr = try XCTUnwrap(materials[0]["pbrMetallicRoughness"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(pbr["baseColorFactor"] as? [Double]).count, 4)
    }

    func testGLBBakesWorldTransform() throws {
        let body = makeBox(size: 2, at: 10)
        let glb = GLBExporter.glb(bodies: [body])
        let jsonLength = Int(u32(glb, 12))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: glb.subdata(in: 20..<(20 + jsonLength)))
                as? [String: Any]
        )
        let accessors = try XCTUnwrap(json["accessors"] as? [[String: Any]])
        let position = try XCTUnwrap(
            accessors.first { ($0["type"] as? String) == "VEC3" && $0["min"] != nil }
        )
        let minX = try XCTUnwrap(position["min"] as? [Double])[0]
        let maxX = try XCTUnwrap(position["max"] as? [Double])[0]
        XCTAssertEqual(minX, 9, accuracy: 1e-4, "x=10 translation baked into positions")
        XCTAssertEqual(maxX, 11, accuracy: 1e-4)
    }

    // MARK: - DXF round-trips

    private func roundTrip(_ entities: [SketchEntity]) -> [SketchEntity] {
        let dxf = DXFKit.exportSketch(entities: entities, plane: .ground)
        return DXFKit.importDXF(Data(dxf.utf8))
    }

    func testDXFLineCircleArcRoundTrip() throws {
        let line = SketchEntity.line(id: UUID(), a: SIMD2(-3, 1.5), b: SIMD2(4, -2.25))
        let circle = SketchEntity.circle(id: UUID(), center: SIMD2(5, -7), radius: 2.5)
        let arc = SketchEntity.arc(
            id: UUID(), center: SIMD2(1, 2), radius: 3,
            startAngle: 0.4, endAngle: 2.1
        )
        let imported = roundTrip([line, circle, arc])
        XCTAssertEqual(imported.count, 3)

        guard case let .line(_, a, b) = imported[0] else { return XCTFail("Expected line") }
        XCTAssertEqual(a.x, -3, accuracy: 1e-6)
        XCTAssertEqual(a.y, 1.5, accuracy: 1e-6)
        XCTAssertEqual(b.x, 4, accuracy: 1e-6)
        XCTAssertEqual(b.y, -2.25, accuracy: 1e-6)

        guard case let .circle(_, center, radius) = imported[1] else {
            return XCTFail("Expected circle")
        }
        XCTAssertEqual(center.x, 5, accuracy: 1e-6)
        XCTAssertEqual(center.y, -7, accuracy: 1e-6)
        XCTAssertEqual(radius, 2.5, accuracy: 1e-6)

        guard case let .arc(_, arcCenter, arcRadius, start, end) = imported[2] else {
            return XCTFail("Expected arc")
        }
        XCTAssertEqual(arcCenter.x, 1, accuracy: 1e-6)
        XCTAssertEqual(arcCenter.y, 2, accuracy: 1e-6)
        XCTAssertEqual(arcRadius, 3, accuracy: 1e-6)
        XCTAssertEqual(start, 0.4, accuracy: 1e-6, "degrees round-trip back to radians")
        XCTAssertEqual(end, 2.1, accuracy: 1e-6)
    }

    func testDXFRectExportsClosedPolylineOfFourLines() throws {
        let rect = SketchEntity.rect(id: UUID(), min: SIMD2(-1, -2), max: SIMD2(3, 4))
        let dxf = DXFKit.exportSketch(entities: [rect], plane: .ground)
        XCTAssertTrue(dxf.contains("POLYLINE"))
        XCTAssertTrue(dxf.contains("SEQEND"))

        let imported = roundTrip([rect])
        XCTAssertEqual(imported.count, 4, "closed 4-vertex polyline becomes 4 line segments")
        var endpoints = Set<SIMD2<Double>>()
        for entity in imported {
            guard case let .line(_, a, b) = entity else { return XCTFail("Expected line") }
            endpoints.insert(a)
            endpoints.insert(b)
        }
        XCTAssertEqual(
            endpoints,
            [SIMD2(-1, -2), SIMD2(3, -2), SIMD2(3, 4), SIMD2(-1, 4)],
            "segments trace the rect corners"
        )
    }

    func testDXFPolygonRoundTripPreservesVertices() throws {
        let polygon = SketchEntity.polygon(
            id: UUID(), center: SIMD2(2, -1), radius: 5, sides: 6, rotation: 0.3
        )
        let imported = roundTrip([polygon])
        XCTAssertEqual(imported.count, 6, "hexagon becomes 6 closed segments")

        let expected = SketchEntity.polygonPoints(
            center: SIMD2(2, -1), radius: 5, sides: 6, rotation: 0.3
        )
        for (i, entity) in imported.enumerated() {
            guard case let .line(_, a, b) = entity else { return XCTFail("Expected line") }
            let expectedA = expected[i]
            let expectedB = expected[(i + 1) % expected.count]
            XCTAssertEqual(a.x, expectedA.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, expectedA.y, accuracy: 1e-6)
            XCTAssertEqual(b.x, expectedB.x, accuracy: 1e-6)
            XCTAssertEqual(b.y, expectedB.y, accuracy: 1e-6)
        }
    }

    func testDXFEllipseTessellatesToClosedPolyline() throws {
        let ellipse = SketchEntity.ellipse(
            id: UUID(), center: SIMD2(0, 0), radiusX: 4, radiusY: 2, rotation: 0.5
        )
        let imported = roundTrip([ellipse])
        XCTAssertEqual(imported.count, DXFKit.ellipseSegments)

        // Every imported endpoint sits on the exact ellipse (implicit equation).
        for entity in imported {
            guard case let .line(_, a, _) = entity else { return XCTFail("Expected line") }
            let cosR = cos(-0.5)
            let sinR = sin(-0.5)
            let local = SIMD2(a.x * cosR - a.y * sinR, a.x * sinR + a.y * cosR)
            let value = pow(local.x / 4, 2) + pow(local.y / 2, 2)
            XCTAssertEqual(value, 1, accuracy: 1e-6)
        }
    }

    // MARK: - DXF import of foreign files + malformed input

    func testImportsLWPolylineR2000Style() {
        let dxf = """
        0
        SECTION
        2
        ENTITIES
        0
        LWPOLYLINE
        8
        0
        90
        3
        70
        1
        10
        0.0
        20
        0.0
        10
        10.0
        20
        0.0
        10
        10.0
        20
        5.0
        0
        ENDSEC
        0
        EOF
        """
        let imported = DXFKit.importDXF(Data(dxf.utf8))
        XCTAssertEqual(imported.count, 3, "closed 3-vertex LWPOLYLINE yields 3 segments")
    }

    func testImportIgnoresUnknownEntities() {
        let dxf = """
        0
        SECTION
        2
        ENTITIES
        0
        SPLINE
        10
        1.0
        20
        2.0
        0
        MTEXT
        1
        hello
        0
        LINE
        8
        0
        10
        0.0
        20
        0.0
        11
        1.0
        21
        1.0
        0
        ENDSEC
        0
        EOF
        """
        let imported = DXFKit.importDXF(Data(dxf.utf8))
        XCTAssertEqual(imported.count, 1)
        guard case .line = imported[0] else { return XCTFail("Expected line") }
    }

    func testImportOutsideEntitiesSectionIgnored() {
        let dxf = """
        0
        SECTION
        2
        BLOCKS
        0
        LINE
        10
        0.0
        20
        0.0
        11
        1.0
        21
        1.0
        0
        ENDSEC
        0
        EOF
        """
        XCTAssertTrue(DXFKit.importDXF(Data(dxf.utf8)).isEmpty)
    }

    func testMalformedDXFDoesNotCrash() {
        XCTAssertTrue(DXFKit.importDXF(Data()).isEmpty)
        XCTAssertTrue(DXFKit.importDXF(Data([0xFF, 0x00, 0x81, 0x12])).isEmpty)
        XCTAssertTrue(DXFKit.importDXF(Data("not a dxf at all".utf8)).isEmpty)

        // Truncated mid-entity: incomplete LINE is dropped, no crash.
        let truncated = """
        0
        SECTION
        2
        ENTITIES
        0
        LINE
        10
        1.0
        """
        XCTAssertTrue(DXFKit.importDXF(Data(truncated.utf8)).isEmpty)

        // Non-numeric coordinates are skipped gracefully.
        let garbageValues = """
        0
        SECTION
        2
        ENTITIES
        0
        CIRCLE
        10
        abc
        20
        1.0
        40
        2.0
        0
        ENDSEC
        0
        EOF
        """
        XCTAssertTrue(DXFKit.importDXF(Data(garbageValues.utf8)).isEmpty)
    }

    // MARK: - USDZ

    func testUSDZExportNoCrashAndDataWhenSupported() {
        let data = USDZExporter.usdz(bodies: [makeBox()])
        if USDZExporter.isSupported {
            if let data {
                XCTAssertFalse(data.isEmpty, "supported platform produced empty USDZ")
                // USDZ is a zip archive: local file header magic "PK\u{03}\u{04}".
                XCTAssertEqual(data.prefix(2), Data([0x50, 0x4B]))
            }
            // A nil result on a supported platform means export failed at
            // runtime; the exporter contract allows that (UI hides the option).
        } else {
            XCTAssertNil(data, "unsupported platform must return nil, never fake data")
        }
        XCTAssertNil(USDZExporter.usdz(bodies: []), "no bodies yields nil")
    }
}
