//
//  MeshUnitPromptTests.swift
//  openshape3dTests
//
//  The import units prompt's model: unit table, nearest-unit mapping,
//  parsing, the probe's detection for unit-less files, size descriptions,
//  and that `parts(unitScale:)` is exactly probe + scale.
//

import XCTest
@testable import openshape3d

final class MeshUnitPromptTests: XCTestCase {

    private func cubeOBJ(size: Double) -> Data {
        let s = size
        return Data("""
        v 0 0 0
        v \(s) 0 0
        v \(s) \(s) 0
        v 0 \(s) 0
        v 0 0 \(s)
        v \(s) 0 \(s)
        v \(s) \(s) \(s)
        v 0 \(s) \(s)
        f 1 4 3 2
        f 5 6 7 8
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f 4 1 5 8
        """.utf8)
    }

    func testUnitTableAndMapping() {
        XCTAssertEqual(MeshImportUnit.allCases.map(\.millimetresPerUnit), [1, 10, 1000, 25.4, 304.8])
        XCTAssertEqual(MeshImportUnit.nearest(toScale: 1), .millimetres)
        XCTAssertEqual(MeshImportUnit.nearest(toScale: 10), .centimetres)
        XCTAssertEqual(MeshImportUnit.nearest(toScale: 1000), .metres)
        XCTAssertEqual(MeshImportUnit.nearest(toScale: 25.4), .inches)
        XCTAssertEqual(MeshImportUnit.nearest(toScale: 304.8), .feet)
        XCTAssertEqual(MeshImportUnit.nearest(toScale: 3), .millimetres, "ratio 3 vs 3.3: mm wins")
        XCTAssertEqual(MeshImportUnit.nearest(toScale: 0), .millimetres)
        XCTAssertEqual(MeshImportUnit.parse("m"), .metres)
        XCTAssertEqual(MeshImportUnit.parse(" Inches "), .inches)
        XCTAssertEqual(MeshImportUnit.parse("millimeters"), .millimetres)
        XCTAssertNil(MeshImportUnit.parse("furlongs"))
    }

    func testProbeDetectsMetresForSmallUnitlessModels() throws {
        let scan = try MeshImportKit.probe(data: cubeOBJ(size: 4.7), fileName: "scan.obj")
        XCTAssertEqual(scan.format, "OBJ")
        XCTAssertFalse(scan.unitIsDeclared)
        XCTAssertEqual(scan.detectedScale, 1000)
        XCTAssertEqual(scan.detectedUnit, .metres)
        XCTAssertEqual(scan.triangleCount, 12)
        XCTAssertEqual(scan.rawExtent.x, 4.7, accuracy: 1e-5, "parts stay in file units")
        XCTAssertEqual(scan.sizeDescription(for: .metres), "4.70 × 4.70 × 4.70 m")
        XCTAssertEqual(scan.sizeDescription(for: .millimetres), "4.70 × 4.70 × 4.70 mm")
        XCTAssertEqual(scan.sizeDescription(for: .centimetres), "47.00 × 47.00 × 47.00 mm")
        XCTAssertEqual(scan.sizeDescription(for: .inches), "119.38 × 119.38 × 119.38 mm")
        XCTAssertTrue(scan.unitNote.contains("don't record a unit"))

        let part = try MeshImportKit.probe(data: cubeOBJ(size: 25), fileName: "part.obj")
        XCTAssertEqual(part.detectedUnit, .millimetres)
        XCTAssertEqual(part.sizeDescription(for: .feet), "7.62 × 7.62 × 7.62 m")
    }

    func testScaledAndPartsAgree() throws {
        let probe = try MeshImportKit.probe(data: cubeOBJ(size: 4.7), fileName: "scan.obj")
        let inches = MeshImportKit.scaled(probe.parts, by: MeshImportUnit.inches.millimetresPerUnit)
        XCTAssertEqual(inches[0].mesh.localAABB.max.x, Float(4.7 * 25.4), accuracy: 1e-3)
        XCTAssertEqual(MeshImportKit.scaled(probe.parts, by: 1)[0].mesh.positions,
                       probe.parts[0].mesh.positions, "scale 1 is a no-op")

        let auto = try MeshImportKit.parts(from: cubeOBJ(size: 4.7), fileName: "scan.obj")
        XCTAssertEqual(auto[0].mesh.localAABB.max.x, 4700, accuracy: 1e-2,
                       "parts(unitScale: nil) applies the detected scale")
        let forced = try MeshImportKit.parts(from: cubeOBJ(size: 4.7), fileName: "scan.obj", unitScale: 10)
        XCTAssertEqual(forced[0].mesh.localAABB.max.x, 47, accuracy: 1e-4)
    }

    func testZipProbeKeepsTheArchiveName() throws {
        let zip = ZipWriterForTests.archive([("scan/textured_output.obj", cubeOBJ(size: 4.7))])
        let probe = try MeshImportKit.probe(data: zip, fileName: "Untitled_Scan.zip")
        XCTAssertEqual(probe.fileName, "Untitled_Scan.zip")
        XCTAssertEqual(probe.format, "OBJ")
        XCTAssertEqual(probe.detectedUnit, .metres)
    }

    func testProbeRejectsUnknownAndEmpty() {
        XCTAssertThrowsError(try MeshImportKit.probe(data: Data("x".utf8), fileName: "thing.xyz")) {
            XCTAssertEqual($0 as? MeshImportError, .unsupportedFormat("xyz"))
        }
        XCTAssertThrowsError(try MeshImportKit.probe(data: Data("v 0 0 0\n".utf8), fileName: "empty.obj")) {
            XCTAssertEqual($0 as? MeshImportError, .empty)
        }
    }
}
