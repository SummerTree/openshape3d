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
        let names = ElementNaming.composeNames(
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

    // MARK: - Name-first resolve (step 4)

    /// A slab with two IDENTICAL square through-holes — the geometry that
    /// makes signature scoring genuinely ambiguous, which is what name-first
    /// resolution exists for.
    private func twoHoleFixture() throws
        -> (body: Body, table: FaceTable, cutA: FeatureID, cutB: FeatureID) {
        let slabSketch = SketchID(), aSketch = SketchID(), bSketch = SketchID()
        let slabRect = UUID(), aRect = UUID(), bRect = UUID()
        let slabFeature = FeatureID(), cutA = FeatureID(), cutB = FeatureID()
        let slabID = BodyID()
        func cut(_ id: FeatureID, name: String, sketch: SketchID,
                 entity: UUID, seed: SIMD2<Double>) -> FeatureNode {
            FeatureNode(
                id: id, name: name,
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketch, entityIDs: [entity],
                                        holeEntityIDs: [], seedPoint: seed),
                    plane: PlaneRef(source: .sketch(sketch)),
                    distance: Expr(value: 3), symmetric: true,
                    boolean: BooleanIntent(
                        op: .subtract,
                        resolvedTargets: [BodyRef(producer: slabFeature,
                                                  bodyID: slabID)]),
                    extraProfiles: []),
                outputBodyIDs: [])
        }
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
            cut(cutA, name: "CutA", sketch: aSketch, entity: aRect,
                seed: SIMD2(-3, 0)),
            cut(cutB, name: "CutB", sketch: bSketch, entity: bRect,
                seed: SIMD2(3, 0)),
        ])
        let sketches = [
            Sketch(id: slabSketch, name: "S", plane: .ground, entities: [
                .rect(id: slabRect, min: SIMD2(-5, -3), max: SIMD2(5, 3))]),
            Sketch(id: aSketch, name: "A", plane: .ground, entities: [
                .rect(id: aRect, min: SIMD2(-4, -1), max: SIMD2(-2, 1))]),
            Sketch(id: bSketch, name: "B", plane: .ground, entities: [
                .rect(id: bRect, min: SIMD2(2, -1), max: SIMD2(4, 1))]),
        ]
        var revision: UInt64 = 0
        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == slabID })
        return (body, try XCTUnwrap(result.faceTables[slabID]), cutA, cutB)
    }

    /// The +x-facing wall entry of the given cut's hole.
    private func plusXWall(of creator: FeatureID,
                           in table: FaceTable) throws -> FaceTable.Entry {
        try XCTUnwrap(table.entries.first { entry in
            guard entry.elementName?.creator == creator,
                  case .profileWall = entry.elementName?.source else { return false }
            return entry.signature.normal.x > 0.9
        }, "no +x wall named for \(creator)")
    }

    /// THE mis-binding demonstration: a ref whose geometry has drifted onto
    /// hole B's wall but whose NAME says hole A. Signature-only binds B;
    /// name-first binds A. This is R4-N1..N6 in one assertion.
    func testANameHitOutranksSignatureScoring() throws {
        let (body, table, cutA, cutB) = try twoHoleFixture()
        let wallA = try plusXWall(of: cutA, in: table)
        let wallB = try plusXWall(of: cutB, in: table)
        let naming = SignatureNaming()

        let driftedRef = FaceRef(
            body: BodyRef(producer: cutA, bodyID: body.id), creator: cutA,
            role: .derived(index: 0),
            signature: wallB.signature,          // geometry says B…
            elementName: wallA.elementName)      // …identity says A
        let named = try XCTUnwrap(naming.resolve(driftedRef, in: body, table: table))
        XCTAssertEqual(named.confidence, 1, "a name hit is exact")
        XCTAssertLessThan(try XCTUnwrap(named.planar).origin.x, 0,
                          "the name must win: hole A lives at x < 0")

        var legacyRef = driftedRef
        legacyRef.elementName = nil
        let legacy = try XCTUnwrap(naming.resolve(legacyRef, in: body, table: table))
        XCTAssertGreaterThan(try XCTUnwrap(legacy.planar).origin.x, 0,
                             "without the name, the signature binds hole B — "
                             + "the silent mis-bind this design exists to stop")
    }

    /// A name-bearing ref whose name MISSED and whose signature sits exactly
    /// between two identical candidates: refuse. The same ref without a name
    /// keeps today's behavior and picks one.
    func testANameMissWithAmbiguousSignatureRefusesToGuess() throws {
        let (body, table, _, cutB) = try twoHoleFixture()
        let wallB = try plusXWall(of: cutB, in: table)
        let naming = SignatureNaming()

        var midway = wallB.signature
        midway.centroid.x = 0
        midway.planeOffset = simd_dot(midway.normal, midway.centroid)
        let ghostName = ElementName(creator: FeatureID(),
                                    source: .profileCap(end: true))
        let namedRef = FaceRef(
            body: BodyRef(producer: cutB, bodyID: body.id), creator: cutB,
            role: .derived(index: 0), signature: midway,
            elementName: ghostName)
        XCTAssertNil(naming.resolve(namedRef, in: body, table: table),
                     "two near-tied candidates after a name miss must refuse")

        var legacyRef = namedRef
        legacyRef.elementName = nil
        XCTAssertNotNil(naming.resolve(legacyRef, in: body, table: table),
                        "legacy refs keep today's behavior untouched")
    }

    /// Old documents carry refs with no elementName key at all — they must
    /// decode unchanged, and a nil name must not even be written.
    func testFaceRefCodableBackCompat() throws {
        let legacy = FaceRef(
            body: BodyRef(producer: creator, bodyID: BodyID()),
            creator: creator, role: .derived(index: 0),
            signature: FaceSignature(kind: .planar, normal: SIMD3(0, 0, 1),
                                     centroid: .zero, area: 1, planeOffset: 0))
        let encoded = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self)
            .contains("elementName"), "nil names stay off disk")
        let decoded = try JSONDecoder().decode(FaceRef.self, from: encoded)
        XCTAssertEqual(decoded, legacy)

        var named = legacy
        named.elementName = ElementName(creator: creator,
                                        source: .profileCap(end: true))
        let namedRoundTrip = try JSONDecoder().decode(
            FaceRef.self, from: JSONEncoder().encode(named))
        XCTAssertEqual(namedRoundTrip, named)
    }

    /// The name path through a full replay: a pushPull whose ref carries the
    /// top cap's name evaluates cleanly and moves the right face.
    func testAPushPullResolvesByNameThroughReplay() throws {
        let (body, table, _, _) = try twoHoleFixture()
        _ = body
        let capEntry = try XCTUnwrap(table.entries.first {
            $0.elementName?.source == .profileCap(end: true)
        })
        // Rebuild the same document with a pushPull appended, its ref
        // carrying BOTH the honest signature and the name.
        // (Fixture rebuilt inline because FeatureGraph nodes are immutable.)
        let slabSketch = SketchID(), slabRect = UUID()
        let slabFeature = FeatureID(), pushFeature = FeatureID()
        let slabID = BodyID()
        let ref = FaceRef(
            body: BodyRef(producer: slabFeature, bodyID: slabID),
            creator: slabFeature, role: .derived(index: 0),
            signature: capEntry.signature,
            elementName: ElementName(creator: slabFeature,
                                     source: .profileCap(end: true)))
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
                id: pushFeature, name: "Push",
                kind: .pushPull(face: ref, distance: Expr(value: 2),
                                mode: .planarAxial),
                outputBodyIDs: []),
        ])
        let sketches = [Sketch(id: slabSketch, name: "S", plane: .ground, entities: [
            .rect(id: slabRect, min: SIMD2(-5, -3), max: SIMD2(5, 3))])]
        var revision: UInt64 = 0
        let result = graph.evaluate(sketches: sketches, planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let pushed = try XCTUnwrap(result.bodies.first { $0.id == slabID })
        // 10×4×6 slab, top cap pushed out 2 → 10×6×6.
        XCTAssertEqual(MeasureKit.bodyVolume(pushed.render, scale: 1), 360,
                       accuracy: 1e-6)
    }

    // MARK: - Edge identity (step 4b)

    func testEdgeNamesPairUnorderedAndCountOccurrences() {
        let cap = ElementName(creator: creator, source: .profileCap(end: true))
        let wall = ElementName(creator: creator,
                               source: .profileWall(entity: UUID(), occurrence: 0))
        let names = [1: cap, 2: wall]
        let adjacency = [(edge: 3, faceA: 1, faceB: 2),
                         (edge: 7, faceA: 2, faceB: 1),   // same pair again
                         (edge: 9, faceA: 1, faceB: 5)]   // face 5 unnamed
        let edgeNames = ElementNaming.edgeNames(adjacency: adjacency, names: names)
        XCTAssertEqual(edgeNames.count, 2, "the unnamed-flank edge is unaddressable")
        XCTAssertEqual(edgeNames[3]?.occurrence, 0)
        XCTAssertEqual(edgeNames[7]?.occurrence, 1, "same pair, next occurrence")
        // Unordered equality: a swapped pair finds the same edge.
        let swapped = EdgeName(faceA: wall, faceB: cap, occurrence: 0)
        XCTAssertEqual(ElementNaming.edgeIndex(named: swapped,
                                               adjacency: adjacency,
                                               names: names), 3)
    }

    func testAdjacencyCoversEveryBoxEdge() throws {
        let box = try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: 4, depth: 4, height: 4), placement: .identity))
        let adjacency = OCCTKernel.edgeFaceAdjacency(box)
        XCTAssertEqual(adjacency.count, 12)
        for triple in adjacency {
            XCTAssertNotEqual(triple.faceA, triple.faceB)
            XCTAssertTrue((1...6).contains(triple.faceA))
            XCTAssertTrue((1...6).contains(triple.faceB))
        }
        XCTAssertEqual(Set(adjacency.map(\.edge)).count, 12, "each edge once")
    }

    /// Identity addressing and point matching share one implementation —
    /// blending the same rim by edge index and by midpoint must produce the
    /// same solid, and a bad index must fail the WHOLE op, typed.
    func testBlendByIndexMatchesBlendByPointAndFailsClosed() throws {
        let cylinder = try XCTUnwrap(OCCTKernel.primitiveShape(
            .cylinder(radius: 5, height: 8), placement: .identity))
        let rim = SIMD3<Double>(5, 8, 0)
        let tolerance = OCCTKernel.matchTolerance(for: cylinder)
        let byPoint = try OCCTKernel.filletResult(
            cylinder, at: [rim], radius: 1, tolerance: tolerance).get()
        let index = try XCTUnwrap(OCCTKernel.nearestEdgeIndex(
            cylinder, to: rim, tolerance: tolerance))
        let byIndex = try OCCTKernel.filletResult(
            cylinder, edgeIndices: [index], radius: 1).get()
        XCTAssertEqual(OCCTKernel.volume(byPoint),
                       OCCTKernel.volume(byIndex), accuracy: 1e-9)

        guard case .failure = OCCTKernel.filletResult(
            cylinder, edgeIndices: [999], radius: 1) else {
            return XCTFail("an out-of-range index must fail the whole op")
        }
    }

    /// THE step-4b payoff: a chamfer ref whose SIGNATURE drifted onto hole
    /// B's rim but whose NAME says hole A blends hole A. The same ref
    /// without the name blends hole B — the silent wrong-edge rebind that
    /// "rebuild broke my fillet" reports come from.
    func testABlendResolvesByIdentityNotBySignature() throws {
        let slabSketch = SketchID(), aSketch = SketchID(), bSketch = SketchID()
        let slabRect = UUID(), aRect = UUID(), bRect = UUID()
        let slabFeature = FeatureID(), cutA = FeatureID(), cutB = FeatureID()
        let slabID = BodyID()
        func cutNode(_ id: FeatureID, name: String, sketch: SketchID,
                     seed: SIMD2<Double>, entity: UUID) -> FeatureNode {
            FeatureNode(
                id: id, name: name,
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketch, entityIDs: [entity],
                                        holeEntityIDs: [], seedPoint: seed),
                    plane: PlaneRef(source: .sketch(sketch)),
                    distance: Expr(value: 3), symmetric: true,
                    boolean: BooleanIntent(
                        op: .subtract,
                        resolvedTargets: [BodyRef(producer: slabFeature,
                                                  bodyID: slabID)]),
                    extraProfiles: []),
                outputBodyIDs: [])
        }
        let baseNodes = [
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
            cutNode(cutA, name: "CutA", sketch: aSketch, seed: SIMD2(-3, 0),
                    entity: aRect),
            cutNode(cutB, name: "CutB", sketch: bSketch, seed: SIMD2(3, 0),
                    entity: bRect),
        ]
        let sketches = [
            Sketch(id: slabSketch, name: "S", plane: .ground, entities: [
                .rect(id: slabRect, min: SIMD2(-5, -3), max: SIMD2(5, 3))]),
            Sketch(id: aSketch, name: "A", plane: .ground, entities: [
                .rect(id: aRect, min: SIMD2(-4, -1), max: SIMD2(-2, 1))]),
            Sketch(id: bSketch, name: "B", plane: .ground, entities: [
                .rect(id: bRect, min: SIMD2(2, -1), max: SIMD2(4, 1))]),
        ]
        func evaluate(_ nodes: [FeatureNode]) -> EvalResult {
            var revision: UInt64 = 0
            return FeatureGraph(nodes: nodes).evaluate(
                sketches: sketches, planes: [], naming: SignatureNaming(),
                nextRevision: { revision += 1; return revision })
        }

        // Harvest identity from the base build.
        let base = evaluate(baseNodes)
        XCTAssertTrue(base.errors.isEmpty, "\(base.errors)")
        let baseBody = try XCTUnwrap(base.bodies.first { $0.id == slabID })
        let brep = try XCTUnwrap(baseBody.brep)
        let names = try XCTUnwrap(base.kernelNames[slabID])
        let edgeNames = ElementNaming.edgeNames(
            adjacency: OCCTKernel.edgeFaceAdjacency(brep), names: names)
        // An edge on hole A's TOP rim: top cap on one flank, a cutA wall on
        // the other.
        let topCap = ElementName(creator: slabFeature,
                                 source: .profileCap(end: true))
        let ridgeName = try XCTUnwrap(edgeNames.values.first { name in
            let pair = [name.faceA, name.faceB]
            return pair.contains(topCap) && pair.contains { other in
                guard case .profileWall = other.source else { return false }
                return other.creator == cutA
            }
        }, "no named top-rim edge on hole A: \(edgeNames)")

        // A DRIFTED signature: the mirrored rim edge over at hole B.
        let driftedEdge = try XCTUnwrap(
            EdgeTopology.selectableEdges(from: baseBody.render).first {
                $0.midpoint.y > 1.9 && $0.midpoint.x > 1.4
                    && abs($0.midpoint.z) < 1.1 && $0.isConvex
            }, "no selectable rim edge near hole B")
        let driftedSignature = EdgeTopology.signature(of: driftedEdge)

        func chamferNode(faceNames: EdgeName?) -> FeatureNode {
            FeatureNode(
                name: "Chamfer",
                kind: .chamfer(
                    body: BodyRef(producer: slabFeature, bodyID: slabID),
                    edges: [EdgeRef(body: BodyRef(producer: slabFeature,
                                                  bodyID: slabID),
                                    signature: driftedSignature,
                                    faceNames: faceNames)],
                    setback: Expr(value: 0.4)),
                outputBodyIDs: [slabID])
        }
        // Which side did the chamfer land on? The new 45° face's centroid
        // says: hole A lives at x < 0, hole B at x > 0.
        func chamferSideX(_ result: EvalResult) throws -> Double {
            XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
            let table = try XCTUnwrap(result.faceTables[slabID])
            let slanted = table.entries.filter {
                if case .planar = $0.signature.kind {
                    return abs($0.signature.normal.y) > 0.6
                        && abs($0.signature.normal.y) < 0.8
                }
                return false
            }
            XCTAssertEqual(slanted.count, 1,
                           "exactly one chamfer face, got \(slanted.count)")
            return try XCTUnwrap(slanted.first).signature.centroid.x
        }

        let byIdentity = evaluate(baseNodes + [chamferNode(faceNames: ridgeName)])
        XCTAssertLessThan(try chamferSideX(byIdentity), 0,
                          "the NAME says hole A — the chamfer must land there")

        let bySignature = evaluate(baseNodes + [chamferNode(faceNames: nil)])
        XCTAssertGreaterThan(try chamferSideX(bySignature), 0,
                             "without the name, the drifted signature rebinds "
                             + "to hole B — the bug class this step closes")
    }

    // MARK: - Modifier-op history (step 5): names survive blends/shell/deleteFace

    /// One slab + one square through-hole, with stable ids — the base every
    /// modifier test builds on.
    private struct ModifierFixture {
        let slabFeature = FeatureID()
        let cutFeature = FeatureID()
        let slabID = BodyID()
        let slabSketch = SketchID(), cutSketch = SketchID()
        let slabRect = UUID(), cutRect = UUID()

        var nodes: [FeatureNode] {
            [FeatureNode(
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
                                        holeEntityIDs: [], seedPoint: SIMD2(-3, 0)),
                    plane: PlaneRef(source: .sketch(cutSketch)),
                    distance: Expr(value: 3), symmetric: true,
                    boolean: BooleanIntent(
                        op: .subtract,
                        resolvedTargets: [BodyRef(producer: slabFeature,
                                                  bodyID: slabID)]),
                    extraProfiles: []),
                outputBodyIDs: [])]
        }
        var sketches: [Sketch] {
            [Sketch(id: slabSketch, name: "S", plane: .ground, entities: [
                .rect(id: slabRect, min: SIMD2(-5, -3), max: SIMD2(5, 3))]),
             Sketch(id: cutSketch, name: "C", plane: .ground, entities: [
                .rect(id: cutRect, min: SIMD2(-4, -1), max: SIMD2(-2, 1))])]
        }
        var bodyRef: BodyRef { BodyRef(producer: slabFeature, bodyID: slabID) }
        var bottomCap: ElementName {
            ElementName(creator: slabFeature, source: .profileCap(end: false))
        }
        var topCap: ElementName {
            ElementName(creator: slabFeature, source: .profileCap(end: true))
        }
    }

    private func evaluate(_ nodes: [FeatureNode],
                          _ sketches: [Sketch]) -> EvalResult {
        var revision: UInt64 = 0
        return FeatureGraph(nodes: nodes).evaluate(
            sketches: sketches, planes: [], naming: SignatureNaming(),
            nextRevision: { revision += 1; return revision })
    }

    /// A named rim edge of the fixture's hole plus a fresh chamfer node for it.
    private func chamferNode(for fixture: ModifierFixture,
                             from base: EvalResult) throws
        -> (node: FeatureNode, ridge: EdgeName) {
        let body = try XCTUnwrap(base.bodies.first { $0.id == fixture.slabID })
        let names = try XCTUnwrap(base.kernelNames[fixture.slabID])
        let edgeNames = ElementNaming.edgeNames(
            adjacency: OCCTKernel.edgeFaceAdjacency(try XCTUnwrap(body.brep)),
            names: names)
        let ridge = try XCTUnwrap(edgeNames.values.first { name in
            let pair = [name.faceA, name.faceB]
            return pair.contains(fixture.topCap) && pair.contains { other in
                guard case .profileWall = other.source else { return false }
                return other.creator == fixture.cutFeature
            }
        }, "no named top-rim edge on the hole")
        let available = EdgeTopology.selectableEdges(from: body.render)
        let anyEdge = try XCTUnwrap(available.first)
        let node = FeatureNode(
            name: "Chamfer",
            kind: .chamfer(
                body: fixture.bodyRef,
                edges: [EdgeRef(body: fixture.bodyRef,
                                signature: EdgeTopology.signature(of: anyEdge),
                                faceNames: ridge)],
                setback: Expr(value: 0.3)),
            outputBodyIDs: [fixture.slabID])
        return (node, ridge)
    }

    /// THE step-5 regression: a blend used to relabel everything `.generic`
    /// and erase every name. Now untouched faces INHERIT through it and the
    /// chamfer face is named FOR ITS CREASE.
    func testNamesSurviveABlend() throws {
        let fixture = ModifierFixture()
        let base = evaluate(fixture.nodes, fixture.sketches)
        XCTAssertTrue(base.errors.isEmpty, "\(base.errors)")
        let (chamfer, ridge) = try chamferNode(for: fixture, from: base)

        let result = evaluate(fixture.nodes + [chamfer], fixture.sketches)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let names = try XCTUnwrap(result.faceTables[fixture.slabID])
            .entries.compactMap(\.elementName)
        XCTAssertTrue(names.contains(fixture.bottomCap),
                      "the untouched bottom cap keeps its identity through the blend")
        let creaseFaces = names.filter { name in
            guard case let .opFace(operation, parents, _) = name.source,
                  operation == chamfer.id else { return false }
            return parents.contains(ridge.faceA) && parents.contains(ridge.faceB)
        }
        XCTAssertEqual(creaseFaces.count, 1,
                       "the chamfer face is named for its crease: \(names)")
    }

    /// REPEATED refs for ONE kernel edge. The picker selects mesh segments,
    /// and a tessellated rim is a chain of them over a single OCCT edge, so
    /// every segment mints the SAME EdgeName and the node legitimately stores
    /// the crease many times over. Composing the blend's face names keyed by
    /// edge index used to trap the whole process ("Duplicate values for key")
    /// on every rebuild of such a node — the app died mid-drag.
    func testRepeatedRefsForOneCreaseBlendItOnce() throws {
        let fixture = ModifierFixture()
        let base = evaluate(fixture.nodes, fixture.sketches)
        XCTAssertTrue(base.errors.isEmpty, "\(base.errors)")
        let (chamfer, ridge) = try chamferNode(for: fixture, from: base)
        guard case let .chamfer(body, edges, setback) = chamfer.kind else {
            return XCTFail("the fixture builds a chamfer node")
        }
        // The same crease, as three picked segments.
        let repeated = FeatureNode(
            id: chamfer.id, name: chamfer.name,
            kind: .chamfer(body: body, edges: edges + edges + edges,
                           setback: setback),
            outputBodyIDs: chamfer.outputBodyIDs)

        let result = evaluate(fixture.nodes + [repeated], fixture.sketches)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let names = try XCTUnwrap(result.faceTables[fixture.slabID])
            .entries.compactMap(\.elementName)
        let creaseFaces = names.filter { name in
            guard case let .opFace(operation, parents, _) = name.source,
                  operation == repeated.id else { return false }
            return parents.contains(ridge.faceA) && parents.contains(ridge.faceB)
        }
        XCTAssertEqual(creaseFaces.count, 1,
                       "one crease, one chamfer face — not one per ref: \(names)")
    }

    /// Names flow THROUGH the blend into later ops: a second cut after the
    /// chamfer still composes — its own hole walls named, the slab's bottom
    /// cap still carrying its original identity two ops later.
    func testNamesFlowThroughABlendIntoLaterBooleans() throws {
        let fixture = ModifierFixture()
        let base = evaluate(fixture.nodes, fixture.sketches)
        let (chamfer, _) = try chamferNode(for: fixture, from: base)

        let lateSketch = SketchID(), lateRect = UUID()
        let lateCut = FeatureID()
        let late = FeatureNode(
            id: lateCut, name: "LateHole",
            kind: .extrude(
                profile: ProfileRef(sketchID: lateSketch, entityIDs: [lateRect],
                                    holeEntityIDs: [], seedPoint: SIMD2(3, 0)),
                plane: PlaneRef(source: .sketch(lateSketch)),
                distance: Expr(value: 3), symmetric: true,
                boolean: BooleanIntent(op: .subtract,
                                       resolvedTargets: [fixture.bodyRef]),
                extraProfiles: []),
            outputBodyIDs: [])
        let sketches = fixture.sketches + [
            Sketch(id: lateSketch, name: "L", plane: .ground, entities: [
                .rect(id: lateRect, min: SIMD2(2, -1), max: SIMD2(4, 1))])]

        let result = evaluate(fixture.nodes + [chamfer, late], sketches)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let names = try XCTUnwrap(result.faceTables[fixture.slabID])
            .entries.compactMap(\.elementName)
        XCTAssertTrue(names.contains(fixture.bottomCap),
                      "the bottom cap's identity survives cut → blend → cut")
        let lateWalls = names.filter { name in
            guard name.creator == lateCut,
                  case let .profileWall(entity, _) = name.source else { return false }
            return entity == lateRect
        }
        XCTAssertEqual(lateWalls.count, 4,
                       "the late cut composes against post-blend names: \(names)")
    }

    /// A closed hollow keeps every OUTER identity; the new inner faces stay
    /// honestly unnamed (the composite offset+cut branch reports survival
    /// only).
    func testAClosedHollowShellKeepsOuterIdentities() throws {
        let fixture = ModifierFixture()
        let shellNode = FeatureNode(
            name: "Shell",
            kind: .shell(body: fixture.bodyRef, openFaces: [],
                         thickness: Expr(value: 0.5)),
            outputBodyIDs: [fixture.slabID])
        // Slab only (no hole) — the simplest closed hollow.
        let result = evaluate([fixture.nodes[0], shellNode], fixture.sketches)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let entries = try XCTUnwrap(result.faceTables[fixture.slabID]).entries
        let named = entries.compactMap(\.elementName)
        XCTAssertEqual(named.count, 6, "all six outer faces keep identities")
        XCTAssertTrue(named.contains(fixture.bottomCap))
        XCTAssertTrue(named.contains(fixture.topCap))
        XCTAssertEqual(entries.count, 12, "6 outer + 6 unnamed inner")
    }

    /// Delete Face heals the hole away and the surviving faces keep their
    /// names — including the caps, whose hole boundaries the heal rewrote.
    func testDeleteFaceHealsAndKeepsNames() throws {
        let fixture = ModifierFixture()
        let base = evaluate(fixture.nodes, fixture.sketches)
        let table = try XCTUnwrap(base.faceTables[fixture.slabID])
        // ALL FOUR hole walls — a square hole only heals as a whole feature
        // (the cylindrical-bore case is one face; this one is four).
        let wallEntries = table.entries.filter {
            guard let name = $0.elementName,
                  case .profileWall = name.source else { return false }
            return name.creator == fixture.cutFeature
        }
        XCTAssertEqual(wallEntries.count, 4)
        let deleteNode = FeatureNode(
            name: "Delete Face",
            kind: .deleteFace(
                body: fixture.bodyRef,
                faces: wallEntries.map {
                    FaceRef(body: fixture.bodyRef,
                            creator: fixture.cutFeature,
                            role: $0.role,
                            signature: $0.signature,
                            elementName: $0.elementName)
                }),
            outputBodyIDs: [fixture.slabID])
        let result = evaluate(fixture.nodes + [deleteNode], fixture.sketches)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == fixture.slabID })
        // The heal restores the full 10×4×6 slab.
        XCTAssertEqual(MeasureKit.bodyVolume(body.render, scale: 1), 240,
                       accuracy: 1e-6)
        let names = try XCTUnwrap(result.faceTables[fixture.slabID])
            .entries.compactMap(\.elementName)
        XCTAssertTrue(names.contains(fixture.bottomCap))
        XCTAssertTrue(names.contains(fixture.topCap),
                      "the healed caps keep their identities: \(names)")
    }

    /// A loft between two squares names its two caps (FirstShape/LastShape)
    /// and its four walls from the FIRST section's profile edges — the
    /// tractable half of loft naming; a wall spans all sections, so later
    /// sections' identities stay deferred.
    func testALoftNamesItsCapsAndFirstSectionWalls() throws {
        let loftFeature = FeatureID(), bodyID = BodyID()
        let sketchA = SketchID(), sketchB = SketchID()
        let rectA = UUID(), rectB = UUID()
        let nodes = [
            FeatureNode(
                id: loftFeature, name: "Loft",
                kind: .loft(
                    sections: [
                        ProfileRef(sketchID: sketchA, entityIDs: [rectA],
                                   holeEntityIDs: [], seedPoint: .zero),
                        ProfileRef(sketchID: sketchB, entityIDs: [rectB],
                                   holeEntityIDs: [], seedPoint: .zero),
                    ],
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [bodyID]),
        ]
        let sketches = [
            Sketch(id: sketchA, name: "A", plane: .ground, entities: [
                .rect(id: rectA, min: SIMD2(-5, -5), max: SIMD2(5, 5))]),
            Sketch(id: sketchB, name: "B", plane: .offsetGround(y: 10), entities: [
                .rect(id: rectB, min: SIMD2(-3, -3), max: SIMD2(3, 3))]),
        ]
        let result = evaluate(nodes, sketches)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")

        let names = try XCTUnwrap(result.kernelNames[bodyID],
                                  "a loft must populate the name layer")
        XCTAssertTrue(
            names.values.contains(ElementName(creator: loftFeature,
                                              source: .profileCap(end: false))),
            "bottom cap named: \(names.values)")
        XCTAssertTrue(
            names.values.contains(ElementName(creator: loftFeature,
                                              source: .profileCap(end: true))),
            "top cap named: \(names.values)")
        let wallCount = names.values.filter {
            if case .profileWall(rectA, _) = $0.source { return true }
            return false
        }.count
        XCTAssertEqual(wallCount, 4,
                       "all four walls named from the first section: \(names.values)")
    }

    /// Replace-face is a boolean under the hood, so the faces it does NOT
    /// touch must keep their identities: extend the top cap of a named slab
    /// and the bottom cap plus all four walls still carry their names (a
    /// fillet or later boolean upstream of the replace stays bound).
    func testReplaceFaceKeepsUntouchedFaceNames() throws {
        let slabFeature = FeatureID(), replaceFeature = FeatureID()
        let slabID = BodyID(), sketch = SketchID(), rect = UUID()
        let nodes = [
            FeatureNode(
                id: slabFeature, name: "Slab",
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketch, entityIDs: [rect],
                                        holeEntityIDs: [], seedPoint: .zero),
                    plane: PlaneRef(source: .sketch(sketch)),
                    distance: Expr(value: 2), symmetric: true,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: []),
                outputBodyIDs: [slabID]),
        ]
        let sketches = [Sketch(id: sketch, name: "S", plane: .ground, entities: [
            .rect(id: rect, min: SIMD2(-5, -3), max: SIMD2(5, 3))])]
        let base = evaluate(nodes, sketches)
        XCTAssertTrue(base.errors.isEmpty, "\(base.errors)")

        let table = try XCTUnwrap(base.faceTables[slabID])
        let bottomCap = ElementName(creator: slabFeature, source: .profileCap(end: false))
        let topCap = ElementName(creator: slabFeature, source: .profileCap(end: true))
        let baseNames = try XCTUnwrap(base.kernelNames[slabID])
        XCTAssertTrue(baseNames.values.contains(topCap), "\(baseNames.values)")
        let topEntry = try XCTUnwrap(
            table.entries.first { $0.elementName == topCap },
            "the slab's top cap is named before the replace")

        let bodyRef = BodyRef(producer: slabFeature, bodyID: slabID)
        let replaceNode = FeatureNode(
            id: replaceFeature, name: "Replace Face",
            kind: .replaceFace(
                face: FaceRef(body: bodyRef, creator: slabFeature,
                              role: topEntry.role, signature: topEntry.signature,
                              elementName: topEntry.elementName),
                targetOrigin: PointWrapper(SIMD3(0, 4, 0)),
                targetNormal: PointWrapper(SIMD3(0, 1, 0)), flip: false),
            outputBodyIDs: [])
        let result = evaluate(nodes + [replaceNode], sketches)
        XCTAssertNil(result.errors[replaceFeature], "\(result.errors)")

        let names = try XCTUnwrap(result.kernelNames[slabID],
                                  "replace-face must compose the name layer")
        XCTAssertTrue(names.values.contains(bottomCap),
                      "the untouched bottom cap keeps its identity: \(names.values)")
        let wallCount = names.values.filter {
            if case .profileWall = $0.source { return true }
            return false
        }.count
        XCTAssertEqual(wallCount, 4, "all four walls keep their names: \(names.values)")
    }

    // MARK: - Opportunistic ref upgrade (step 5b)

    private func slabPushGraph(ref: FaceRef, slabFeature: FeatureID,
                               pushFeature: FeatureID, slabID: BodyID,
                               sketch: SketchID, rect: UUID)
        -> ([FeatureNode], [Sketch]) {
        let nodes = [
            FeatureNode(
                id: slabFeature, name: "Slab",
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketch, entityIDs: [rect],
                                        holeEntityIDs: [], seedPoint: .zero),
                    plane: PlaneRef(source: .sketch(sketch)),
                    distance: Expr(value: 2), symmetric: true,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: []),
                outputBodyIDs: [slabID]),
            FeatureNode(
                id: pushFeature, name: "Push",
                kind: .pushPull(face: ref, distance: Expr(value: 2),
                                mode: .planarAxial),
                outputBodyIDs: []),
        ]
        let sketches = [Sketch(id: sketch, name: "S", plane: .ground, entities: [
            .rect(id: rect, min: SIMD2(-5, -3), max: SIMD2(5, 3))])]
        return (nodes, sketches)
    }

    /// A legacy ref that resolves strongly EARNS its name during replay —
    /// and once upgraded, never proposes again.
    func testALegacyRefEarnsItsNameDuringReplay() throws {
        let slabFeature = FeatureID(), pushFeature = FeatureID()
        let slabID = BodyID(), sketch = SketchID(), rect = UUID()
        // A legacy ref carrying the top cap's honest signature and NO name.
        let legacyRef = FaceRef(
            body: BodyRef(producer: slabFeature, bodyID: slabID),
            creator: slabFeature, role: .derived(index: 0),
            signature: FaceSignature(kind: .planar, normal: SIMD3(0, 1, 0),
                                     centroid: SIMD3(0, 2, 0),
                                     area: 60, planeOffset: 2))
        let (legacyNodes, sketches) = slabPushGraph(
            ref: legacyRef, slabFeature: slabFeature, pushFeature: pushFeature,
            slabID: slabID, sketch: sketch, rect: rect)
        let base = evaluate(legacyNodes, sketches)
        XCTAssertTrue(base.errors.isEmpty, "\(base.errors)")

        // The legacy ref earned an upgrade naming the slab's top cap.
        let proposal = try XCTUnwrap(base.proposedUpgrades[pushFeature],
                                     "a strong legacy resolution must propose")
        guard case let .pushPull(face, distance, mode) = proposal else {
            return XCTFail("expected an upgraded .pushPull, got \(proposal)")
        }
        XCTAssertEqual(face.elementName,
                       ElementName(creator: slabFeature,
                                   source: .profileCap(end: true)))
        XCTAssertEqual(distance.value, 2, "payload preserved")
        XCTAssertEqual(mode, .planarAxial)
        XCTAssertEqual(base.proposedUpgrades.count, 1,
                       "nothing else has a legacy ref to upgrade")

        // Idempotence: replaying WITH the upgraded kind proposes nothing.
        let (upgradedNodes, _) = slabPushGraph(
            ref: face, slabFeature: slabFeature, pushFeature: pushFeature,
            slabID: slabID, sketch: sketch, rect: rect)
        let again = evaluate(upgradedNodes, sketches)
        XCTAssertTrue(again.errors.isEmpty)
        XCTAssertTrue(again.proposedUpgrades.isEmpty,
                      "an upgraded ref must never propose again")
    }

    /// A legacy ref sitting between two identical candidates still resolves
    /// (legacy behavior is frozen) but must NOT bake the coin flip into an
    /// identity.
    func testANearTieResolvesButNeverUpgrades() throws {
        let (body, table, _, cutB) = try twoHoleFixture()
        let wallB = try plusXWall(of: cutB, in: table)
        var midway = wallB.signature
        midway.centroid.x = 0
        midway.planeOffset = simd_dot(midway.normal, midway.centroid)
        let legacyRef = FaceRef(
            body: BodyRef(producer: cutB, bodyID: body.id), creator: cutB,
            role: .derived(index: 0), signature: midway)
        let naming = SignatureNaming()
        let resolved = try XCTUnwrap(naming.resolve(legacyRef, in: body,
                                                    table: table))
        XCTAssertNil(ElementNaming.upgraded(legacyRef, from: resolved),
                     "margin \(String(describing: resolved.margin)) is a "
                     + "near-tie — no upgrade")
    }

    /// Step 5b for EDGES: a legacy blend `EdgeRef` (no faceNames) that
    /// resolves by signature on a named body earns the crease's name pair —
    /// so the next rebuild binds by identity, immune to signature drift. The
    /// name comes from the kernel edge at the ref's own resolved midpoint, so
    /// it pins exactly the edge blended, never re-binding.
    func testALegacyBlendEdgeRefEarnsItsCreaseName() throws {
        let fixture = ModifierFixture()
        let base = evaluate(fixture.nodes, fixture.sketches)
        XCTAssertTrue(base.errors.isEmpty, "\(base.errors)")
        let body = try XCTUnwrap(base.bodies.first { $0.id == fixture.slabID })
        let brep = try XCTUnwrap(body.brep)
        let names = try XCTUnwrap(base.kernelNames[fixture.slabID])
        let edgeNames = ElementNaming.edgeNames(
            adjacency: OCCTKernel.edgeFaceAdjacency(brep), names: names)

        // A selectable render edge whose midpoint maps to a NAMED kernel
        // crease — the case a legacy fillet on it earns.
        let available = EdgeTopology.selectableEdges(from: body.render)
        let tol = OCCTKernel.matchTolerance(for: brep)
        func mid(_ e: SelectableEdge) -> SIMD3<Double> {
            let m = e.midpoint
            return SIMD3(Double(m.x), Double(m.y), Double(m.z))
        }
        var chosen: (edge: SelectableEdge, name: EdgeName)?
        for e in available {
            if let idx = OCCTKernel.nearestEdgeIndex(brep, to: mid(e), tolerance: tol),
               let name = edgeNames[idx] { chosen = (e, name); break }
        }
        let (edge, expected) = try XCTUnwrap(chosen, "no named selectable edge")

        let legacy = FeatureNode(
            id: FeatureID(), name: "Fillet",
            kind: .fillet(body: fixture.bodyRef,
                          edges: [EdgeRef(body: fixture.bodyRef,
                                          signature: EdgeTopology.signature(of: edge),
                                          faceNames: nil)],
                          radius: Expr(value: 0.3)),
            outputBodyIDs: [fixture.slabID])
        let result = evaluate(fixture.nodes + [legacy], fixture.sketches)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")

        let proposal = try XCTUnwrap(result.proposedUpgrades[legacy.id],
                                     "a legacy blend ref must earn its name")
        guard case let .fillet(_, edges, _) = proposal else {
            return XCTFail("upgrade must stay a fillet: \(proposal)")
        }
        XCTAssertEqual(try XCTUnwrap(edges.first?.faceNames), expected,
                       "the earned name is the crease at the resolved edge")

        // Idempotence: an already-named ref takes the identity path and
        // proposes nothing.
        let named = FeatureNode(
            id: FeatureID(), name: "Fillet2",
            kind: .fillet(body: fixture.bodyRef,
                          edges: [EdgeRef(body: fixture.bodyRef,
                                          signature: EdgeTopology.signature(of: edge),
                                          faceNames: expected)],
                          radius: Expr(value: 0.3)),
            outputBodyIDs: [fixture.slabID])
        let again = evaluate(fixture.nodes + [named], fixture.sketches)
        XCTAssertNil(again.proposedUpgrades[named.id],
                     "an already-named blend ref never proposes again")
    }

    // MARK: - Revolve/sweep naming (the last naming-mission deferral)

    /// A full-revolve washer: every wall face named for its profile entity;
    /// no caps (a 360° revolve has none — the in-result gate eats
    /// FirstShape/LastShape for free).
    func testARevolveNamesItsWallsFromTheProfile() throws {
        let entities = [UUID(), UUID(), UUID(), UUID()]
        let plane = SketchPlane(origin: .zero, xAxis: SIMD3(1, 0, 0),
                                yAxis: SIMD3(0, 1, 0))
        let profile = Profile(
            loop: [SIMD2(4, 0), SIMD2(6, 0), SIMD2(6, 3), SIMD2(4, 3)],
            kind: .polygonal, sourceEntityIDs: Set(entities),
            edgeEntityIDs: entities)
        let history = OCCTShapeHistory()
        let washer = try XCTUnwrap(OCCTKernel.revolveSolid(
            outer: profile, holes: [], plane: plane,
            axisOrigin: .zero, axisDirection: SIMD3(0, 1, 0),
            angleRadians: 2 * .pi, history: history))
        _ = washer
        let ancestry = ShapeAncestry(history)
        let names = ElementNaming.extrudeNames(
            creator: creator, ancestry: ancestry,
            outer: profile, holes: [])
        XCTAssertEqual(names.count, 4,
                       "names=\(names) rows=\(ancestry.rows) rowCount=\(history.rowCount)")
        let sources = Set(names.values.map(\.source))
        for entity in entities {
            XCTAssertTrue(sources.contains(
                .profileWall(entity: entity, occurrence: 0)),
                "each profile edge owns one revolved face")
        }
    }

    /// A HALF revolve keeps its two profile-face caps, named start/end.
    func testAPartialRevolveNamesItsCaps() throws {
        let plane = SketchPlane(origin: .zero, xAxis: SIMD3(1, 0, 0),
                                yAxis: SIMD3(0, 1, 0))
        let profile = Profile(
            loop: [SIMD2(4, 0), SIMD2(6, 0), SIMD2(6, 3), SIMD2(4, 3)],
            kind: .polygonal, sourceEntityIDs: [UUID()])
        let history = OCCTShapeHistory()
        _ = try XCTUnwrap(OCCTKernel.revolveSolid(
            outer: profile, holes: [], plane: plane,
            axisOrigin: .zero, axisDirection: SIMD3(0, 1, 0),
            angleRadians: .pi, history: history))
        let names = ElementNaming.extrudeNames(
            creator: creator, ancestry: ShapeAncestry(history),
            outer: profile, holes: [])
        let sources = Set(names.values.map(\.source))
        XCTAssertTrue(sources.contains(.profileCap(end: false)), "\(sources)")
        XCTAssertTrue(sources.contains(.profileCap(end: true)))
    }

    /// A sweep along a two-segment spine generates TWO faces from the one
    /// circle edge: the first inherits the wall identity, the sibling mints
    /// as its opFace child — never a duplicated name.
    func testASweepSiblingFaceMintsInsteadOfDuplicating() throws {
        let entity = UUID()
        let circle = (0..<32).map { i -> SIMD2<Double> in
            let a = Double(i) / 32 * 2 * .pi
            return SIMD2(3 * cos(a), 3 * sin(a))
        }
        let plane = SketchPlane(origin: .zero, xAxis: SIMD3(0, 1, 0),
                                yAxis: SIMD3(0, 0, 1))
        let profile = Profile(loop: circle,
                              kind: .circle(center: .zero, radius: 3),
                              sourceEntityIDs: [entity])
        let history = OCCTShapeHistory()
        _ = try XCTUnwrap(OCCTKernel.sweepSolid(
            outer: profile, holes: [], plane: plane,
            spine: [SIMD3(0, 0, 0), SIMD3(20, 0, 0), SIMD3(20, 20, 0)],
            history: history))
        let names = ElementNaming.extrudeNames(
            creator: creator, ancestry: ShapeAncestry(history),
            outer: profile, holes: [])
        XCTAssertEqual(Set(names.values).count, names.count,
                       "no duplicate names: \(names)")
        let wall = ElementName(creator: creator,
                               source: .profileWall(entity: entity, occurrence: 0))
        XCTAssertTrue(names.values.contains(wall))
        XCTAssertTrue(names.values.contains { name in
            guard case let .opFace(_, parents, _) = name.source else { return false }
            return parents == [wall]
        }, "the second segment's face is the wall's minted sibling: \(names)")
    }

    /// End to end: a revolve node's eval populates the composable name layer
    /// even though its render stays Euclid (no table attach — the kernel-side
    /// consumers key on indices).
    func testARevolveEvalPopulatesKernelNames() throws {
        let sketchID = SketchID(), rectEntity = UUID()
        let feature = FeatureID(), bodyID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: feature, name: "Washer",
                kind: .revolve(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [rectEntity],
                                        holeEntityIDs: [], seedPoint: SIMD2(5, 1.5)),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    axis: AxisRef(source: .explicit(RevolveAxis(
                        point: .zero, direction: SIMD2(0, 1)))),
                    angle: Expr(value: 360),
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: [])),
                outputBodyIDs: [bodyID]),
        ])
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .rect(id: rectEntity, min: SIMD2(4, 0), max: SIMD2(6, 3))])
        var revision: UInt64 = 0
        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let names = try XCTUnwrap(result.kernelNames[bodyID],
                                  "a revolve must populate the name layer")
        XCTAssertEqual(names.count, 4, "\(names)")
        XCTAssertTrue(names.values.allSatisfy { name in
            if case .profileWall(rectEntity, _) = name.source { return true }
            return false
        }, "\(names)")
    }

    // MARK: - Mirror/pattern name inheritance

    /// A mirror is a copying isometry, so names carry over BY INDEX — and the
    /// index alignment is pinned geometrically: face k of the copy sits at
    /// the reflection of face k of the source.
    func testAMirrorCopyInheritsNamesByIndex() throws {
        let sketchID = SketchID(), rectEntity = UUID()
        let extrude = FeatureID(), mirror = FeatureID()
        let sourceID = BodyID(), copyID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: extrude, name: "Block",
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [rectEntity],
                                        holeEntityIDs: [], seedPoint: SIMD2(5, 5)),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    distance: Expr(value: 10), symmetric: false,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: []),
                outputBodyIDs: [sourceID]),
            FeatureNode(
                id: mirror, name: "Block Mirror",
                kind: .mirror(body: BodyRef(producer: extrude, bodyID: sourceID),
                              plane: PlaneRef(source: .sketch(sketchID)),
                              keepOriginal: true),
                outputBodyIDs: [copyID]),
        ])
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .rect(id: rectEntity, min: SIMD2(2, 2), max: SIMD2(9, 8))])
        var revision: UInt64 = 0
        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let sourceNames = try XCTUnwrap(result.kernelNames[sourceID])
        XCTAssertEqual(result.kernelNames[copyID], sourceNames,
                       "the reflected copy shares its source's name map")
        let sourceBrep = try XCTUnwrap(
            result.bodies.first { $0.id == sourceID }?.brep)
        let copyBrep = try XCTUnwrap(
            result.bodies.first { $0.id == copyID }?.brep)
        let sourceFaces = Dictionary(
            uniqueKeysWithValues: OCCTKernel.faceInfo(sourceBrep)
                .map { ($0.index, $0.centroid) })
        let copyFaces = Dictionary(
            uniqueKeysWithValues: OCCTKernel.faceInfo(copyBrep)
                .map { ($0.index, $0.centroid) })
        XCTAssertEqual(sourceFaces.count, copyFaces.count)
        for (index, c) in sourceFaces {
            // Ground-plane mirror: y -> -y.
            let reflected = SIMD3(c.x, -c.y, c.z)
            let got = try XCTUnwrap(copyFaces[index])
            XCTAssertLessThan(simd_distance(reflected, got), 1e-6,
                              "face \(index) drifted: the by-index inherit "
                              + "would name the wrong face")
        }
    }

    /// A pattern copy shares the source's solid outright, so its names are
    /// the source's, verbatim.
    func testAPatternCopyInheritsNames() throws {
        let sketchID = SketchID(), rectEntity = UUID()
        let extrude = FeatureID(), pattern = FeatureID()
        let sourceID = BodyID(), copyID = BodyID()
        let graph = FeatureGraph(nodes: [
            FeatureNode(
                id: extrude, name: "Block",
                kind: .extrude(
                    profile: ProfileRef(sketchID: sketchID, entityIDs: [rectEntity],
                                        holeEntityIDs: [], seedPoint: SIMD2(5, 5)),
                    plane: PlaneRef(source: .sketch(sketchID)),
                    distance: Expr(value: 10), symmetric: false,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                    extraProfiles: []),
                outputBodyIDs: [sourceID]),
            FeatureNode(
                id: pattern, name: "Row",
                kind: .pattern(body: BodyRef(producer: extrude, bodyID: sourceID),
                               spec: PatternSpec(kind: .linear,
                                                 axis: SIMD3(1, 0, 0),
                                                 count: 2, spacing: 50)),
                outputBodyIDs: [copyID]),
        ])
        let sketch = Sketch(id: sketchID, name: "S", plane: .ground, entities: [
            .rect(id: rectEntity, min: SIMD2(2, 2), max: SIMD2(9, 8))])
        var revision: UInt64 = 0
        let result = graph.evaluate(sketches: [sketch], planes: [],
                                    naming: SignatureNaming(),
                                    nextRevision: { revision += 1; return revision })
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let sourceNames = try XCTUnwrap(result.kernelNames[sourceID])
        XCTAssertEqual(sourceNames.count, 6, "4 walls + 2 caps: \(sourceNames)")
        XCTAssertEqual(result.kernelNames[copyID], sourceNames)
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
