//
//  VisualizationTests.swift
//  openshape3dTests
//
//  Visualization workspace (spec §14): the environment, its lighting, the
//  material library's search and glow, and their persistence.
//

import XCTest
import simd
@testable import openshape3d

final class VisualizationTests: XCTestCase {

    // MARK: - Lighting

    func testSunPositionFollowsRotationAndElevation() {
        var environment = VisualizationEnvironment()
        environment.sunElevation = 90
        var light = VisualizationLighting(environment)
        XCTAssertEqual(light.lightDirection.y, -1, accuracy: 1e-6, "a sun overhead shines straight down")

        environment.sunElevation = 0
        environment.lightRotation = 90
        light = VisualizationLighting(environment)
        XCTAssertEqual(light.lightDirection.x, -1, accuracy: 1e-6, "a sun on the right (+X) shines toward −X")
        environment.lightRotation = 0
        light = VisualizationLighting(environment)
        XCTAssertEqual(light.lightDirection.z, -1, accuracy: 1e-6, "a sun in front (+Z) shines toward −Z")
        XCTAssertEqual(simd_length(light.lightDirection), 1, accuracy: 1e-6)
    }

    func testIntensityScalesTheSunAndBackgroundsFollowTheChoice() {
        var environment = VisualizationEnvironment(preset: EnvironmentPreset.library[1])
        let preset = environment.presetValue
        environment.lightIntensity = 2
        var light = VisualizationLighting(environment)
        XCTAssertEqual(light.lightColor, SIMD3<Float>(preset.sun * 2))
        XCTAssertEqual(light.backgroundTop, SIMD3<Float>(preset.backgroundTop))
        XCTAssertFalse(light.transparentBackground)

        environment.background = .color
        environment.backgroundColor = SIMD3(0.1, 0.2, 0.3)
        light = VisualizationLighting(environment)
        XCTAssertEqual(light.backgroundTop, SIMD3<Float>(0.1, 0.2, 0.3))
        XCTAssertEqual(light.backgroundBottom, light.backgroundTop)

        environment.background = .transparent
        XCTAssertTrue(VisualizationLighting(environment).transparentBackground)
    }

    func testClampingAndUnknownPreset() {
        var environment = VisualizationEnvironment()
        environment.lightRotation = -30
        environment.sunElevation = 120
        environment.lightIntensity = 9
        environment.preset = "No Such Place"
        let clamped = environment.clamped
        XCTAssertEqual(clamped.lightRotation, 330)
        XCTAssertEqual(clamped.sunElevation, 90)
        XCTAssertEqual(clamped.lightIntensity, 2)
        XCTAssertEqual(environment.presetValue.name, EnvironmentPreset.library[0].name, "falls back to Studio")
    }

    // MARK: - Persistence

