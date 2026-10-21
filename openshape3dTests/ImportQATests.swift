//
//  ImportQATests.swift
//  openshape3dTests
//
//  The CAD test pack (docs/qa/shapr3d-parity), run offline through the
//  importers themselves: every STEP, STL and DXF fixture is held to its
//  manifest — solids, volume, bounds, validity, and what a negative input
//  must do. This is the fast half of the import QA loop; the live half
//  (tools/import_qa.py) drives the app over MCP and adds the STEP round
//  trip, deviation and the agent-facing replies. Fixtures live in the repo
//  and are read off the host filesystem like Fixtures/Captures (see
//  KernelCaptureReplayTests for why).
//

import XCTest
import simd
import Euclid
@testable import openshape3d

final class ImportQATests: XCTestCase {

    private static let pack = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("docs/qa/shapr3d-parity", isDirectory: true)
    private static let fixtures = pack.appendingPathComponent("fixtures", isDirectory: true)

    private func manifest() throws -> [[String: Any]] {
        let data = try Data(contentsOf: Self.pack.appendingPathComponent("fixture_manifest.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["files"] as? [[String: Any]])
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
    }

    // MARK: STEP

    func testEveryStepFixtureImportsToItsManifest() throws {
        var checked = 0
        for entry in try manifest() {
            let name = try XCTUnwrap(entry["file"] as? String)
            guard name.hasSuffix(".step") || name.hasSuffix(".igs") else { continue }
            checked += 1
            let read = STEPKit.read(from: try fixture(name), format: name.hasSuffix(".igs") ? .iges : .step)
            if (entry["valid_reference"] as? Bool) == false {
                XCTAssertTrue(read.solids.isEmpty, "\(name): a negative fixture must import nothing")
                continue
            }
            let expectedSolids = entry["solid_count"] as? Int ?? 0
            let expectedSheets = entry["sheet_bodies"] as? Int ?? 0
            let solids = read.solids.filter { OCCTKernel.solidCount($0) > 0 }
            XCTAssertEqual(solids.count, expectedSolids, "\(name): solid bodies")
            XCTAssertEqual(read.solids.count - solids.count, expectedSheets, "\(name): sheet bodies")

            let expectedVolume = entry["expected_aggregate_volume_mm3"] as? Double ?? 0
            let volume = solids.reduce(0.0) { $0 + OCCTKernel.volume($1) }
            XCTAssertEqual(volume, expectedVolume, accuracy: max(0.001, 1e-5 * expectedVolume),
                           "\(name): volume (TEST_PLAN §3 gate)")

            if let lo = entry["bounds_min_mm"] as? [Double], let hi = entry["bounds_max_mm"] as? [Double],
               !read.solids.isEmpty {
                var lowest = SIMD3<Double>(repeating: .infinity)
                var highest = SIMD3<Double>(repeating: -.infinity)
                for handle in read.solids {
                    guard let bounds = OCCTKernel.bounds(handle) else { continue }
                    lowest = simd_min(lowest, bounds.min)
                    highest = simd_max(highest, bounds.max)
                }
                for axis in 0..<3 {
                    XCTAssertEqual(lowest[axis], lo[axis], accuracy: 0.01, "\(name): bounds min[\(axis)]")
                    XCTAssertEqual(highest[axis], hi[axis], accuracy: 0.01, "\(name): bounds max[\(axis)]")
                }
            }
            for handle in solids {
                XCTAssertTrue(OCCTKernel.healthReport(for: handle).isValid, "\(name): BRepCheck")
            }
            if (entry["expect_notice"] as? Bool) == true {
                XCTAssertFalse(read.summary.notice.isEmpty, "\(name): the import must say what it did")
            } else {
                XCTAssertTrue(read.summary.notice.isEmpty, "\(name): unexpected notice: \(read.summary.notice)")
            }
            // Every imported shape must become a body: tessellation cannot fail
            // on geometry OCCT just validated.
            for handle in read.solids {
                XCTAssertNotNil(STEPKit.body(from: handle, name: name, revision: 1), "\(name): adoptBRep")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 20, "the pack's STEP fixtures were not found at \(Self.fixtures.path)")
    }

    func testShellOnlyStepIsStitchedIntoASolidAndSaysSo() throws {
        let read = STEPKit.read(from: try fixture("M17_shell_only_box.step"))
        XCTAssertEqual(read.summary.solids, 0)
        XCTAssertEqual(read.summary.freeFaces, 6)
        XCTAssertEqual(read.summary.sewnSolids, 1)
        XCTAssertEqual(read.summary.openShells, 0)
        XCTAssertEqual(read.solids.count, 1)
        XCTAssertEqual(OCCTKernel.volume(read.solids[0]), 12000, accuracy: 1e-6, "a stitched shell must be oriented outward")
        XCTAssertTrue(read.summary.notice.contains("Stitched 6 loose faces into 1 solid"), read.summary.notice)
    }

    func testShellOnlyIGESIsStitchedIntoTheSameSolid() throws {
        // The usual IGES: every face a trimmed surface, no shell, no solid.
        // It goes through the same collector as STEP and comes out the same.
        let read = STEPKit.read(from: try fixture("M17_shell_only_box.igs"), format: .iges)
        XCTAssertEqual(read.summary.freeFaces, 6)
        XCTAssertEqual(read.summary.sewnSolids, 1)
        XCTAssertEqual(read.summary.openShells, 0)
        XCTAssertEqual(read.solids.count, 1)
        XCTAssertEqual(OCCTKernel.volume(read.solids[0]), 12000, accuracy: 1e-6)
        XCTAssertTrue(read.summary.notice.contains("Stitched 6 loose faces into 1 solid"), read.summary.notice)
    }

    func testSolidBesideALooseShellKeepsBoth() throws {
        let read = STEPKit.read(from: try fixture("M18_solid_and_free_shell.step"))
        XCTAssertEqual(read.summary.solids, 1)
        XCTAssertEqual(read.summary.sewnSolids, 1)
        XCTAssertEqual(read.solids.count, 2)
        XCTAssertEqual(read.solids.reduce(0.0) { $0 + OCCTKernel.volume($1) }, 2000, accuracy: 1e-6)
    }

    func testOpenSheetImportsAsASheetBodyWithZeroVolume() throws {
        let read = STEPKit.read(from: try fixture("M19_open_sheet.step"))
        XCTAssertEqual(read.summary.openShells, 1)
        XCTAssertEqual(read.summary.sewnSolids, 0)
        XCTAssertEqual(read.solids.count, 1)
        XCTAssertEqual(OCCTKernel.solidCount(read.solids[0]), 0)
        let body = try XCTUnwrap(STEPKit.body(from: read.solids[0], name: "sheet", revision: 1))
        XCTAssertEqual(MeasureKit.volume(of: body), 0, "a sheet encloses nothing; no face integral, no mesh guess")
        XCTAssertTrue(read.summary.notice.contains("open surface"), read.summary.notice)
    }

    // MARK: STL

    func testEveryStlFixtureImportsAsAClosedMeshWithinMeshGates() throws {
        for entry in try manifest() {
            let name = try XCTUnwrap(entry["file"] as? String)
            guard name.hasSuffix(".stl") else { continue }
            let data = try fixture(name)
            if (entry["valid_reference"] as? Bool) == false {
                if name.contains("open_triangle") {
                    let parts = try MeshImportKit.parts(from: data, fileName: name, unitScale: 1)
                    XCTAssertEqual(parts.count, 1)
                    XCTAssertEqual(MeshIntegrity.openEdgeCount(parts[0].mesh), 3, "\(name): a lone triangle has three boundary edges")
                } else {
                    XCTAssertThrowsError(try MeshImportKit.parts(from: data, fileName: name, unitScale: 1), "\(name): must be refused")
                }
                continue
            }
            let parts = try MeshImportKit.parts(from: data, fileName: name, unitScale: 1)
            XCTAssertEqual(parts.count, 1, name)
            let mesh = parts[0].mesh
            XCTAssertEqual(MeshIntegrity.openEdgeCount(mesh), 0, "\(name): watertight")
            let body = Body(id: BodyID(), name: name, transform: .identity, primitive: nil, render: mesh, revision: 1)
            let expectedVolume = entry["expected_aggregate_volume_mm3"] as? Double ?? 0
            XCTAssertEqual(MeasureKit.volume(of: body), expectedVolume, accuracy: 0.001 * expectedVolume,
                           "\(name): mesh volume within 0.1 %")
            if let lo = entry["bounds_min_mm"] as? [Double], let hi = entry["bounds_max_mm"] as? [Double] {
                let aabb = mesh.localAABB
                for axis in 0..<3 {
                    XCTAssertEqual(Double(aabb.min[axis]), lo[axis], accuracy: 0.05, "\(name): bounds min[\(axis)]")
                    XCTAssertEqual(Double(aabb.max[axis]), hi[axis], accuracy: 0.05, "\(name): bounds max[\(axis)]")
                }
            }
        }
    }

    func testMeshIntegrityTellsClosedFromOpen() {
        let cube = Body(name: "cube", euclidMesh: Euclid.Mesh.cube(center: Vector(0, 0, 0), size: Vector(4, 4, 4)), revision: 1)
        XCTAssertEqual(MeshIntegrity.openEdgeCount(cube.render), 0)
        XCTAssertTrue(MeshIntegrity.isClosed(cube.render))
        var triangle = RenderMesh(positions: [], normals: [], indices: [])
        triangle.positions = [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(0, 10, 0)]
        triangle.normals = [SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(0, 0, 1)]
        triangle.indices = [0, 1, 2]
        XCTAssertEqual(MeshIntegrity.openEdgeCount(triangle), 3)
        XCTAssertFalse(MeshIntegrity.isClosed(triangle))
    }

    // MARK: DXF

    func testDXFEllipseImportsAsAnEllipse() throws {
        let entities = DXFKit.importDXF(try fixture("M15_curve_coupon.dxf"))
        XCTAssertEqual(entities.count, 4, "ellipse, arc, circle, line")
        var ellipses = 0
        for entity in entities {
            if case let .ellipse(_, center, radiusX, radiusY, _) = entity {
                ellipses += 1
                XCTAssertEqual(center.x, 0, accuracy: 1e-9)
                XCTAssertEqual(center.y, 0, accuracy: 1e-9)
                XCTAssertEqual(max(radiusX, radiusY), 10, accuracy: 1e-9)
                XCTAssertEqual(min(radiusX, radiusY), 5, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(ellipses, 1)
    }

    func testDXFEllipticalArcArrivesAsAPolylineBetweenItsEndpoints() {
        let quarter = """
        0\nSECTION\n2\nENTITIES\n0\nELLIPSE\n8\n0\n10\n0\n20\n0\n30\n0\n11\n10\n21\n0\n31\n0\n40\n0.5\n41\n0\n42\n1.5707963267948966\n0\nENDSEC\n0\nEOF\n
        """
        let entities = DXFKit.importDXF(Data(quarter.utf8))
        XCTAssertGreaterThanOrEqual(entities.count, 8)
        guard case let .line(_, first, _)? = entities.first, case let .line(_, _, last)? = entities.last else {
            return XCTFail("expected line segments, got \(entities)")
        }
        XCTAssertEqual(first.x, 10, accuracy: 1e-9); XCTAssertEqual(first.y, 0, accuracy: 1e-9)
        XCTAssertEqual(last.x, 0, accuracy: 1e-9); XCTAssertEqual(last.y, 5, accuracy: 1e-9)
    }

    func testDXFInsunitsScalesInchesToMillimetres() {
        let inches = "0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n1\n0\nENDSEC\n0\nSECTION\n2\nENTITIES\n0\nCIRCLE\n8\n0\n10\n1\n20\n2\n30\n0\n40\n0.5\n0\nENDSEC\n0\nEOF\n"
        let entities = DXFKit.importDXF(Data(inches.utf8))
        guard case let .circle(_, center, radius)? = entities.first else { return XCTFail("circle expected, got \(entities)") }
        XCTAssertEqual(center.x, 25.4, accuracy: 1e-9)
        XCTAssertEqual(center.y, 50.8, accuracy: 1e-9)
        XCTAssertEqual(radius, 12.7, accuracy: 1e-9)
        // Millimetres and an unspecified unit stay as they are.
        XCTAssertEqual(DXFKit.millimetresPerUnit(insunits: 4), 1)
        XCTAssertEqual(DXFKit.millimetresPerUnit(insunits: 0), 1)
        XCTAssertEqual(DXFKit.millimetresPerUnit(insunits: 5), 10)
        // The small imperial units are a thousand apart: a mil is a
        // thousandth of an inch, a microinch a millionth (2026-10-21: the
        // table had mils at 25.4 mm and microinches at a mil).
        XCTAssertEqual(DXFKit.millimetresPerUnit(insunits: 9), 0.0254, accuracy: 1e-12)
        XCTAssertEqual(DXFKit.millimetresPerUnit(insunits: 8), 0.0000254, accuracy: 1e-15)
        XCTAssertEqual(DXFKit.millimetresPerUnit(insunits: 3), 1_609_344)
        XCTAssertEqual(DXFKit.millimetresPerUnit(insunits: 12), 1e-6, accuracy: 1e-18)
    }

    func testDXFPlateSketchHasFourHolesAtTheirCentres() throws {
        let entities = DXFKit.importDXF(try fixture("M02_plate_sketch.dxf"))
        var lines = 0
        var centres = Set<String>()
        for entity in entities {
            switch entity {
            case .line: lines += 1
            case let .circle(_, c, r):
                XCTAssertEqual(r, 3, accuracy: 1e-9)
                centres.insert("\(Int(c.x.rounded())),\(Int(c.y.rounded()))")
            default: XCTFail("unexpected \(entity)")
            }
        }
        XCTAssertEqual(lines, 4)
        XCTAssertEqual(centres, ["10,10", "10,40", "70,10", "70,40"])
    }
}
