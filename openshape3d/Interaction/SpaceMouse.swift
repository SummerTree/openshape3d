//
//  SpaceMouse.swift
//  openshape3d
//
//  3Dconnexion SpaceMouse navigation (spec §7.5). The device reports six
//  axes — three of push and three of twist — and a few buttons. This file
//  turns those reports into camera motion; the platforms only deliver the
//  reports (IOKit HID on the Mac, `SpaceMouseHIDMonitor`; WebHID in the
//  browser) and call `tick` once a frame while the cap is moved. One path,
//  so the Mac and the web navigate identically.
//
//  Directions follow 3Dconnexion's "object mode": you hold the model.
//  Push the cap right and the model goes right, lift it and the model
//  rises, push it away and the model recedes, twist it and the model
//  turns. Each can be inverted in Settings ▸ SpaceMouse.
//

import Foundation
import CoreGraphics
import Observation
import simd

/// Settings ▸ SpaceMouse.
nonisolated struct SpaceMouseSettings: Codable, Equatable, Sendable {
    /// Overall speed, 0.25…4 (1 = standard).
    var speed = 1.0
    /// Twisting and tilting the cap turns the view.
    var rotation = true
    /// Pushing the cap pans and zooms.
    var panZoom = true
    /// Only the strongest axis moves the view at a time — for precise,
    /// one-direction moves.
    var dominantAxis = false
    var invertPanX = false
    var invertPanY = false
    var invertZoom = false
    var invertTilt = false
    var invertSpin = false

    static let speedRange = 0.25...4.0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case speed, rotation, panZoom, dominantAxis, invertPanX, invertPanY, invertZoom, invertTilt, invertSpin
    }

    // Every field optional on the way in, so settings stored by another
    // build still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SpaceMouseSettings()
        speed = min(max(try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed,
                        Self.speedRange.lowerBound), Self.speedRange.upperBound)
        rotation = try c.decodeIfPresent(Bool.self, forKey: .rotation) ?? d.rotation
        panZoom = try c.decodeIfPresent(Bool.self, forKey: .panZoom) ?? d.panZoom
        dominantAxis = try c.decodeIfPresent(Bool.self, forKey: .dominantAxis) ?? d.dominantAxis
        invertPanX = try c.decodeIfPresent(Bool.self, forKey: .invertPanX) ?? d.invertPanX
        invertPanY = try c.decodeIfPresent(Bool.self, forKey: .invertPanY) ?? d.invertPanY
        invertZoom = try c.decodeIfPresent(Bool.self, forKey: .invertZoom) ?? d.invertZoom
        invertTilt = try c.decodeIfPresent(Bool.self, forKey: .invertTilt) ?? d.invertTilt
        invertSpin = try c.decodeIfPresent(Bool.self, forKey: .invertSpin) ?? d.invertSpin
    }
}

