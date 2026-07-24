//
//  MoveGizmoOverlay.swift
//  openshape3d
//
//  The move/rotate gizmo, drawn in 2D (SwiftUI) instead of as a Metal mesh so
//  it matches the extrude handle's flat, outlined look:
//
//   • axis translate arrows — solid flat arrows with a dark outline, exactly
//     like the extrude pull handle;
//   • rotation handles — thin double-headed arrows on a curve;
//   • plane-move handles — rounded squares; a small dot at the pivot.
//
//  Purely visual: it projects the gizmo's own local part anchors (the same
//  positions the 3D hit test in `GizmoGeometry` uses) to screen, so a tap on a
//  drawn handle lands on its 3D drag target. Hit-testing and drag math stay in
//  the viewport — this view never takes a touch.
//

import SwiftUI
import simd

struct MoveGizmoOverlay: View {
    @Bindable var viewModel: EditorViewModel

    // Extrude-handle palette: dark outline behind a light/coloured fill.
    private static let outline = Color(white: 0.08)
    private static let fill = Color.white
    private static let highlight = Color(red: 0.20, green: 0.52, blue: 1.0)
    private static let pivot = Color(red: 0.20, green: 0.80, blue: 0.85)

    private let axes: [GizmoPart] = [.xAxis, .yAxis, .zAxis]
    private let rings: [GizmoPart] = [.xRing, .yRing, .zRing]
    private let planes: [GizmoPart] = [.xyPlane, .yzPlane, .zxPlane]

    var body: some View {
        let _ = viewModel.cameraEpoch
        if let origin = viewModel.gizmoOrigin,
           let control = viewModel.cameraControl,
           let center = control.worldToScreenPoint(dbl(origin)) {
            let scale = control.gizmoWorldScale(at: origin)
            let ctx = ProjectionContext(origin: origin, scale: scale, control: control)

            ZStack(alignment: .topLeading) {
                ForEach(planes, id: \.self) { planeHandle($0, ctx) }
                // A selected face translates only — hide the rotation rings.
                if viewModel.gizmoAllowsRotation {
                    ForEach(rings, id: \.self) { rotationArc($0, ctx) }
                }
                ForEach(axes, id: \.self) { axisArrow($0, ctx) }
                pivotDot(at: center)
            }
            .allowsHitTesting(false)   // drags are hit-tested in 3D by the viewport
            .ignoresSafeArea()         // full-bleed Metal viewport, inset SwiftUI
        }
    }

    // MARK: - Axis translate arrow (flat, outlined — like the extrude handle)

    @ViewBuilder
    private func axisArrow(_ part: GizmoPart, _ ctx: ProjectionContext) -> some View {
        let axis = part.axisDirection
        if let tip = GizmoScreenLayout.axisAnchor(part, project: ctx.project),
           let base = ctx.project(axis * (GizmoScreenLayout.armLocal * 0.35)) {
            let dx = tip.x - base.x, dy = tip.y - base.y
            let len = hypot(dx, dy)
            // Fade an axis that points nearly into/out of the screen (its arrow
            // would be a foreshortened smear); it is still draggable in 3D.
            if len > 6 {
                let angle = atan2(Double(dy), Double(dx))
                let colored = viewModel.gizmoHighlight == part ? Self.highlight : Self.fill
                ZStack {
                    Image(systemName: "arrowshape.up.fill")
                        .foregroundStyle(Self.outline).scaleEffect(1.22)
                    Image(systemName: "arrowshape.up.fill")
                        .foregroundStyle(colored)
                }
                .font(.system(size: 30, weight: .semibold))
                .rotationEffect(.radians(angle + .pi / 2))
                .position(tip)
                .opacity(min(1, Double(len) / 24))
                .accessibilityIdentifier("GizmoAxis-\(part.axisName)")
            }
        }
    }

    // MARK: - Rotation handle (double-headed arrow on a curve)

    /// Project the visible arc of a rotation ring (centred at 45° in the ring
    /// basis, ~66° wide) so the drawn curve follows its on-screen ellipse.
    @ViewBuilder
    private func rotationArc(_ part: GizmoPart, _ ctx: ProjectionContext) -> some View {
        let pts = GizmoScreenLayout.ringPolyline(part, project: ctx.project)
        if pts.count >= 3 {
            let colored = viewModel.gizmoHighlight == part ? Self.highlight : Self.fill
            // Outline pass (fat, dark) then the fill pass, both with arrowheads
            // at each end — the double-ended curved arrow. Thicker + shorter and
            // pushed OUT past the move arrows (radius from GizmoScreenLayout) so
            // it reads as its own control, clear of the move handles.
            curvedArrow(pts, width: 13, arrow: 20, color: Self.outline)
            curvedArrow(pts, width: 7, arrow: 16, color: colored)
        }
    }

    /// A polyline through `pts` with a triangular arrowhead at each end.
    @ViewBuilder
    private func curvedArrow(_ pts: [CGPoint], width: CGFloat,
                             arrow: CGFloat, color: Color) -> some View {
        Path { path in
            path.addLines(pts)
        }
        .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        arrowHead(tip: pts[0], from: pts[1], size: arrow, color: color)
        arrowHead(tip: pts[pts.count - 1], from: pts[pts.count - 2], size: arrow, color: color)
    }

    @ViewBuilder
    private func arrowHead(tip: CGPoint, from: CGPoint, size: CGFloat, color: Color) -> some View {
        let dx = tip.x - from.x, dy = tip.y - from.y
        let len = hypot(dx, dy)
        if len > 0.5 {
            let ux = dx / len, uy = dy / len
            let nx = -uy, ny = ux
            let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
            Path { path in
                path.move(to: tip)
                path.addLine(to: CGPoint(x: base.x + nx * size * 0.6, y: base.y + ny * size * 0.6))
                path.addLine(to: CGPoint(x: base.x - nx * size * 0.6, y: base.y - ny * size * 0.6))
                path.closeSubpath()
            }
            .fill(color)
        }
    }

    // MARK: - Plane-move handle (rounded square)

    @ViewBuilder
    private func planeHandle(_ part: GizmoPart, _ ctx: ProjectionContext) -> some View {
        if let p = GizmoScreenLayout.planeAnchor(part, project: ctx.project) {
            let colored = viewModel.gizmoHighlight == part ? Self.highlight : Self.fill
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(colored)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Self.outline, lineWidth: 1.5))
                .frame(width: 16, height: 16)
                .position(p)
        }
    }

    @ViewBuilder
    private func pivotDot(at p: CGPoint) -> some View {
        Circle().fill(Self.pivot)
            .overlay(Circle().stroke(Self.outline, lineWidth: 1))
            .frame(width: 11, height: 11)
            .position(p)
    }

    private func dbl(_ v: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(v.x), Double(v.y), Double(v.z))
    }
}

/// Projects gizmo-local offsets (unit-scale, origin at zero) to screen points.
private struct ProjectionContext {
    let origin: SIMD3<Float>
    let scale: Float
    let control: any ViewportCameraControl

    func project(_ local: SIMD3<Float>) -> CGPoint? {
        let world = origin + local * scale
        return control.worldToScreenPoint(
            SIMD3(Double(world.x), Double(world.y), Double(world.z)))
    }
}
