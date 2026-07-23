//
//  SketchLiveDimensionOverlay.swift
//  openshape3d
//
//  The dimensions shown WHILE a sketch stroke is in flight (spec §1.1) — the
//  "480 mm / 210 mm" a rectangle reads as you drag it out, the "Ø661.60 mm" a
//  circle reads. Distinct from `SketchDimensionOverlay`, which draws the
//  PERSISTED driving dimensions: nothing here is tappable or stored, it exists
//  only for the duration of the drag.
//
//  Everything is projected from world space, so the annotation reads correctly
//  with the camera at any angle — which is the point, since sketching no longer
//  forces a head-on view.
//

import SwiftUI

struct SketchLiveDimensionOverlay: View {
    @Bindable var viewModel: EditorViewModel

    /// Half-length of an arrow head, in points.
    private static let arrowLength: CGFloat = 9
    private static let arrowHalfWidth: CGFloat = 3.5

    var body: some View {
        // Reproject whenever the camera moves.
        let _ = viewModel.cameraEpoch
        ZStack(alignment: .topLeading) {
            ForEach(viewModel.liveDimensionLabels, id: \.id) { label in
                dimensionView(label)
            }
        }
        // Purely informational — taps must reach the sketch underneath.
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func dimensionView(_ label: EditorViewModel.LiveDimensionLabel) -> some View {
        if let lineStart = project(label.worldLineStart),
           let lineEnd = project(label.worldLineEnd),
           let witnessStart = project(label.worldWitnessStart),
           let witnessEnd = project(label.worldWitnessEnd),
           let anchor = project(label.worldLabel),
           hypot(lineEnd.x - lineStart.x, lineEnd.y - lineStart.y) > 1 {

            // Witness lines: thin leaders from the geometry out to the
            // dimension line. Zero-length when the dimension is drawn straight
            // across the shape (a diameter), which draws as nothing.
            Path { path in
                path.move(to: witnessStart)
                path.addLine(to: lineStart)
                path.move(to: witnessEnd)
                path.addLine(to: lineEnd)
            }
            .stroke(Color.primary.opacity(0.45), lineWidth: 0.75)

            Path { path in
                path.move(to: lineStart)
                path.addLine(to: lineEnd)
            }
            .stroke(Color.primary.opacity(0.85), lineWidth: 1)

            arrowHead(at: lineStart, pointingFrom: lineEnd)
            arrowHead(at: lineEnd, pointingFrom: lineStart)

            Text(label.text)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                // Ride the dimension line the way a CAD annotation does, but
                // never upside down.
                .rotationEffect(.radians(readableAngle(from: lineStart, to: lineEnd)))
                .position(anchor)
                .accessibilityIdentifier("LiveDimension")
        }
    }

    /// Solid arrow head at `tip`, aimed away from `origin`.
    @ViewBuilder
    private func arrowHead(at tip: CGPoint, pointingFrom origin: CGPoint) -> some View {
        let dx = tip.x - origin.x, dy = tip.y - origin.y
        let length = hypot(dx, dy)
        if length > 1 {
            let ux = dx / length, uy = dy / length
            let base = CGPoint(x: tip.x - ux * Self.arrowLength,
                               y: tip.y - uy * Self.arrowLength)
            Path { path in
                path.move(to: tip)
                path.addLine(to: CGPoint(x: base.x - uy * Self.arrowHalfWidth,
                                         y: base.y + ux * Self.arrowHalfWidth))
                path.addLine(to: CGPoint(x: base.x + uy * Self.arrowHalfWidth,
                                         y: base.y - ux * Self.arrowHalfWidth))
                path.closeSubpath()
            }
            .fill(Color.primary.opacity(0.85))
        }
    }

    /// The line's screen angle, flipped when it would read upside down.
    private func readableAngle(from a: CGPoint, to b: CGPoint) -> Double {
        var angle = atan2(Double(b.y - a.y), Double(b.x - a.x))
        if angle > .pi / 2 { angle -= .pi }
        if angle < -.pi / 2 { angle += .pi }
        return angle
    }

    private func project(_ world: SIMD3<Double>) -> CGPoint? {
        viewModel.cameraControl?.worldToScreenPoint(world)
    }
}
