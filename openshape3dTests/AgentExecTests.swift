//
//  AgentExecTests.swift
//  openshape3dTests
//
//  The parsing half of `/v1/exec`. Pure statics only — no `EditorViewModel`
//  (STATUS_AND_NEXT_STEPS gotcha 1), which is exactly why `AgentExec` decides
//  everything it can before the main-actor hop.
//
//  What these tests are really defending: an agent cannot see a dialog or a
//  disabled button, so every way a request can be wrong has to come back as a
//  DISTINCT, named code. A single "bad_request" for all of them would make the
//  endpoint unusable in a loop — the agent would have no idea which knob to
//  turn — so most of what follows asserts on the code, not just on failure.
//

import XCTest
import simd
@testable import openshape3d

final class AgentExecTests: XCTestCase {

    // MARK: Sweep

    func testSweepParsesSpineAndRejectsShortOnes() throws {
        let id = UUID().uuidString
        let parsed = op(#"{"op":"feature.sweep","args":{"sketchID":"\#(id)","seedPoint":[1,2],"spine":[[0,0,0],[10,0,0],[10,5,0]]}}"#)
        guard case let .sweep(_, seed, spine, boolean, targets)? = parsed else {
            return XCTFail("expected .sweep, got \(String(describing: parsed))")
        }
        XCTAssertEqual(seed, SIMD2(1, 2))
        XCTAssertEqual(spine.count, 3)
        XCTAssertEqual(spine[1], SIMD3(10, 0, 0))
        XCTAssertEqual(boolean, .newBody)
        XCTAssertTrue(targets.isEmpty)
        XCTAssertEqual(code(#"{"op":"feature.sweep","args":{"sketchID":"\#(id)","seedPoint":[0,0],"spine":[[0,0,0]]}}"#),
                       "missing_spine", "a one-point spine is no path")
    }

    func testLoftParsesSectionsAndRejectsFewerThanTwo() throws {
        let a = UUID().uuidString, b = UUID().uuidString
        let parsed = op(#"{"op":"feature.loft","args":{"sections":[{"sketchID":"\#(a)","seedPoint":[0,0]},{"sketchID":"\#(b)","seedPoint":[1,1]}]}}"#)
        guard case let .loft(sections, boolean, targets)? = parsed else {
            return XCTFail("expected .loft, got \(String(describing: parsed))")
        }
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].sketch.raw.uuidString, a)
        XCTAssertEqual(sections[1].seed, SIMD2(1, 1))
        XCTAssertEqual(boolean, .newBody)
        XCTAssertTrue(targets.isEmpty)
        // One section is not a loft; a bad seed is named by section index.
        XCTAssertEqual(code(#"{"op":"feature.loft","args":{"sections":[{"sketchID":"\#(a)","seedPoint":[0,0]}]}}"#),
                       "missing_sections")
        XCTAssertEqual(code(#"{"op":"feature.loft","args":{"sections":[{"sketchID":"\#(a)","seedPoint":[0,0]},{"sketchID":"\#(b)"}]}}"#),
                       "missing_seedPoint")
    }

    // MARK: Delete/replace face

    func testDeleteFaceParsesAndRejectsEmpty() throws {
        let id = UUID().uuidString
        let parsed = op(#"{"op":"feature.deleteFace","args":{"bodyID":"\#(id)","faces":[3,4]}}"#)
        guard case let .deleteFace(_, faces)? = parsed else {
            return XCTFail("expected .deleteFace")
        }
        XCTAssertEqual(faces, [3, 4])
        XCTAssertEqual(code(#"{"op":"feature.deleteFace","args":{"bodyID":"\#(id)","faces":[]}}"#),
                       "missing_faces")
    }

    func testReplaceFaceParsesPlaneAndRejectsDegenerateNormal() throws {
        let id = UUID().uuidString
        let parsed = op(#"{"op":"feature.replaceFace","args":{"bodyID":"\#(id)","face":[2],"targetOrigin":[0,5,0],"targetNormal":[0,2,0],"flip":true}}"#)
        guard case let .replaceFace(_, face, origin, normal, flip)? = parsed else {
            return XCTFail("expected .replaceFace")
        }
        XCTAssertEqual(face, 2)
        XCTAssertEqual(origin, SIMD3(0, 5, 0))
        XCTAssertEqual(normal, SIMD3(0, 1, 0), "normal comes back normalized")
        XCTAssertTrue(flip)
        XCTAssertEqual(code(#"{"op":"feature.replaceFace","args":{"bodyID":"\#(id)","face":[2],"targetOrigin":[0,5,0],"targetNormal":[0,0,0]}}"#),
                       "missing_targetNormal")
        XCTAssertEqual(code(#"{"op":"feature.replaceFace","args":{"bodyID":"\#(id)","face":[2,3],"targetOrigin":[0,5,0],"targetNormal":[0,1,0]}}"#),
                       "bad_face", "exactly one face")
    }

    // MARK: Blends + shell (identity-addressed, step 4b/5 wiring)

    func testFilletParsesEdgesAndRadius() throws {
        let id = UUID().uuidString
        let parsed = op(#"{"op":"feature.fillet","args":{"bodyID":"\#(id)","radius":1.5,"edges":[3,7]}}"#)
        guard case let .blend(body, isFillet, amount, edges)? = parsed else {
            return XCTFail("expected .blend, got \(String(describing: parsed))")
        }
        XCTAssertEqual(body.raw.uuidString, id)
        XCTAssertTrue(isFillet)
        XCTAssertEqual(amount, 1.5)
        XCTAssertEqual(edges, [3, 7])
    }

    func testChamferUsesSetbackAndFilletUsesRadius() {
        let id = UUID().uuidString
        XCTAssertEqual(code(#"{"op":"feature.chamfer","args":{"bodyID":"\#(id)","radius":1,"edges":[1]}}"#),
                       "missing_setback", "chamfer must not accept radius")
        XCTAssertEqual(code(#"{"op":"feature.fillet","args":{"bodyID":"\#(id)","setback":1,"edges":[1]}}"#),
                       "missing_radius")
    }

    func testBlendRefusesEmptyZeroOrNegativeIndices() {
        let id = UUID().uuidString
        XCTAssertEqual(code(#"{"op":"feature.fillet","args":{"bodyID":"\#(id)","radius":1,"edges":[]}}"#),
                       "missing_edges")
        XCTAssertEqual(code(#"{"op":"feature.fillet","args":{"bodyID":"\#(id)","radius":1,"edges":[0]}}"#),
                       "bad_index", "indices are 1-based; 0 is a typo")
        XCTAssertEqual(code(#"{"op":"feature.fillet","args":{"bodyID":"\#(id)","radius":-2,"edges":[1]}}"#),
                       "bad_radius")
    }

    func testShellParsesAndAllowsAClosedHollow() throws {
        let id = UUID().uuidString
        let open = op(#"{"op":"feature.shell","args":{"bodyID":"\#(id)","thickness":0.5,"openFaces":[2]}}"#)
        guard case let .shell(_, thickness, faces)? = open else {
            return XCTFail("expected .shell")
        }
        XCTAssertEqual(thickness, 0.5)
        XCTAssertEqual(faces, [2])
        // Absent openFaces = fully-enclosed hollow, not an error.
        let closed = op(#"{"op":"feature.shell","args":{"bodyID":"\#(id)","thickness":0.5}}"#)
        guard case let .shell(_, _, none)? = closed else {
            return XCTFail("expected .shell")
        }
        XCTAssertTrue(none.isEmpty)
        XCTAssertEqual(code(#"{"op":"feature.shell","args":{"bodyID":"\#(id)","thickness":0}}"#),
                       "bad_thickness")
    }

    // MARK: Helpers

    private func parse(_ json: String) -> Result<AgentExecOp, AgentExecError> {
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        return AgentExec.parse(object)
    }

    private func code(_ json: String, _ file: StaticString = #filePath, _ line: UInt = #line) -> String {
        switch parse(json) {
        case .success(let op):
            XCTFail("expected a failure, got \(op)", file: file, line: line)
            return ""
        case .failure(let error):
            return error.code
        }
    }

    private func op(_ json: String, _ file: StaticString = #filePath, _ line: UInt = #line) -> AgentExecOp? {
        switch parse(json) {
        case .success(let op): return op
        case .failure(let error):
            XCTFail("expected success, got \(error.code): \(error.message)", file: file, line: line)
            return nil
        }
    }

    private let sketchUUID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
    private let bodyUUID   = "3F2504E0-4F89-11D3-9A0C-0305E82C3302"

    // MARK: Dispatch

    func testUnknownOpNamesTheAlternatives() {
        switch parse(#"{"op":"feature.bevel"}"#) {
        case .success: XCTFail("unknown op should not parse")
        case .failure(let error):
            XCTAssertEqual(error.code, "unknown_op")
            // The list is the whole point: an agent that guessed wrong needs to
            // see what it could have said instead.
            XCTAssertTrue(error.message.contains("feature.extrude"), error.message)
        }
    }

    func testMissingOpAndMissingBodyAreDistinct() {
        XCTAssertEqual(code(#"{"args":{}}"#), "missing_op")
        switch AgentExec.parse(nil) {
        case .failure(let e): XCTAssertEqual(e.code, "missing_body")
        case .success: XCTFail("nil body should not parse")
        }
    }

    // MARK: sketch.create

    func testCreateSketchDefaultsToGround() {
        guard case let .createSketch(name, plane)? = op(#"{"op":"sketch.create"}"#) else { return }
        XCTAssertEqual(name, "Sketch")
        XCTAssertEqual(plane, .ground)
    }

    func testCreateSketchNormalizesAxes() {
        // Deliberately non-unit input: a caller working in metres or reading
        // axes off another tool should not have to normalize first.
        guard case let .createSketch(_, plane)? = op("""
        {"op":"sketch.create","args":{"name":"Side","origin":[1,2,3],
         "xAxis":[5,0,0],"yAxis":[0,9,0]}}
        """) else { return }
        XCTAssertEqual(plane.origin, SIMD3(1, 2, 3))
        XCTAssertEqual(simd_length(plane.xAxis), 1, accuracy: 1e-12)
        XCTAssertEqual(simd_length(plane.yAxis), 1, accuracy: 1e-12)
    }

    func testParallelAxesAreRejected() {
        XCTAssertEqual(code("""
        {"op":"sketch.create","args":{"xAxis":[1,0,0],"yAxis":[2,0,0]}}
        """), "degenerate_plane")
    }

    // MARK: sketch.addEntities

    func testEntityKindsThatTheShaprFormatUses() {
        guard case let .addEntities(_, entities, _)? = op("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchUUID)","entities":[
          {"kind":"line","a":[0,0],"b":[10,0]},
          {"kind":"circle","center":[5,5],"radius":2.5},
          {"kind":"arc","center":[0,0],"radius":4,"startAngle":0,"endAngle":1.57},
          {"kind":"spline","points":[[0,0],[1,2],[3,1]],"closed":false}
        ]}}
        """) else { return }
        XCTAssertEqual(entities.count, 4)
        guard case .line = entities[0] else { return XCTFail("0 should be a line") }
        guard case .circle = entities[1] else { return XCTFail("1 should be a circle") }
        guard case .arc = entities[2] else { return XCTFail("2 should be an arc") }
        guard case .spline = entities[3] else { return XCTFail("3 should be a spline") }
    }

    func testClosedPrimitiveEntitiesParse() {
        guard case let .addEntities(_, entities, _)? = op("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchUUID)","entities":[
          {"kind":"rect","min":[10,8],"max":[0,0]},
          {"kind":"polygon","center":[0,0],"radius":13.856,"sides":6},
          {"kind":"ellipse","center":[1,2],"radiusX":5,"radiusY":3}
        ]}}
        """) else { return }
        XCTAssertEqual(entities.count, 3)
        // rect normalizes corners so min is the lower-left regardless of order.
        guard case let .rect(_, mn, mx) = entities[0] else { return XCTFail("0 rect") }
        XCTAssertEqual(mn, SIMD2(0, 0))
        XCTAssertEqual(mx, SIMD2(10, 8))
        guard case let .polygon(_, _, r, sides, rot) = entities[1] else { return XCTFail("1 polygon") }
        XCTAssertEqual(sides, 6)
        XCTAssertEqual(r, 13.856, accuracy: 1e-9)
        XCTAssertEqual(rot, 0, "rotation defaults to 0")
        guard case let .ellipse(_, _, rx, ry, _) = entities[2] else { return XCTFail("2 ellipse") }
        XCTAssertEqual(rx, 5); XCTAssertEqual(ry, 3)
    }

    func testClosedPrimitivesRejectDegenerateArgs() {
        let head = #"{"op":"sketch.addEntities","args":{"sketchID":"\#(sketchUUID)","entities":["#
        XCTAssertEqual(code(head + #"{"kind":"rect","min":[0,0],"max":[0,5]}]}}"#), "degenerate_rect")
        XCTAssertEqual(code(head + #"{"kind":"polygon","center":[0,0],"radius":2,"sides":2}]}}"#), "bad_sides")
        XCTAssertEqual(code(head + #"{"kind":"polygon","center":[0,0],"radius":2,"sides":5.5}]}}"#), "bad_sides")
        XCTAssertEqual(code(head + #"{"kind":"ellipse","center":[0,0],"radiusX":0,"radiusY":3}]}}"#), "bad_radius")
    }

    func testConstructionIndicesAreKeptAndBoundsChecked() {
        guard case let .addEntities(_, entities, construction)? = op("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchUUID)",
         "entities":[{"kind":"line","a":[0,0],"b":[1,0]}],
         "construction":[0, 7, -1]}}
        """) else { return }
        XCTAssertEqual(entities.count, 1)
        // 7 and -1 index nothing; keeping them would crash the applier later.
        XCTAssertEqual(construction, [0])
    }

    func testBadEntitiesAreNamedByIndex() {
        switch parse("""
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchUUID)","entities":[
          {"kind":"line","a":[0,0],"b":[1,1]},
          {"kind":"trapezoid"}
        ]}}
        """) {
        case .success: XCTFail("unknown entity kind should not parse")
        case .failure(let error):
            XCTAssertEqual(error.code, "unknown_entity_kind")
            // Which one is wrong matters when a sketch has forty of them.
            XCTAssertTrue(error.message.contains("entities[1]"), error.message)
        }
    }

    func testDegenerateGeometryIsRejected() {
        let head = #"{"op":"sketch.addEntities","args":{"sketchID":"\#(sketchUUID)","entities":["#
        XCTAssertEqual(code(head + #"{"kind":"line","a":[2,2],"b":[2,2]}]}}"#), "degenerate_line")
        XCTAssertEqual(code(head + #"{"kind":"circle","center":[0,0],"radius":0}]}}"#), "bad_radius")
        XCTAssertEqual(code(head + #"{"kind":"spline","points":[[0,0]]}]}}"#), "bad_spline")
    }

    // MARK: feature.extrude

    func testExtrudeCarriesSeedAndDistance() {
        guard case let .extrude(sketch, seed, distance, symmetric, boolean, targets)?
            = op("""
            {"op":"feature.extrude","args":{"sketchID":"\(sketchUUID)",
             "seedPoint":[3,4],"distance":12,"symmetric":true}}
            """) else { return }
        XCTAssertEqual(sketch.raw.uuidString, sketchUUID)
        XCTAssertEqual(seed, SIMD2(3, 4))
        XCTAssertEqual(distance, 12)
        XCTAssertTrue(symmetric)
        XCTAssertEqual(boolean, .newBody)
        XCTAssertTrue(targets.isEmpty)
    }

    func testZeroDistanceExtrudeIsRefusedRatherThanSilentlyDoingNothing() {
        XCTAssertEqual(code("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchUUID)","seedPoint":[0,0],"distance":0}}
        """), "zero_distance")
    }

    func testBooleanExtrudeWithoutTargetsIsRefused() {
        // The trap this guards: `subtract` with no targets is a perfectly
        // well-formed request that quietly produces a NEW BODY instead of
        // cutting anything — the agent would see "ok" and a wrong model.
        XCTAssertEqual(code("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchUUID)","seedPoint":[0,0],
         "distance":5,"boolean":"subtract"}}
        """), "missing_boolean_targets")
    }

    func testBooleanExtrudeWithTargetsParses() {
        guard case let .extrude(_, _, _, _, boolean, targets)? = op("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchUUID)","seedPoint":[0,0],
         "distance":5,"boolean":"subtract","booleanTargets":["\(bodyUUID)"]}}
        """) else { return }
        XCTAssertEqual(boolean, .subtract)
        XCTAssertEqual(targets.map(\.raw.uuidString), [bodyUUID])
    }

    func testBooleanAsAnObjectIsRefusedNotSilentlyANewBody() {
        // The FreeCAD-tutorial footgun: writing the op as a nested object
        // {"boolean":{"kind":"subtract"}} used to fail the string cast and
        // fall to the newBody default — a cut that silently became a stray
        // solid. It must be a typed refusal now, distinct from a bad op name.
        XCTAssertEqual(code("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchUUID)","seedPoint":[0,0],
         "distance":5,"boolean":{"kind":"subtract"},"booleanTargets":["\(bodyUUID)"]}}
        """), "bad_boolean_type")
        // A number is equally wrong-typed.
        XCTAssertEqual(code("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchUUID)","seedPoint":[0,0],
         "distance":5,"boolean":1}}
        """), "bad_boolean_type")
        // A bad STRING op stays its own distinct error (not conflated).
        XCTAssertEqual(code("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchUUID)","seedPoint":[0,0],
         "distance":5,"boolean":"nope"}}
        """), "unknown_boolean_op")
    }

    // MARK: feature.revolve

    func testRevolveKeepsDegreesAndNormalizesTheAxis() {
        guard case let .revolve(_, _, axis, angle, _, _)? = op("""
        {"op":"feature.revolve","args":{"sketchID":"\(sketchUUID)","seedPoint":[1,1],
         "axisPoint":[0,0],"axisDirection":[0,4],"angleDegrees":90}}
        """) else { return }
        // The graph's revolve Expr is in DEGREES — FeatureGraph converts once
        // at the OCCT boundary. Converting here as well produced a 6.28-degree
        // revolve that looked like a real solid and was silently wrong.
        XCTAssertEqual(angle, 90, accuracy: 1e-12)
        XCTAssertEqual(simd_length(axis.direction), 1, accuracy: 1e-12)
    }

    func testRevolveDefaultsToAFullTurn() {
        guard case let .revolve(_, _, _, angle, _, _)? = op("""
        {"op":"feature.revolve","args":{"sketchID":"\(sketchUUID)","seedPoint":[1,1],
         "axisPoint":[0,0],"axisDirection":[0,1]}}
        """) else { return }
        XCTAssertEqual(angle, 360, accuracy: 1e-12)
    }

    func testAbsurdAngleIsRefused() {
        XCTAssertEqual(code("""
        {"op":"feature.revolve","args":{"sketchID":"\(sketchUUID)","seedPoint":[1,1],
         "axisPoint":[0,0],"axisDirection":[0,1],"angleDegrees":3600}}
        """), "angle_out_of_range")
    }

    func testZeroLengthRevolveAxisIsRefused() {
        XCTAssertEqual(code("""
        {"op":"feature.revolve","args":{"sketchID":"\(sketchUUID)","seedPoint":[1,1],
         "axisPoint":[0,0],"axisDirection":[0,0]}}
        """), "degenerate_axis")
    }

    // MARK: feature.pattern / mirror / boolean

    func testCircularPatternCountIsTotalIncludingTheOriginal() {
        guard case let .pattern(_, spec)? = op("""
        {"op":"feature.pattern","args":{"bodyID":"\(bodyUUID)","kind":"circular",
         "axis":[0,2,0],"center":[0,0,0],"count":5,"totalAngleDegrees":360}}
        """) else { return }
        XCTAssertEqual(spec.kind, .circular)
        XCTAssertEqual(spec.count, 5)
        XCTAssertEqual(spec.totalAngle, 2 * .pi, accuracy: 1e-12)
        XCTAssertEqual(simd_length(spec.axis), 1, accuracy: 1e-12)
    }

    func testPatternCountBelowOneIsRefused() {
        XCTAssertEqual(code("""
        {"op":"feature.pattern","args":{"bodyID":"\(bodyUUID)","count":0}}
        """), "bad_count")
    }

    func testMirrorBuildsAPlaneWhoseNormalIsTheOneAsked() {
        guard case let .mirror(_, plane, keepOriginal)? = op("""
        {"op":"feature.mirror","args":{"bodyID":"\(bodyUUID)",
         "planeOrigin":[0,0,0],"planeNormal":[0,0,3]}}
        """) else { return }
        XCTAssertTrue(keepOriginal, "keepOriginal should default to true")
        // The two in-plane axes are arbitrary, but the normal they span is not.
        let n = simd_normalize(plane.normal)
        XCTAssertEqual(abs(simd_dot(n, SIMD3(0, 0, 1))), 1, accuracy: 1e-12)
    }

    func testBodyCannotBeItsOwnBooleanTool() {
        XCTAssertEqual(code("""
        {"op":"feature.boolean","args":{"kind":"subtract",
         "targetBodyID":"\(bodyUUID)","toolBodyIDs":["\(bodyUUID)"]}}
        """), "self_boolean")
    }

    func testUnknownBooleanKindIsRefused() {
        XCTAssertEqual(code("""
        {"op":"feature.boolean","args":{"kind":"merge",
         "targetBodyID":"\(bodyUUID)","toolBodyIDs":["\(sketchUUID)"]}}
        """), "unknown_boolean_kind")
    }

    // MARK: Decoding hygiene

    func testMalformedIdentifiersAndNumbersAreNamed() {
        XCTAssertEqual(code(#"{"op":"feature.pattern","args":{"bodyID":"not-a-uuid","count":2}}"#),
                       "bad_uuid")
        XCTAssertEqual(code(#"{"op":"feature.extrude","args":{"seedPoint":[0,0],"distance":1}}"#),
                       "missing_sketchID")
        XCTAssertEqual(code("""
        {"op":"feature.extrude","args":{"sketchID":"\(sketchUUID)","distance":1}}
        """), "missing_seedPoint")
    }
}