    func testEnvironmentCodableAndForgiving() throws {
        var environment = VisualizationEnvironment(preset: EnvironmentPreset.library[2])
        environment.background = .transparent
        environment.groundShadow = false
        let data = try JSONEncoder().encode(environment)
        XCTAssertEqual(try JSONDecoder().decode(VisualizationEnvironment.self, from: data), environment)
        // Fields missing (an older build) or unknown values (a newer one) fall back.
        let partial = try JSONDecoder().decode(VisualizationEnvironment.self,
                                               from: Data(#"{"preset":"Night","background":"hologram"}"#.utf8))
        XCTAssertEqual(partial.preset, "Night")
        XCTAssertEqual(partial.background, .environment)
        XCTAssertEqual(partial.lightIntensity, 1)
    }

    func testEnvironmentTravelsInTheArchiveAndUndoes() throws {
        var environment = VisualizationEnvironment(preset: EnvironmentPreset.library[3])
        environment.lightIntensity = 1.5
        var archive = ProjectArchive(name: "Render")
        archive.visualization = try JSONEncoder().encode(environment)
        let decoded = try XCTUnwrap(ProjectArchive.decode(XCTUnwrap(archive.encoded())))
        XCTAssertEqual(try JSONDecoder().decode(VisualizationEnvironment.self,
                                                from: XCTUnwrap(decoded.visualization)), environment)

        var document = DesignDocument()
        let command = SetVisualizationEnvironmentCommand(old: document.visualization, new: environment)
        command.apply(to: &document)
        XCTAssertEqual(document.visualization, environment)
        command.revert(in: &document)
        XCTAssertEqual(document.visualization, VisualizationEnvironment())
    }

    func testGlowIsOptionalInTheMaterialRecord() throws {
        // A record written before Glow existed reads as no glow, and a plain
        // material writes no glow key (its record is unchanged).
        let old = try JSONDecoder().decode(BodyMaterialSpec.self, from: Data(
            #"{"baseColor":[0.5,0.5,0.5,1],"metallic":0,"roughness":0.4}"#.utf8))
        XCTAssertEqual(old.emission, 0)
        let plain = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        XCTAssertFalse(plain.contains("emission"))
        var glow = old
        glow.emission = 0.8
        let back = try JSONDecoder().decode(BodyMaterialSpec.self, from: JSONEncoder().encode(glow))
        XCTAssertEqual(back.emission, 0.8)
        glow.emission = 3
        XCTAssertEqual(glow.clamped.emission, 1)
    }

    // MARK: - Library

    func testSearchByNameCategoryAndWords() {
        XCTAssertEqual(MaterialPreset.matching("chrome").map(\.name), ["Chrome"])
        XCTAssertTrue(MaterialPreset.matching("GLASS").allSatisfy { $0.category == .glass || $0.name.contains("Glass") })
        XCTAssertEqual(MaterialPreset.matching("glow blue").map(\.name), ["Glow Blue"], "every word must match")
        XCTAssertEqual(MaterialPreset.matching("", in: .wood).count,
                       MaterialPreset.library.filter { $0.category == .wood }.count)
        XCTAssertTrue(MaterialPreset.matching("zzz").isEmpty)
        let gold = MaterialPreset.library.first { $0.name == "Gold" }!
        XCTAssertEqual(MaterialPreset.named(gold.spec)?.name, "Gold")
        XCTAssertTrue(MaterialPreset.library.filter { $0.category == .glass }.allSatisfy { $0.spec.baseColor.w < 1 })
        XCTAssertTrue(MaterialPreset.library.filter { $0.category == .emissive }.allSatisfy { $0.spec.emission > 0 })
    }

    // MARK: - Agent

    func testAgentVisualizeOp() throws {
        guard case let .success(.visualize(on, args)) = AgentExec.parse(
            ["op": "view.visualize", "args": ["preset": "sunset", "lightIntensity": 1.5, "background": "transparent"]])
        else { return XCTFail("parses") }
        XCTAssertTrue(on)
        XCTAssertEqual(args.preset, "Sunset")
        let applied = args.applied(to: VisualizationEnvironment())
        XCTAssertEqual(applied.preset, "Sunset")
        XCTAssertEqual(applied.sunElevation, EnvironmentPreset.library.first { $0.name == "Sunset" }!.sunElevation)
        XCTAssertEqual(applied.lightIntensity, 1.5, "explicit fields win over the preset's")
        XCTAssertEqual(applied.background, .transparent)

        guard case .success(.visualize(false, _)) = AgentExec.parse(["op": "view.visualize", "args": ["off": true]])
        else { return XCTFail("off parses") }
        guard case let .failure(error) = AgentExec.parse(["op": "view.visualize", "args": ["preset": "Mars"]])
        else { return XCTFail("unknown preset refused") }
        XCTAssertEqual(error.code, "unknown_preset")
        guard case let .failure(bad) = AgentExec.parse(["op": "view.visualize", "args": ["sunElevation": 120.0]])
        else { return XCTFail("bad elevation refused") }
        XCTAssertEqual(bad.code, "bad_sunElevation")
    }

    func testDepthOfFieldBlursByDistanceFromTheFocus() {
        let eye = SIMD3<Float>(0, 0, 10), forward = SIMD3<Float>(0, 0, -1)
        // Focus 10 in front of the camera, whatever its sideways offset.
        XCTAssertEqual(DepthOfFieldKit.focusDistance(eye: eye, viewDirection: forward, focus: SIMD3(3, -2, 0)), 10, accuracy: 1e-5)
        // Behind the camera clamps to a sliver, never negative.
        XCTAssertGreaterThan(DepthOfFieldKit.focusDistance(eye: eye, viewDirection: forward, focus: SIMD3(0, 0, 20)), 0)
        func radius(_ d: Float, blur: Float = 1) -> Float {
            DepthOfFieldKit.radius(distance: d, focusDistance: 10, blur: blur, imageHeight: 1000)
        }
        XCTAssertEqual(radius(10), 0, "sharp at the focus")
        XCTAssertEqual(radius(11), 6, accuracy: 1e-4, "a tenth of the focus distance away: 0.3 of the widest 20 px")
        XCTAssertEqual(radius(9), radius(11), accuracy: 1e-4, "as much in front as behind")
        XCTAssertEqual(radius(14), 20, accuracy: 1e-4, "a third away: the widest")
        XCTAssertEqual(radius(100), 20, accuracy: 1e-4, "never past the widest blur")
        XCTAssertEqual(radius(100, blur: 0.25), 5, accuracy: 1e-4)
    }

    func testDepthOfFieldSettingsAreSavedAndReachTheRenderer() throws {
        var environment = VisualizationEnvironment()
        XCTAssertNil(VisualizationLighting(environment).depthOfField, "off by default")
        environment.depthOfField = true
        environment.blur = 0.7
        XCTAssertEqual(VisualizationLighting(environment).depthOfField, .init(focus: nil, blur: 0.7))
        environment.focusPoint = SIMD3(1, 2, 3)
        XCTAssertEqual(VisualizationLighting(environment).depthOfField?.focus, SIMD3<Float>(1, 2, 3))
        let back = try JSONDecoder().decode(VisualizationEnvironment.self, from: JSONEncoder().encode(environment))
        XCTAssertEqual(back, environment)
        // Out of range on the way in: pinned.
        environment.blur = 4
        environment.focusPoint = SIMD3(.nan, 0, 0)
        XCTAssertEqual(environment.clamped.blur, 1)
        XCTAssertNil(environment.clamped.focusPoint)
        // Saved before depth of field existed: off.
        let old = try JSONDecoder().decode(VisualizationEnvironment.self, from: Data(#"{"preset":"Studio"}"#.utf8))
        XCTAssertFalse(old.depthOfField)
        XCTAssertEqual(old.blur, 0.5)
    }
}
