//
//  PinnedMeasurement.swift
//  openshape3d
//
//  Measure ▸ Pin (spec §16.3, "Pin to Always Show"): a measurement kept in
//  the model as an annotation — a distance between two points or the angle
//  at the middle of three — drawn until it is unpinned, and hidden with
//  View ▸ Show Pinned Measurements. Plain world points: a pin records what
//  was measured, it does not follow geometry that moves later.
//

import Foundation
import simd

nonisolated struct PinnedMeasurement: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case distance, angle }

    var id = UUID()
    var kind: Kind
    /// Distance: the two end points. Angle: arm end, vertex, arm end.
    var points: [SIMD3<Double>]

    /// Millimetres for a distance, degrees for an angle.
    var value: Double {
        switch kind {
        case .distance:
            guard points.count == 2 else { return 0 }
            return simd_length(points[1] - points[0])
        case .angle:
            guard points.count == 3 else { return 0 }
            return MeasureKit.angleDegrees(points[0], vertex: points[1], points[2]) ?? 0
        }
    }

    /// Where the label sits: the span's midpoint, or just inside the angle.
    var labelAnchor: SIMD3<Double> {
        switch kind {
        case .distance:
            return points.count == 2 ? (points[0] + points[1]) / 2 : points.first ?? .zero
        case .angle:
            guard points.count == 3 else { return points.first ?? .zero }
            let v = points[1]
            let a = points[0] - v, c = points[2] - v
            let la = simd_length(a), lc = simd_length(c)
            guard la > 1e-12, lc > 1e-12 else { return v }
            let reach = min(la, lc) * 0.4
            let bisector = a / la + c / lc
            let len = simd_length(bisector)
            return len > 1e-9 ? v + bisector / len * reach : v + a / la * reach
        }
    }

    /// World segments for the renderer: the span, or the two arms.
    var segments: [SIMD3<Double>] {
        switch kind {
        case .distance: return points.count == 2 ? points : []
        case .angle: return points.count == 3 ? [points[0], points[1], points[1], points[2]] : []
        }
    }
}

struct PinMeasurementCommand: DocumentCommand {
    let title = "Pin Measurement"
    let measurement: PinnedMeasurement

    func apply(to document: inout DesignDocument) {
        document.pinnedMeasurements.append(measurement)
    }

    func revert(in document: inout DesignDocument) {
        document.pinnedMeasurements.removeAll { $0.id == measurement.id }
    }
}

struct UnpinMeasurementCommand: DocumentCommand {
    let title = "Unpin Measurement"
    let measurement: PinnedMeasurement
    let index: Int

    func apply(to document: inout DesignDocument) {
        document.pinnedMeasurements.removeAll { $0.id == measurement.id }
    }

    func revert(in document: inout DesignDocument) {
        document.pinnedMeasurements.insert(measurement, at: min(index, document.pinnedMeasurements.count))
    }
}
