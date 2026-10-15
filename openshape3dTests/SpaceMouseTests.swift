//
//  SpaceMouseTests.swift
//  openshape3dTests
//
//  Spec §7.5: SpaceMouse reports → camera motion, as pure values. The Mac
//  (IOKit element values) and the web (WebHID raw reports) feed the same
//  state, so both parsers are pinned here against each other.
//

import XCTest
import simd
@testable import openshape3d

final class SpaceMouseTests: XCTestCase {

    private func bytes(_ values: [Int]) -> [UInt8] {
        values.flatMap { v -> [UInt8] in
            let bits = UInt16(bitPattern: Int16(v))
            return [UInt8(bits & 0xFF), UInt8(bits >> 8)]
        }
    }

    func testSixAxisReportParsesLittleEndianSignedCounts() {
        var state = SpaceMouseState()
        state.apply(reportID: 1, payload: bytes([120, -350, 7, -1, 300, -42]))
        XCTAssertEqual(state.translation, SIMD3(120, -350, 7))
        XCTAssertEqual(state.rotation, SIMD3(-1, 300, -42))
        XCTAssertFalse(state.isAtRest)
        state.apply(reportID: 1, payload: bytes([0, 0, 0, 0, 0, 0]))
        XCTAssertTrue(state.isAtRest)
    }

    func testOlderDevicesSplitTranslationAndRotation() {
        var state = SpaceMouseState()
        state.apply(reportID: 1, payload: bytes([10, 20, 30]))
        state.apply(reportID: 2, payload: bytes([-40, -50, -60]))
        XCTAssertEqual(state.translation, SIMD3(10, 20, 30))
        XCTAssertEqual(state.rotation, SIMD3(-40, -50, -60))
        // A translation-only report leaves the rotation alone.
        state.apply(reportID: 1, payload: bytes([1, 2, 3]))
        XCTAssertEqual(state.rotation, SIMD3(-40, -50, -60))
        // Short or unknown reports change nothing.
        state.apply(reportID: 1, payload: [1, 2])
        state.apply(reportID: 9, payload: bytes([5, 5, 5]))
        XCTAssertEqual(state.translation, SIMD3(1, 2, 3))
    }

    func testButtonReportsReturnOnlyNewPresses() {
        var state = SpaceMouseState()
        XCTAssertEqual(state.apply(reportID: 3, payload: [0b10, 0]), 0b10)
        XCTAssertEqual(state.apply(reportID: 3, payload: [0b11, 0]), 0b01, "the held button is not pressed again")
        XCTAssertEqual(state.apply(reportID: 3, payload: [0, 0]), 0)
        XCTAssertEqual(state.buttons, 0)
    }

    func testElementValuesMatchTheRawReport() {
        var fromReport = SpaceMouseState()
        fromReport.apply(reportID: 1, payload: bytes([11, -22, 33, -44, 55, -66]))
        var fromElements = SpaceMouseState()
        for (usage, value) in zip(0x30...0x35, [11, -22, 33, -44, 55, -66]) {
            fromElements.set(usagePage: 0x01, usage: usage, value: value)
        }
        XCTAssertEqual(fromElements, fromReport)
        // Button usages are 1-based.
        XCTAssertEqual(fromElements.set(usagePage: 0x09, usage: 2, value: 1), 0b10)
        XCTAssertEqual(fromElements.set(usagePage: 0x09, usage: 2, value: 0), 0)
        XCTAssertEqual(fromElements.buttons, 0)
    }

    func testDeadZoneAndCurve() {
        XCTAssertEqual(SpaceMouseNavigation.shaped(15), 0, "a released cap's drift is ignored")
        XCTAssertEqual(SpaceMouseNavigation.shaped(350), 1, accuracy: 1e-12)
        XCTAssertEqual(SpaceMouseNavigation.shaped(-900), -1, accuracy: 1e-12, "clamped past full scale")
        let half = SpaceMouseNavigation.shaped(175)
        XCTAssertGreaterThan(half, 0)
        XCTAssertLessThan(half, 0.5, "half a push moves slower than half speed")
    }

