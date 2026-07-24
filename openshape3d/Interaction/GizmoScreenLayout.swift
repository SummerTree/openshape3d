//
//  GizmoScreenLayout.swift
//  openshape3d
//
//  The single source of truth for WHERE the move/rotate gizmo's handles sit on
//  screen. Both the `MoveGizmoOverlay` (which draws them) and the viewport
//  (which hit-tests taps against them) use it, so the flat 2D handle a user
//  sees is exactly the target they grab. Everything is expressed as gizmo-local
//  offsets projected through a caller-supplied `project` closure
//  (local → world → screen), so the layout has no camera dependency of its own.
//

import Foundation
import simd
import CoreGraphics

nonisolated enum GizmoScreenLayout {
    /// Gizmo-local anchor distances (match GizmoGeometry).
    static let armLocal: Float = 0.82    // axis arrow
    /// Rotation arcs sit OUTSIDE the move arrows (armLocal) so the two don't
    /// share space — a grab meant for a move handle no longer catches a rotate
    /// arc. (They used to be at 0.62, tucked among the move controls.)
    static let ringLocal: Float = 0.98
    static let planeLocal: Float = 0.235 // plane-tile centre

    /// Screen grab tolerances (points). Generous — these are touch targets.
    static let arrowHitRadius: CGFloat = 44
    static let planeHitRadius: CGFloat = 20
    /// Rotation arcs get a big touch band — they are now off on their own
    /// (outside the move arrows), so a generous target is safe and grabbable.
    static let ringHitRadius: CGFloat = 50
    /// Dead zone around the pivot (the free-move dot). A tap here grabs nothing
    /// rather than a random nearby handle, and it keeps the generous arrow band
    /// from claiming a dead-centre tap.
    static let pivotDeadZone: CGFloat = 18

    static let axes: [GizmoPart] = [.xAxis, .yAxis, .zAxis]
    static let rings: [GizmoPart] = [.xRing, .yRing, .zRing]
    static let planes: [GizmoPart] = [.xyPlane, .yzPlane, .zxPlane]

    /// Screen point of an axis arrow, or nil if it projects off-screen.
    static func axisAnchor(_ part: GizmoPart,
                           project: (SIMD3<Float>) -> CGPoint?) -> CGPoint? {
        project(part.axisDirection * armLocal)
    }

    /// Screen point of a plane-move handle.
    static func planeAnchor(_ part: GizmoPart,
                            project: (SIMD3<Float>) -> CGPoint?) -> CGPoint? {
        project(planeCenterLocal(part))
    }

    /// The projected arc of a rotation ring (its on-screen ellipse segment).
    static func ringPolyline(_ part: GizmoPart,
                             project: (SIMD3<Float>) -> CGPoint?) -> [CGPoint] {
        let (u, v) = GizmoGeometry.ringBasis(for: part)
        let a0 = Float.pi / 4 - 15 * .pi / 180
        let a1 = Float.pi / 4 + 15 * .pi / 180
        let steps = 12
        var pts: [CGPoint] = []
        for i in 0...steps {
            let a = a0 + (a1 - a0) * Float(i) / Float(steps)
            if let p = project((u * cos(a) + v * sin(a)) * ringLocal) { pts.append(p) }
        }
        return pts
    }

    static func planeCenterLocal(_ part: GizmoPart) -> SIMD3<Float> {
        switch part {
        case .xyPlane: SIMD3(planeLocal, planeLocal, 0)
        case .yzPlane: SIMD3(0, planeLocal, planeLocal)
        default:       SIMD3(planeLocal, 0, planeLocal)
        }
    }

    /// The gizmo part under a screen tap, matching what the overlay draws.
    ///
    /// Arrows and plane handles are point targets; rings are the projected arc
    /// polyline. Ties resolve by the SMALLEST normalised distance (distance /
    /// that part's tolerance), so a tap that is a hair inside two overlapping
    /// targets picks the one it is most centred on. Arrows and planes are
    /// tested before rings, so where an arc passes behind an arrow the arrow
    /// wins — translation stays the easy default.
    static func hitTest(at point: CGPoint,
                        project: (SIMD3<Float>) -> CGPoint?) -> GizmoPart? {
        var best: (part: GizmoPart, score: CGFloat)?
        func consider(_ part: GizmoPart, _ distance: CGFloat, _ tol: CGFloat) {
            guard distance <= tol else { return }
            let score = distance / tol
            if best == nil || score < best!.score { best = (part, score) }
        }

        // An axis is grabbable along its whole projected LINE — from the pivot
        // out to the arrow — not just the arrowhead, so a grab anywhere on the
        // arrow lands. A foreshortened axis (arrow collapsed onto the pivot,
        // pointing into the screen) is skipped: the overlay fades it and
        // grabbing it there would be a surprise.
        let center = project(.zero)
        // Dead-centre taps are the free-move pivot — grab nothing.
        if let center, hypot(point.x - center.x, point.y - center.y) < pivotDeadZone {
            return nil
        }
        for part in axes {
            guard let tip = axisAnchor(part, project: project) else { continue }
            if let center {
                guard hypot(tip.x - center.x, tip.y - center.y) >= arrowHitRadius else { continue }
                // Start the grabbable segment partway out from the pivot, so a
                // tap dead-centre (over the free-move dot) does not grab a
                // random axis, while grabs along the arrow's line still land.
                let start = CGPoint(x: center.x + (tip.x - center.x) * 0.4,
                                    y: center.y + (tip.y - center.y) * 0.4)
                consider(part, distance(from: point, toSegment: start, tip), arrowHitRadius)
            } else {
                consider(part, hypot(tip.x - point.x, tip.y - point.y), arrowHitRadius)
            }
        }
        for part in planes {
            if let a = planeAnchor(part, project: project) {
                consider(part, hypot(a.x - point.x, a.y - point.y), planeHitRadius)
            }
        }
        // Rings only if nothing closer already won on a point target.
        if best == nil {
            for part in rings {
                let poly = ringPolyline(part, project: project)
                let d = distance(from: point, toPolyline: poly)
                if let d { consider(part, d, ringHitRadius) }
            }
        }
        return best?.part
    }

    private static func distance(from p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat? {
        guard pts.count >= 2 else { return nil }
        var best: CGFloat?
        for i in 0..<(pts.count - 1) {
            let d = distance(from: p, toSegment: pts[i], pts[i + 1])
            if best == nil || d < best! { best = d }
        }
        return best
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 1e-9 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = min(max(t, 0), 1)
        return hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t))
    }
}