/// The cap's position and the buttons held, as the device last reported
/// them. Axes are raw device counts in the HID frame: X right, Y toward
/// the user, Z down; rotations about the same axes.
nonisolated struct SpaceMouseState: Equatable, Sendable {
    var translation = SIMD3<Double>(repeating: 0)
    var rotation = SIMD3<Double>(repeating: 0)
    /// Bit n set while button n is held.
    var buttons: UInt32 = 0

    /// Counts at full deflection. Current devices report about ±350; older
    /// ones go further, and are clamped.
    static let fullScale = 350.0

    var isAtRest: Bool { translation == .zero && rotation == .zero }

    /// One HID input report, without its report-ID byte. Report 1 carries
    /// translation (6 bytes) or, on current devices, all six axes (12 bytes);
    /// report 2 the rotation; report 3 the buttons. Returns the buttons that
    /// went down with this report.
    @discardableResult
    mutating func apply(reportID: Int, payload: [UInt8]) -> UInt32 {
        func axis(_ i: Int) -> Double {
            guard payload.count >= 2 * i + 2 else { return 0 }
            return Double(Int16(bitPattern: UInt16(payload[2 * i]) | UInt16(payload[2 * i + 1]) << 8))
        }
        switch reportID {
        case 1:
            guard payload.count >= 6 else { return 0 }
            translation = SIMD3(axis(0), axis(1), axis(2))
            if payload.count >= 12 { rotation = SIMD3(axis(3), axis(4), axis(5)) }
        case 2:
            guard payload.count >= 6 else { return 0 }
            rotation = SIMD3(axis(0), axis(1), axis(2))
        case 3:
            var bits: UInt32 = 0
            for (i, byte) in payload.prefix(4).enumerated() { bits |= UInt32(byte) << (8 * i) }
            return setButtons(bits)
        default: break
        }
        return 0
    }

    /// One HID element value (usage page / usage), as the Mac's IOKit value
    /// callback delivers them: Generic Desktop X…Rz for the axes, the Button
    /// page (1-based usages) for the buttons. Returns the buttons that went
    /// down.
    @discardableResult
    mutating func set(usagePage: Int, usage: Int, value: Int) -> UInt32 {
        switch (usagePage, usage) {
        case (0x01, 0x30): translation.x = Double(value)
        case (0x01, 0x31): translation.y = Double(value)
        case (0x01, 0x32): translation.z = Double(value)
        case (0x01, 0x33): rotation.x = Double(value)
        case (0x01, 0x34): rotation.y = Double(value)
        case (0x01, 0x35): rotation.z = Double(value)
        case (0x09, 1...32):
            let bit = UInt32(1) << UInt32(usage - 1)
            return setButtons(value != 0 ? buttons | bit : buttons & ~bit)
        default: break
        }
        return 0
    }

    private mutating func setButtons(_ bits: UInt32) -> UInt32 {
        let pressed = bits & ~buttons
        buttons = bits
        return pressed
    }
}

/// What a frame of SpaceMouse input does to the camera.
nonisolated enum SpaceMouseNavigation {
    /// Deflection, as a fraction of full scale, below which the cap counts
    /// as at rest — a released cap rarely reads exactly zero.
    static let deadZone = 0.06
    /// Turn rate at full deflection and speed 1, radians a second.
    static let rotationRate = 0.75 * Double.pi
    /// Pan rate at full deflection, viewport heights a second.
    static let panRate = 0.9
    /// Zoom rate at full deflection, e-folds of distance a second.
    static let zoomRate = 1.6
    /// The longest frame one tick integrates, so a stall never jumps.
    static let maxStep = 0.1

    /// Each control's rate, −1…1 scaled by the speed: + pans right and up,
    /// zooms in, tilts the top toward the viewer, spins anticlockwise seen
    /// from above.
    struct Motion: Equatable, Sendable {
        var panX = 0.0, panY = 0.0, zoom = 0.0, tilt = 0.0, spin = 0.0
        var isZero: Bool { panX == 0 && panY == 0 && zoom == 0 && tilt == 0 && spin == 0 }
    }

    /// The dead zone, then a gentle curve: small pushes move slowly for
    /// precision, full ones fast.
    static func shaped(_ raw: Double) -> Double {
        let a = min(abs(raw) / SpaceMouseState.fullScale, 1)
        guard a > deadZone else { return 0 }
        let n = (a - deadZone) / (1 - deadZone)
        return (raw < 0 ? -1 : 1) * (0.3 * n + 0.7 * n * n)
    }

    static func motion(_ state: SpaceMouseState, settings: SpaceMouseSettings) -> Motion {
        // Object mode, from the HID frame (X right, Y toward the user, Z down):
        // the model follows the cap, so the camera moves the other way.
        var m = Motion()
        if settings.panZoom {
            m.panX = shaped(state.translation.x) * (settings.invertPanX ? -1 : 1)
            m.panY = -shaped(state.translation.z) * (settings.invertPanY ? -1 : 1)
            // Pulling the cap toward you brings the model closer: zoom in.
            m.zoom = shaped(state.translation.y) * (settings.invertZoom ? -1 : 1)
        }
        if settings.rotation {
            // The turntable stays upright, so roll (about Y) is left out.
            m.tilt = shaped(state.rotation.x) * (settings.invertTilt ? -1 : 1)
            m.spin = -shaped(state.rotation.z) * (settings.invertSpin ? -1 : 1)
        }
        if settings.dominantAxis {
            let all = [m.panX, m.panY, m.zoom, m.tilt, m.spin]
            let strongest = all.indices.max { abs(all[$0]) < abs(all[$1]) } ?? 0
            var kept = Motion()
            switch strongest {
            case 0: kept.panX = m.panX
            case 1: kept.panY = m.panY
            case 2: kept.zoom = m.zoom
            case 3: kept.tilt = m.tilt
            default: kept.spin = m.spin
            }
            m = kept
        }
        let s = min(max(settings.speed, SpaceMouseSettings.speedRange.lowerBound),
                    SpaceMouseSettings.speedRange.upperBound)
        return Motion(panX: m.panX * s, panY: m.panY * s, zoom: m.zoom * s, tilt: m.tilt * s, spin: m.spin * s)
    }

    /// Moves `camera` by `dt` seconds of `motion`.
    static func apply(_ motion: Motion, dt: Double, to camera: inout TurntableCamera, viewportSize: CGSize) {
        let t = min(max(dt, 0), maxStep)
        guard t > 0, !motion.isZero else { return }
        // The model turns with the cap; the camera orbits the other way.
        camera.azimuth -= Float(motion.spin * rotationRate * t)
        camera.elevation = min(max(camera.elevation + Float(motion.tilt * rotationRate * t),
                                   -TurntableCamera.elevationLimit), TurntableCamera.elevationLimit)
        if motion.panX != 0 || motion.panY != 0 {
            let pixels = panRate * t * Double(viewportSize.height)
            // `pan` drags the scene with the finger: +width moves it right,
            // +height (screen down) moves it down.
            camera.pan(deltaPixels: CGSize(width: motion.panX * pixels, height: -motion.panY * pixels),
                       viewportSize: viewportSize)
        }
        if motion.zoom != 0 {
            camera.zoom(scale: Float(exp(motion.zoom * zoomRate * t)))
        }
    }

    /// What a button does: 3Dconnexion's standard keys by their HID bit —
    /// Menu (no radial menu here: Isometric), Fit, then the view keys.
    enum ButtonAction: Equatable, Sendable {
        case fit
        case view(StandardView)
    }

    static func action(forButton bit: Int) -> ButtonAction? {
        switch bit {
        case 0: .view(.isometric)
        case 1: .fit
        case 2: .view(.top)
        case 3: .view(.left)
        case 4: .view(.right)
        case 5: .view(.front)
        case 6: .view(.bottom)
        case 7: .view(.back)
        default: nil
        }
    }
}