    func testObjectModeDirections() {
        let settings = SpaceMouseSettings()
        func motion(_ t: SIMD3<Double> = .zero, _ r: SIMD3<Double> = .zero) -> SpaceMouseNavigation.Motion {
            SpaceMouseNavigation.motion(SpaceMouseState(translation: t, rotation: r), settings: settings)
        }
        XCTAssertGreaterThan(motion(SIMD3(350, 0, 0)).panX, 0, "push right: the model goes right")
        XCTAssertGreaterThan(motion(SIMD3(0, 0, -350)).panY, 0, "lift (−Z is up): the model rises")
        XCTAssertGreaterThan(motion(SIMD3(0, 350, 0)).zoom, 0, "pull toward you: the model comes closer")
        XCTAssertLessThan(motion(SIMD3(0, -350, 0)).zoom, 0, "push away: the model recedes")
        XCTAssertGreaterThan(motion(.zero, SIMD3(350, 0, 0)).tilt, 0)
        XCTAssertGreaterThan(motion(.zero, SIMD3(0, 0, -350)).spin, 0)
        XCTAssertTrue(motion(.zero, SIMD3(0, 350, 0)).isZero, "roll is left out: the turntable stays upright")
    }

    func testSettingsInvertDisableDominantAndSpeed() {
        let state = SpaceMouseState(translation: SIMD3(350, 200, 0), rotation: SIMD3(0, 0, 100))
        var settings = SpaceMouseSettings()
        let base = SpaceMouseNavigation.motion(state, settings: settings)
        XCTAssertNotEqual(base.panX, 0); XCTAssertNotEqual(base.zoom, 0); XCTAssertNotEqual(base.spin, 0)

        settings.invertPanX = true
        settings.invertZoom = true
        let inverted = SpaceMouseNavigation.motion(state, settings: settings)
        XCTAssertEqual(inverted.panX, -base.panX)
        XCTAssertEqual(inverted.zoom, -base.zoom)
        XCTAssertEqual(inverted.spin, base.spin)

        settings = SpaceMouseSettings()
        settings.rotation = false
        XCTAssertEqual(SpaceMouseNavigation.motion(state, settings: settings).spin, 0)
        settings.rotation = true
        settings.panZoom = false
        let rotateOnly = SpaceMouseNavigation.motion(state, settings: settings)
        XCTAssertEqual(rotateOnly.panX, 0); XCTAssertEqual(rotateOnly.zoom, 0)
        XCTAssertNotEqual(rotateOnly.spin, 0)

        settings = SpaceMouseSettings()
        settings.dominantAxis = true
        XCTAssertEqual(SpaceMouseNavigation.motion(state, settings: settings),
                       SpaceMouseNavigation.Motion(panX: base.panX), "only the strongest axis moves")

        settings = SpaceMouseSettings()
        settings.speed = 2
        XCTAssertEqual(SpaceMouseNavigation.motion(state, settings: settings).panX, base.panX * 2, accuracy: 1e-12)
    }

