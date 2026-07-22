//
//  ProjectArchiveTests.swift
//  openshape3dTests
//
//  Phase F sharing tranche: the .os3d archive. The container must round-trip
//  byte-for-byte, refuse newer format versions, and — the load-bearing part —
//  remap every UUID CONSISTENTLY on import: a sketch ID appearing both as a
//  record ID and inside a feature's JSON blob must map to the same fresh ID,
//  while binary mesh blobs pass through untouched.
//

import XCTest
import SwiftData
@testable import openshape3d

final class ProjectArchiveTests: XCTestCase {

    // MARK: Fixtures — blobs built with the REAL persistence encoders

    private let sketchID = SketchID()
    private let entityID = UUID()
    private let bodyID = BodyID()
    private let featureID = FeatureID()

    private func sampleSketch() -> Sketch {
        var sketch = Sketch(id: sketchID, plane: .ground)
        sketch.entities.append(.line(id: entityID, a: SIMD2(0, 0), b: SIMD2(10, 0)))
        return sketch
    }

    /// An extrude node whose ProfileRef points at the sketch and whose output
    /// is the body — real cross-blob references for the remap to preserve.
    private func sampleFeature() -> FeatureNode {
        FeatureNode(
            id: featureID, name: "Extrude",
            kind: .extrude(
                profile: ProfileRef(
                    sketchID: sketchID, entityIDs: [entityID],
                    holeEntityIDs: [], seedPoint: nil),
                plane: PlaneRef(source: .sketch(sketchID)),
                distance: Expr(value: 5), symmetric: false,
                boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                extraProfiles: []),
            outputBodyIDs: [bodyID])
    }

    private func sampleArchive() throws -> ProjectArchive {
        var archive = ProjectArchive(name: "Fixture")
        let mesh = EuclidBridge.renderMesh(
            from: .primitive(.box(width: 2, depth: 2, height: 2)))
        archive.bodies = [.init(
            id: bodyID.raw, name: "Box",
            transform: try JSONEncoder().encode(Transform3D.identity),
            primitive: nil, mesh: MeshBlob.encode(mesh),
            isHidden: false, material: nil)]
        archive.sketches = [.init(
            id: sketchID.raw, data: try JSONEncoder().encode(sampleSketch()))]
        let node = sampleFeature()
        archive.features = [.init(
            id: featureID.raw, orderIndex: 0, name: node.name,
            suppressed: false, kind: encodeFeatureKind(node.kind),
            outputBodyIDs: encodeBodyIDs(node.outputBodyIDs))]
        archive.variables = [.init(
            id: UUID(), orderIndex: 0, name: "w", expression: "10", value: 10)]
        archive.thumbnail = Data([1, 2, 3])
        archive.rollbackIndex = 1
        return archive
    }

    // MARK: Container round-trip

    func testEncodedArchiveDecodesEqual() throws {
        let archive = try sampleArchive()
        let data = try XCTUnwrap(archive.encoded())
        let decoded = try XCTUnwrap(ProjectArchive.decode(data))
        XCTAssertEqual(decoded.name, "Fixture")
        XCTAssertEqual(decoded.version, ProjectArchive.currentVersion)
        XCTAssertEqual(decoded.bodies.first?.mesh, archive.bodies.first?.mesh)
        XCTAssertEqual(decoded.sketches.first?.data, archive.sketches.first?.data)
        XCTAssertEqual(decoded.features.first?.kind, archive.features.first?.kind)
        XCTAssertEqual(decoded.variables.first?.name, "w")
        XCTAssertEqual(decoded.thumbnail, Data([1, 2, 3]))
        XCTAssertEqual(decoded.rollbackIndex, 1)
    }

