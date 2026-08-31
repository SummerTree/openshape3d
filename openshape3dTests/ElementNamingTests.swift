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

    // MARK: - Boolean composition rules (pure values)

    private func faceRow(_ face: Int, ordinal: Int, sub: Int,
                         _ relation: ShapeAncestry.Relation) -> ShapeAncestry.Row {
        ShapeAncestry.Row(resultFace: face, inputOrdinal: ordinal,
                          inputKind: .face, inputSubshape: sub,
                          relation: relation)
    }

    func testBooleanNamesInheritSplitMintAndRefuse() {
        let op = FeatureID()
        let capA = ElementName(creator: creator, source: .profileCap(end: true))
        let capB = ElementName(creator: creator, source: .profileCap(end: false))
        let wall = ElementName(creator: creator,
                               source: .profileWall(entity: UUID(), occurrence: 0))
        let ancestry = ShapeAncestry(rows: [
            faceRow(1, ordinal: 0, sub: 1, .same),        // untouched → inherit capA
            faceRow(2, ordinal: 0, sub: 2, .modified),    // split capB…
            faceRow(3, ordinal: 0, sub: 2, .modified),    // …into faces 2 and 3
            faceRow(4, ordinal: 1, sub: 1, .generated),   // section from tool wall
            faceRow(5, ordinal: 0, sub: 1, .modified),    // merged: capA…
            faceRow(5, ordinal: 1, sub: 1, .modified),    // …and tool wall
            faceRow(6, ordinal: 0, sub: 9, .modified),    // unnamed parent
        ])
        let names = ElementNaming.booleanNames(
            operation: op, ancestry: ancestry,
            inputNames: [[1: capA, 2: capB], [1: wall]])

        // Face 1 would inherit capA — but face 5's merge doesn't contest it,
        // so the identity continues.
        XCTAssertEqual(names[1], capA)
        // The split: both fragments minted, never a duplicated inherit.
        for face in [2, 3] {
            guard case let .opFace(operation, parents, _)? = names[face]?.source else {
                return XCTFail("face \(face) must be minted, got \(String(describing: names[face]))")
            }
            XCTAssertEqual(operation, op)
            XCTAssertEqual(parents, [capB])
        }
        XCTAssertNotEqual(names[2], names[3], "fragments carry distinct indices")
        // Section face: minted with its generating parent.
        guard case let .opFace(_, sectionParents, _)? = names[4]?.source else {
            return XCTFail("section face must be minted")
        }
        XCTAssertEqual(sectionParents, [wall])
        // Merged face: minted with BOTH parents.
        guard case let .opFace(_, mergedParents, _)? = names[5]?.source else {
            return XCTFail("merged face must be minted")
        }
        XCTAssertEqual(Set(mergedParents), [capA, wall])
        // Modified from an unnamed parent: honestly unnamed.
        XCTAssertNil(names[6])
    }

    // MARK: - Graph wiring: names reach the eval result

    func testAnExtrudeEvalNamesItsWholeFaceTable() throws {
        let sketchID = SketchID()
        let rectEntity = UUID()
        let extrudeFeature = FeatureID()
        let bodyID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: extrudeFeature, name: "Extrude",
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketchID,
                                        entityIDs: [rectEntity],
                                        holeEntityIDs: [], seedPoint: .zero),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    distance: Expr(value: 5), symmetric: false,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: []),
                outputBodyIDs: [bodyID]),
        ])
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .rect(id: rectEntity, min: SIMD2(-2, -2), max: SIMD2(2, 2)),
        ])
        var revision: UInt64 = 0
        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let table = try XCTUnwrap(result.faceTables[bodyID])
        XCTAssertEqual(table.entries.count, 6)
        let names = table.entries.compactMap(\.elementName)
        XCTAssertEqual(names.count, 6, "every extrude face carries a name")
        XCTAssertTrue(names.allSatisfy { $0.creator == extrudeFeature })
        let sources = Set(names.map(\.source))
        XCTAssertTrue(sources.contains(.profileCap(end: false)))
        XCTAssertTrue(sources.contains(.profileCap(end: true)))
        // The rect is ONE entity owning four walls, split by occurrence.
        for occurrence in 0...3 {
            XCTAssertTrue(sources.contains(
                .profileWall(entity: rectEntity, occurrence: occurrence)),
                "missing wall occurrence \(occurrence): \(sources)")
        }
    }

    func testAPrimitiveEvalNamesItsFaces() throws {
        let feature = FeatureID()
        let bodyID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(id: feature, name: "Cyl",
                        kind: .primitive(spec: .cylinder(radius: 4, height: 6),
                                         placement: .identity),
                        outputBodyIDs: [bodyID]),
        ])
        var revision: UInt64 = 0
        let result = graph.evaluate(sketches: [], planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty)
        let table = try XCTUnwrap(result.faceTables[bodyID])
        let sources = Set(table.entries.compactMap(\.elementName?.source))
        XCTAssertTrue(sources.contains(.primitiveFace(.cylinderSide)))
        XCTAssertTrue(sources.contains(.primitiveFace(.cylinderCap(top: true))))
        XCTAssertTrue(sources.contains(.primitiveFace(.cylinderCap(top: false))))
    }

    /// The whole step-3 pipeline on real geometry: a symmetric slab, a
    /// trench tool cutting through its top — untouched faces INHERIT their
    /// extrude names across the boolean, tool-derived faces carry the
    /// TOOL's names into the result, and the split top cap is minted as two
    /// distinct fragments instead of a duplicated inherit.
    func testABooleanEvalComposesNamesAcrossBodies() throws {
        let slabSketch = SketchID(), toolSketch = SketchID()
        let slabRect = UUID(), toolRect = UUID()
        let slabFeature = FeatureID(), toolFeature = FeatureID()
        let booleanFeature = FeatureID()
        let slabID = BodyID(), toolID = BodyID()

        func extrudeNode(_ id: FeatureID, name: String, sketch: SketchID,
                         entity: UUID, distance: Double, symmetric: Bool,
                         body: BodyID) -> FeatureNode {
            FeatureNode(
                id: id, name: name,
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketch, entityIDs: [entity],
                                        holeEntityIDs: [], seedPoint: .zero),
                    plane: PlaneRef(source: .sketch(sketch)),
                    distance: Expr(value: distance), symmetric: symmetric,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: []),
                outputBodyIDs: [body])
        }
        let graph = FeatureGraph(nodes: [
            // Slab y ∈ [-2, 2]; trench tool y ∈ [0, 3] through the top only,
            // full-length in x so the top cap SPLITS into two strips.
            extrudeNode(slabFeature, name: "Slab", sketch: slabSketch,
                        entity: slabRect, distance: 2, symmetric: true,
                        body: slabID),
            extrudeNode(toolFeature, name: "Trench", sketch: toolSketch,
                        entity: toolRect, distance: 3, symmetric: false,
                        body: toolID),
            FeatureNode(
                id: booleanFeature, name: "Cut",
                kind: .boolean(
                    kind: .subtract,
                    target: BodyRef(producer: slabFeature, bodyID: slabID),
                    tools: [BodyRef(producer: toolFeature, bodyID: toolID)]),
                outputBodyIDs: []),
        ])
        let sketches = [
            Sketch(id: slabSketch, name: "S", plane: .ground, entities: [
                .rect(id: slabRect, min: SIMD2(-5, -3), max: SIMD2(5, 3))]),
            Sketch(id: toolSketch, name: "T", plane: .ground, entities: [
                .rect(id: toolRect, min: SIMD2(-6, -1), max: SIMD2(6, 1))]),
        ]
        var revision: UInt64 = 0
        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == slabID })
        // Slab 10×4×6 minus the 10×2×2 trench bite.
        XCTAssertEqual(MeasureKit.bodyVolume(body.render, scale: 1), 200,
                       accuracy: 1e-6)

        let names = try XCTUnwrap(result.faceTables[slabID])
            .entries.compactMap(\.elementName)
        XCTAssertFalse(names.isEmpty)

        // Untouched slab faces inherit their extrude identities verbatim.
        XCTAssertTrue(names.contains(ElementName(
            creator: slabFeature, source: .profileCap(end: false))),
            "the bottom cap survives untouched")
        let slabWalls = names.filter {
            if case .profileWall = $0.source { return $0.creator == slabFeature }
            return false
        }
        XCTAssertEqual(slabWalls.count, 4,
                       "all four slab walls survive (two of them notched)")

        // Tool-derived trench faces carry the TOOL's identities into the
        // result — inherited or minted-with-parent, whichever OCCT's
        // relation reported; deriving from the tool is what matters.
        let toolStartCap = ElementName(creator: toolFeature,
                                       source: .profileCap(end: false))
        func derives(_ name: ElementName, from parent: ElementName) -> Bool {
            if name == parent { return true }
            if case let .opFace(_, parents, _) = name.source {
                return parents.contains(parent)
            }
            return false
        }
        XCTAssertTrue(names.contains { derives($0, from: toolStartCap) },
                      "the trench floor descends from the tool's start cap")
        let toolWallDerived = names.filter { name in
            guard name.creator == toolFeature || name.creator == booleanFeature
            else { return false }
            if case let .profileWall(entity, _) = name.source {
                return entity == toolRect
            }
            if case let .opFace(_, parents, _) = name.source {
                return parents.contains { parent in
                    if case let .profileWall(entity, _) = parent.source {
                        return entity == toolRect
                    }
                    return false
                }
            }
            return false
        }
        XCTAssertEqual(toolWallDerived.count, 2,
                       "the two long trench sides descend from tool walls")

        // The split: the slab's top cap becomes two fragments, minted with
        // distinct indices — never two faces sharing one inherited name.
        let slabTop = ElementName(creator: slabFeature,
                                  source: .profileCap(end: true))
        XCTAssertFalse(names.contains(slabTop),
                       "a split face must not keep its old single identity")
        let fragments = names.compactMap { name -> Int? in
            guard case let .opFace(operation, parents, index) = name.source,
                  operation == booleanFeature, parents == [slabTop]
            else { return nil }
            return index
        }
        XCTAssertEqual(Set(fragments), [0, 1],
                       "two top-cap fragments with distinct indices, got \(fragments)")

        // And no name appears twice anywhere — the invariant the split rule
        // exists to protect.
        XCTAssertEqual(Set(names).count, names.count,
                       "duplicate names in \(names)")
    }

    /// The extrude CUT branch (boolean-into-target): the hole's walls carry
    /// the cutting extrude's identity — "wall of sketch entity X, created
    /// by extrude N" — while the slab's own faces keep theirs.
    func testAnExtrudeCutNamesTheHoleWallsFromTheCuttingSketch() throws {
        let slabSketch = SketchID(), cutSketch = SketchID()
        let slabRect = UUID(), cutRect = UUID()
        let slabFeature = FeatureID(), cutFeature = FeatureID()
        let slabID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: slabFeature, name: "Slab",
                kind: .extrude(
                    profile: ProfileRef(sketchID: slabSketch, entityIDs: [slabRect],
                                        holeEntityIDs: [], seedPoint: .zero),
                    plane: PlaneRef(source: .sketch(slabSketch)),
                    distance: Expr(value: 2), symmetric: true,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: []),
                outputBodyIDs: [slabID]),
            FeatureNode(
                id: cutFeature, name: "Hole",
                kind: .extrude(
                    profile: ProfileRef(sketchID: cutSketch, entityIDs: [cutRect],
                                        holeEntityIDs: [], seedPoint: .zero),
                    plane: PlaneRef(source: .sketch(cutSketch)),
                    distance: Expr(value: 3), symmetric: true,
                    boolean: BooleanIntent(
                        op: .subtract,
                        resolvedTargets: [BodyRef(producer: slabFeature,
                                                  bodyID: slabID)]),
                    extraProfiles: []),
                outputBodyIDs: []),
        ])
        let sketches = [
            Sketch(id: slabSketch, name: "S", plane: .ground, entities: [
                .rect(id: slabRect, min: SIMD2(-5, -3), max: SIMD2(5, 3))]),
            Sketch(id: cutSketch, name: "C", plane: .ground, entities: [
                .rect(id: cutRect, min: SIMD2(-1, -1), max: SIMD2(1, 1))]),
        ]
        var revision: UInt64 = 0
        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == slabID })
        // 10×4×6 slab minus the 2×4×2 through-hole.
        XCTAssertEqual(MeasureKit.bodyVolume(body.render, scale: 1), 224,
                       accuracy: 1e-6)

        let names = try XCTUnwrap(result.faceTables[slabID])
            .entries.compactMap(\.elementName)
        // The slab's caps gained a hole but stayed one face each — identity
        // continues across the cut.
        XCTAssertTrue(names.contains(ElementName(
            creator: slabFeature, source: .profileCap(end: true))))
        XCTAssertTrue(names.contains(ElementName(
            creator: slabFeature, source: .profileCap(end: false))))
        // Four hole walls, each owned by the CUTTING extrude's sketch entity.
        let holeWalls = names.filter { name in
            guard name.creator == cutFeature,
                  case let .profileWall(entity, _) = name.source else { return false }
            return entity == cutRect
        }
        XCTAssertEqual(holeWalls.count, 4, "hole walls: \(names)")
        XCTAssertEqual(Set(names).count, names.count, "no duplicate names")
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