    func testApplyMovesTheTurntable() {
        let size = CGSize(width: 1000, height: 800)
        let start = TurntableCamera()

        var spun = start
        SpaceMouseNavigation.apply(.init(spin: 1), dt: 0.05, to: &spun, viewportSize: size)
        XCTAssertEqual(Double(spun.azimuth), Double(start.azimuth) - SpaceMouseNavigation.rotationRate * 0.05,
                       accuracy: 1e-5)

        var tilted = start
        SpaceMouseNavigation.apply(.init(tilt: 1), dt: 0.1, to: &tilted, viewportSize: size)
        XCTAssertGreaterThan(tilted.elevation, start.elevation, "tilting the top toward you shows more of it")
        for _ in 0..<100 { SpaceMouseNavigation.apply(.init(tilt: 1), dt: 0.1, to: &tilted, viewportSize: size) }
        XCTAssertEqual(tilted.elevation, TurntableCamera.elevationLimit, "the turntable never flips")

        var zoomed = start
        SpaceMouseNavigation.apply(.init(zoom: 1), dt: 0.1, to: &zoomed, viewportSize: size)
        XCTAssertLessThan(zoomed.distance, start.distance)

        // Panning right: the target moves left along the camera's right
        // axis, so the model appears to move right.
        var panned = start
        SpaceMouseNavigation.apply(.init(panX: 1), dt: 0.1, to: &panned, viewportSize: size)
        let view = start.viewMatrix
        let right = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        XCTAssertLessThan(simd_dot(panned.target - start.target, right), 0)
        XCTAssertEqual(panned.distance, start.distance)

        // A stalled frame is capped rather than jumping.
        var stalled = start
        SpaceMouseNavigation.apply(.init(spin: 1), dt: 5, to: &stalled, viewportSize: size)
        XCTAssertEqual(Double(stalled.azimuth),
                       Double(start.azimuth) - SpaceMouseNavigation.rotationRate * SpaceMouseNavigation.maxStep,
                       accuracy: 1e-5)
    }

    func testButtonsMapToTheStandardKeys() {
        XCTAssertEqual(SpaceMouseNavigation.action(forButton: 1), .fit)
        XCTAssertEqual(SpaceMouseNavigation.action(forButton: 0), .view(.isometric))
        XCTAssertEqual(SpaceMouseNavigation.action(forButton: 2), .view(.top))
        XCTAssertEqual(SpaceMouseNavigation.action(forButton: 5), .view(.front))
        XCTAssertNil(SpaceMouseNavigation.action(forButton: 20))
    }

    @MainActor
    func testDriverRoutesMotionAndPressesToTheTarget() {
        final class Recorder: SpaceMouseTarget {
            var moves: [SpaceMouseNavigation.Motion] = []
            var actions: [SpaceMouseNavigation.ButtonAction] = []
            func spaceMouseMove(_ motion: SpaceMouseNavigation.Motion, dt: Double) { moves.append(motion) }
            func spaceMouseButton(_ action: SpaceMouseNavigation.ButtonAction) { actions.append(action) }
        }
        let driver = SpaceMouseDriver()
        let recorder = Recorder()
        driver.target = recorder
        driver.settings = { SpaceMouseSettings() }

        driver.tick(dt: 1.0 / 60)
        XCTAssertTrue(recorder.moves.isEmpty, "at rest, nothing moves")
        driver.receive(reportID: 1, payload: bytes([350, 0, 0, 0, 0, 0]))
        XCTAssertTrue(driver.isMoving)
        driver.tick(dt: 1.0 / 60)
        driver.tick(dt: 1.0 / 60)
        XCTAssertEqual(recorder.moves.count, 2, "a held cap keeps moving between reports")
        driver.reset()
        XCTAssertFalse(driver.isMoving)

        driver.receive(reportID: 3, payload: [0b10, 0])
        driver.receive(reportID: 3, payload: [0, 0])
        XCTAssertEqual(recorder.actions, [.fit])
    }

    @MainActor
    func testSettingsPersist() throws {
        let suite = "SpaceMouseTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.spaceMouse, SpaceMouseSettings())
        settings.spaceMouse.speed = 2
        settings.spaceMouse.invertZoom = true
        settings.spaceMouse.dominantAxis = true
        let reloaded = AppSettings(defaults: defaults).spaceMouse
        XCTAssertEqual(reloaded.speed, 2)
        XCTAssertTrue(reloaded.invertZoom)
        XCTAssertTrue(reloaded.dominantAxis)

        // Settings stored by another build — fewer fields, an out-of-range
        // speed — still load.
        let partial = try JSONDecoder().decode(SpaceMouseSettings.self, from: Data(#"{"speed":99,"rotation":false}"#.utf8))
        XCTAssertEqual(partial.speed, SpaceMouseSettings.speedRange.upperBound)
        XCTAssertFalse(partial.rotation)
        XCTAssertTrue(partial.panZoom)
    }
}
