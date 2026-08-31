//
//  ElementNamingTests.swift
//  openshape3dTests
//
//  Element names (docs/TOPO_NAMING_HISTORY_DESIGN.md step 2): identities
//  derived from persisted stable IDs, bound to kernel faces through real
//  OCCT ancestry, attached to face-table entries by channel majority vote —
//  and every ambiguity dropped rather than guessed. Pure values.
//

import XCTest
import simd
@testable import openshape3d

final class ElementNamingTests: XCTestCase {

    private let creator = FeatureID()

    private func squareProfile(entities: [UUID]) -> Profile {
        Profile(loop: [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 6), SIMD2(0, 6)],
                kind: .polygonal,
                sourceEntityIDs: Set(entities),
                edgeEntityIDs: entities)
    }

    private func extrude(_ profile: Profile)
        throws -> (handle: BRepHandle, ancestry: ShapeAncestry) {
        try XCTUnwrap(OCCTKernel.extrudeShapeWithAncestry(
            outerLoop: profile.loop, holes: [], zMin: 0, zMax: 4,
            origin: .zero, xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
            normal: SIMD3(0, 0, 1)))
    }

    // MARK: - Extrude naming from real kernel ancestry

    func testARectFromFourLinesNamesEachWallByItsEntity() throws {
        let entities = [UUID(), UUID(), UUID(), UUID()]
        let profile = squareProfile(entities: entities)
        let (_, ancestry) = try extrude(profile)
        let names = ElementNaming.extrudeNames(
            creator: creator, ancestry: ancestry, outer: profile, holes: [])

        XCTAssertEqual(names.count, 6, "2 caps + 4 walls, each named once")
        let sources = Set(names.values.map(\.source))
        XCTAssertTrue(sources.contains(.profileCap(end: false)))
        XCTAssertTrue(sources.contains(.profileCap(end: true)))
        for entity in entities {
            XCTAssertTrue(sources.contains(
                .profileWall(entity: entity, occurrence: 0)),
                "each line entity owns exactly one wall")
        }
        XCTAssertTrue(names.values.allSatisfy { $0.creator == creator })
    }

    /// A profile drawn as ONE rect entity: all four walls belong to it,
    /// separated by wire-order occurrence — deterministic from the profile's
    /// own arrays, so a dropped history row cannot shift the numbering.
    func testASingleEntityProfileSeparatesWallsByOccurrence() throws {
        let rect = UUID()
        var profile = squareProfile(entities: [rect, rect, rect, rect])
        profile.sourceEntityIDs = [rect]
        profile.edgeEntityIDs = []
        let (_, ancestry) = try extrude(profile)
        let names = ElementNaming.extrudeNames(
            creator: creator, ancestry: ancestry, outer: profile, holes: [])
        let occurrences = names.values.compactMap { name -> Int? in
            if case let .profileWall(entity, occurrence) = name.source,
               entity == rect { return occurrence }
            return nil
        }
        XCTAssertEqual(Set(occurrences), [0, 1, 2, 3])
    }

    // MARK: - Refusing to guess

    /// When the observed wall count matches no boundary description (here: a
    /// history row went missing), the walls stay unnamed — the caps, whose
    /// rows are intact, keep their names.
    func testAMissingWallRowUnnamesTheLoopNotTheCaps() throws {
        let entities = [UUID(), UUID(), UUID(), UUID()]
        let profile = squareProfile(entities: entities)
        let (_, full) = try extrude(profile)
        let dropped = ShapeAncestry(rows: full.rows.filter {
            !($0.inputKind == .edge && $0.inputSubshape == 3)
        })
        let names = ElementNaming.extrudeNames(
            creator: creator, ancestry: dropped, outer: profile, holes: [])
        let wallNames = names.values.filter {
            if case .profileWall = $0.source { return true }
            return false
        }
        XCTAssertTrue(wallNames.isEmpty,
                      "3 observed walls match neither 4 loop edges nor any "
                      + "segment count — refuse to guess")
        XCTAssertEqual(names.count, 2, "the caps keep their names")
    }

    func testConflictingClaimsOnOneFaceAreDropped() {
        let rows = [
            ShapeAncestry.Row(resultFace: 1, inputOrdinal: 0, inputKind: .face,
                              inputSubshape: 1, relation: .modified),
            ShapeAncestry.Row(resultFace: 1, inputOrdinal: 0, inputKind: .face,
                              inputSubshape: 2, relation: .modified),
        ]
        let profile = squareProfile(entities: [UUID(), UUID(), UUID(), UUID()])
        let names = ElementNaming.extrudeNames(
            creator: creator, ancestry: ShapeAncestry(rows: rows),
            outer: profile, holes: [])
        XCTAssertTrue(names.isEmpty,
                      "one face claimed as both caps is ambiguous — drop it")
    }

    // MARK: - Attachment by majority vote

    private func entry(triangles: [Int]) -> FaceTable.Entry {
        FaceTable.Entry(
            role: .derived(index: 0),
            signature: FaceSignature(kind: .planar, normal: SIMD3(0, 0, 1),
                                     centroid: .zero, area: 1, planeOffset: 0),
            triangles: triangles)
    }

    func testAttachRequiresAStrictMajorityAndSkipsUnknowns() {
        let n1 = ElementName(creator: creator, source: .profileCap(end: false))
        let n2 = ElementName(creator: creator, source: .profileCap(end: true))
        let table = FaceTable(entries: [
            entry(triangles: [0, 1]),        // channel 1,1 → n1
            entry(triangles: [2, 3, 4]),     // channel 2,2,9 → majority 2 → n2
            entry(triangles: [5, 6]),        // channel 0,3 → 0 is unknown, 3 no majority
            entry(triangles: [9]),           // out of channel bounds → unnamed
        ])
        let channel: [UInt32] = [1, 1, 2, 2, 9, 0, 3, 0, 0]
        let named = ElementNaming.attach([1: n1, 2: n2], to: table,
                                         channel: channel)
        XCTAssertEqual(named.entries[0].elementName, n1)
        XCTAssertEqual(named.entries[1].elementName, n2)
        XCTAssertNil(named.entries[2].elementName)
        XCTAssertNil(named.entries[3].elementName)
    }

    // MARK: - Primitives

    func testPrimitiveEntriesNameByRoleExceptDerived() {
        var table = FaceTable(entries: [entry(triangles: [0]),
                                        entry(triangles: [1])])
        table.entries[0].role = .cylinderCap(top: true)
        let named = ElementNaming.namePrimitiveEntries(table, creator: creator)
        XCTAssertEqual(named.entries[0].elementName?.source,
                       .primitiveFace(.cylinderCap(top: true)))
        XCTAssertNil(named.entries[1].elementName, ".derived carries no identity")
    }

    // MARK: - Detector identity arrays

    func testTheDetectorEmitsEdgeEntitiesInLoopOrder() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let sketch = Sketch(plane: .ground, entities: [
            .line(id: a, a: SIMD2(0, 0), b: SIMD2(8, 0)),
            .line(id: b, a: SIMD2(8, 0), b: SIMD2(8, 5)),
            .line(id: c, a: SIMD2(8, 5), b: SIMD2(0, 5)),
            .line(id: d, a: SIMD2(0, 5), b: SIMD2(0, 0)),
        ])
        let profile = try XCTUnwrap(
            ProfileDetector.detectProfiles(in: sketch).first)
        XCTAssertEqual(profile.edgeEntityIDs.count, profile.loop.count)
        // Edge i spans loop[i] → loop[i+1] and must be owned by the line
        // entity with exactly those endpoints.
        let lines = [a: (SIMD2<Double>(0, 0), SIMD2<Double>(8, 0)),
                     b: (SIMD2<Double>(8, 0), SIMD2<Double>(8, 5)),
                     c: (SIMD2<Double>(8, 5), SIMD2<Double>(0, 5)),
                     d: (SIMD2<Double>(0, 5), SIMD2<Double>(0, 0))]
        for i in profile.loop.indices {
            let start = profile.loop[i]
            let end = profile.loop[(i + 1) % profile.loop.count]
            let owner = try XCTUnwrap(lines[profile.edgeEntityIDs[i]])
            let matches = (simd_length(owner.0 - start) < 1e-9
                           && simd_length(owner.1 - end) < 1e-9)
                || (simd_length(owner.1 - start) < 1e-9
                    && simd_length(owner.0 - end) < 1e-9)
            XCTAssertTrue(matches, "edge \(i) owner mismatch")
        }
        // boundaryIdentity picks the polyline description for a 4-edge wire.
        let identity = try XCTUnwrap(
            profile.boundaryIdentity(wireEdge: 2, wireEdgeCount: 4))
        XCTAssertEqual(identity.entity, profile.edgeEntityIDs[1])
        XCTAssertEqual(identity.occurrence, 0)
    }
}