/// Where SpaceMouse input lands: the viewport on screen.
@MainActor
protocol SpaceMouseTarget: AnyObject {
    func spaceMouseMove(_ motion: SpaceMouseNavigation.Motion, dt: Double)
    func spaceMouseButton(_ action: SpaceMouseNavigation.ButtonAction)
}

/// The connected SpaceMouse, shared by every viewport. The platform glue
/// feeds it reports and calls `tick` each frame while `isMoving`.
@MainActor
@Observable
final class SpaceMouseDriver {
    static let shared = SpaceMouseDriver()

    /// The connected device's product name; nil while none is.
    var deviceName: String?
    @ObservationIgnored private(set) var state = SpaceMouseState()
    @ObservationIgnored weak var target: SpaceMouseTarget?
    /// Read on every tick, so a settings change applies mid-move.
    @ObservationIgnored var settings: () -> SpaceMouseSettings = { AppSettings.shared.spaceMouse }

    var isMoving: Bool { !state.isAtRest }

    func receive(reportID: Int, payload: [UInt8]) {
        press(state.apply(reportID: reportID, payload: payload))
    }

    func receive(usagePage: Int, usage: Int, value: Int) {
        press(state.set(usagePage: usagePage, usage: usage, value: value))
    }

    /// Lets go of the cap and buttons — the device went away mid-move.
    func reset() { state = SpaceMouseState() }

    func tick(dt: Double) {
        let motion = SpaceMouseNavigation.motion(state, settings: settings())
        guard !motion.isZero else { return }
        target?.spaceMouseMove(motion, dt: dt)
    }

    private func press(_ bits: UInt32) {
        guard bits != 0 else { return }
        for bit in 0..<32 where bits & (1 << UInt32(bit)) != 0 {
            if let action = SpaceMouseNavigation.action(forButton: bit) { target?.spaceMouseButton(action) }
        }
    }
}
