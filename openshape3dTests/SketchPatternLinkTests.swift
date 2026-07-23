//
//  SketchPatternLinkTests.swift
//  openshape3dTests
//
//  Spec §2.5 — the sketch pattern CONSTRAINT. The behaviour that distinguishes
//  a pattern constraint from a plain copy is propagation: edit the seed and
//  every instance follows. Deleting the link must leave the instances behind as
//  ordinary entities.
//

import XCTest
import simd
@testable import openshape3d

final class SketchPatternLinkTests: XCTestCase {

    private let seedID = UUID()

    private func seedCircle(at x: Double = 0, radius: Double = 2) -> SketchEntity {
        .circle(id: seedID, center: SIMD2(x, 0), radius: radius)
    }

    private var linearSpec: PatternSpec {
        PatternSpec(kind: .linear, axis: SIMD3(1, 0, 0), count: 4, spacing: 10)
    }

    private func patternedSketch() -> Sketch {
        let seed = seedCircle()
        guard let made = SketchPatternKit.makePattern(seeds: [seed], spec: linearSpec) else {
            XCTFail("pattern should build"); return Sketch(plane: .ground)
        }
        return Sketch(plane: .ground,
                      entities: [seed] + made.instances,
                      patternLinks: [made.link])
    }

    // MARK: Creation

    func testPatternEmitsCountMinusOneCopiesAndLinksThem() throws {
        let sketch = patternedSketch()
        // count = 4 total ⇒ seed + 3 copies.
        XCTAssertEqual(sketch.entities.count, 4)
        let link = try XCTUnwrap(sketch.patternLinks.first)
        XCTAssertEqual(link.seedIDs, [seedID])
        XCTAssertEqual(link.instanceIDs.count, 3, "three linked copies")
    }

    func testDegeneratePatternsAreRefused() {
        XCTAssertNil(SketchPatternKit.makePattern(seeds: [], spec: linearSpec),
                     "no seed ⇒ no pattern")
        XCTAssertNil(SketchPatternKit.makePattern(
            seeds: [seedCircle()],
            spec: PatternSpec(kind: .linear, axis: SIMD3(1, 0, 0), count: 1, spacing: 10)),
            "a count of 1 is just the seed — no link should be created")
    }

    // MARK: Propagation — the whole point of §2.5

    func testEditingTheSeedRegeneratesEveryInstance() throws {
        var sketch = patternedSketch()

        // Grow the seed circle; instances must follow.
        sketch.entities[0] = seedCircle(radius: 5)
        sketch = SketchPatternKit.regenerate(sketch)

        for entity in sketch.entities {
            guard case let .circle(_, _, radius) = entity else {
                return XCTFail("pattern of circles should stay circles")
            }
            XCTAssertEqual(radius, 5, accuracy: 1e-9,
                           "every instance follows the seed's new radius")
        }
    }

    func testInstanceIdentityIsPreservedAcrossRegeneration() throws {
        var sketch = patternedSketch()
        let idsBefore = sketch.entities.map(\.id)

        sketch.entities[0] = seedCircle(radius: 7)
        sketch = SketchPatternKit.regenerate(sketch)

        XCTAssertEqual(sketch.entities.map(\.id), idsBefore,
                       "IDs must survive so selections and references stay valid")
    }

    func testInstancesKeepTheirPatternSpacingAfterAnEdit() throws {
        var sketch = patternedSketch()
        sketch.entities[0] = seedCircle(at: 3, radius: 2)   // move the seed
        sketch = SketchPatternKit.regenerate(sketch)

        let centres: [Double] = sketch.entities.compactMap {
            if case let .circle(_, c, _) = $0 { return c.x }
            return nil
        }.sorted()
        XCTAssertEqual(centres, [3, 13, 23, 33],
                       "copies stay one spacing apart, anchored to the moved seed")
    }

    // MARK: Membership + unlink

    func testAnyMemberResolvesBackToTheLink() throws {
        let sketch = patternedSketch()
        let link = try XCTUnwrap(sketch.patternLinks.first)
        // Re-selecting ANY member must re-activate the pattern (spec §2.5).
        XCTAssertEqual(SketchPatternKit.link(owning: seedID, in: sketch)?.id, link.id)
        let anInstance = try XCTUnwrap(link.instanceIDs.first?.first)
        XCTAssertEqual(SketchPatternKit.link(owning: anInstance, in: sketch)?.id, link.id)
        XCTAssertNil(SketchPatternKit.link(owning: UUID(), in: sketch))
    }

    func testUnlinkLeavesInstancesAsIndividualEntities() throws {
        var sketch = patternedSketch()
        let link = try XCTUnwrap(sketch.patternLinks.first)
        let countBefore = sketch.entities.count

        sketch = SketchPatternKit.unlink(link.id, in: sketch)
        XCTAssertTrue(sketch.patternLinks.isEmpty, "the constraint is gone")
        XCTAssertEqual(sketch.entities.count, countBefore,
                       "instances remain — they just stop following the seed")

        // Editing the seed now changes nothing else.
        sketch.entities[0] = seedCircle(radius: 9)
        let after = SketchPatternKit.regenerate(sketch)
        if case let .circle(_, _, r) = after.entities[1] {
            XCTAssertEqual(r, 2, accuracy: 1e-9, "unlinked copy keeps its own radius")
        } else {
            XCTFail("expected a circle")
        }
    }

    func testDeletingTheSeedDropsTheLinkButKeepsTheCopies() {
        var sketch = patternedSketch()
        let countBefore = sketch.entities.count
        sketch.entities.removeAll { $0.id == self.seedID }

        sketch = SketchPatternKit.regenerate(sketch)
        XCTAssertTrue(sketch.patternLinks.isEmpty,
                      "a link with no seed cannot regenerate, so it is dropped")
        XCTAssertEqual(sketch.entities.count, countBefore - 1,
                       "the copies survive as ordinary entities")
    }

    // MARK: Persistence

    func testPatternLinksSurviveACodableRoundTrip() throws {
        let sketch = patternedSketch()
        let data = try JSONEncoder().encode(sketch)
        let back = try JSONDecoder().decode(Sketch.self, from: data)
        XCTAssertEqual(back.patternLinks, sketch.patternLinks)
    }

    func testPreExistingSketchesDecodeWithoutPatternLinks() throws {
        // A document written before §2.5 has no patternLinks key at all.
        let json = """
        {"id":{"raw":"\(UUID().uuidString)"},"plane":{"origin":[0,0,0],\
        "xAxis":[1,0,0],"yAxis":[0,0,-1]},"entities":[]}
        """
        let sketch = try JSONDecoder().decode(Sketch.self, from: Data(json.utf8))
        XCTAssertTrue(sketch.patternLinks.isEmpty, "older documents must still load")
    }
}