    func testDecodeRefusesNewerVersionsAndGarbage() throws {
        var archive = try sampleArchive()
        archive.version = ProjectArchive.currentVersion + 1
        let newer = try XCTUnwrap(archive.encoded())
        XCTAssertNil(ProjectArchive.decode(newer),
                     "a newer-format archive must refuse to load, not half-load")
        XCTAssertNil(ProjectArchive.decode(Data("not an archive".utf8)))
        XCTAssertNil(ProjectArchive.decode(Data()))
    }

    // MARK: UUID remap

    func testRemapKeepsCrossBlobReferencesConsistent() throws {
        let remapped = try sampleArchive().remappingAllUUIDs()

        // Every record ID is fresh.
        let newBody = try XCTUnwrap(remapped.bodies.first)
        let newSketch = try XCTUnwrap(remapped.sketches.first)
        let newFeature = try XCTUnwrap(remapped.features.first)
        XCTAssertNotEqual(newBody.id, bodyID.raw)
        XCTAssertNotEqual(newSketch.id, sketchID.raw)
        XCTAssertNotEqual(newFeature.id, featureID.raw)

        // The feature's output body ref followed the body record's new ID.
        XCTAssertEqual(decodeBodyIDs(newFeature.outputBodyIDs),
                       [BodyID(raw: newBody.id)],
                       "outputBodyIDs must follow the remapped body record")

        // The kind blob still decodes, and its sketch/entity refs follow the
        // sketch record and the entity ID INSIDE the sketch blob.
        let kind = try XCTUnwrap(decodeFeatureKind(newFeature.kind))
        guard case let .extrude(profile, plane, distance, _, _, _) = kind else {
            return XCTFail("remapped kind should still be an extrude")
        }
        XCTAssertEqual(profile.sketchID.raw, newSketch.id,
                       "ProfileRef.sketchID must follow the sketch record")
        if case let .sketch(sid) = plane.source {
            XCTAssertEqual(sid.raw, newSketch.id, "PlaneRef must follow too")
        } else {
            XCTFail("plane source should still be .sketch")
        }
        XCTAssertEqual(distance.value, 5, "non-ID payload survives untouched")

        let sketch = try XCTUnwrap(
            try? JSONDecoder().decode(Sketch.self, from: newSketch.data))
        XCTAssertEqual(sketch.entities.first?.id, profile.entityIDs.first,
                       "entity IDs inside the sketch blob stay consistent with the profile ref")
        XCTAssertNotEqual(sketch.entities.first?.id, entityID)
    }

    func testRemapLeavesBinaryBlobsUntouched() throws {
        let archive = try sampleArchive()
        let remapped = archive.remappingAllUUIDs()
        XCTAssertEqual(remapped.bodies.first?.mesh, archive.bodies.first?.mesh,
                       "mesh blobs carry no IDs and must pass through byte-identical")
        XCTAssertEqual(remapped.thumbnail, archive.thumbnail)
    }

    // MARK: Store insert — import twice, no unique-column collision

    @MainActor
    func testDoubleImportYieldsIndependentProjects() throws {
        let schema = Schema([
            Project.self, PersistedBody.self, PersistedSketch.self,
            PersistedPlane.self, PersistedImage.self, PersistedSymbol.self,
            PersistedFeature.self, PersistedVariable.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let archive = try sampleArchive()
        archive.remappingAllUUIDs().insert(into: context, name: "Import 1")
        try context.save()
        archive.remappingAllUUIDs().insert(into: context, name: "Import 2")
        try context.save()

        let projects = try context.fetch(FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\.name)]))
        XCTAssertEqual(projects.count, 2)
        for project in projects {
            XCTAssertEqual(project.bodies.count, 1)
            XCTAssertEqual(project.sketches.count, 1)
            XCTAssertEqual(project.features.count, 1)
            XCTAssertEqual(project.variables.count, 1)
            XCTAssertEqual(project.rollbackIndex, 1)
        }
        XCTAssertNotEqual(projects[0].bodies.first?.bodyID,
                          projects[1].bodies.first?.bodyID,
                          "each import owns fresh unique IDs")
    }
}
