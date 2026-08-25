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

    /// The projected arm length these point tolerances were tuned against.
    ///
    /// The gizmo's on-screen size follows the VIEWPORT HEIGHT (its world scale
    /// cancels against the projection's half-height divide), so one gizmo unit
    /// is ~0.24 × viewportHeight/2 points: ~165pt on a portrait iPad, but only
    /// ~47pt in iPhone LANDSCAPE, where the 0.82-unit arm projects to ~39pt.
    /// Fixed point tolerances then stop describing the gizmo at all — see
    /// `shrinkFactor` (2026-08-25 review round 3, finding R3-A).
    static let referenceArmPoints: CGFloat = 96

    /// Fraction of the LONGEST arm below which an axis counts as foreshortened
    /// (pointing into the screen) and is skipped. Relative, so it means the
    /// same thing at every gizmo size.
    static let foreshortenedFraction: CGFloat = 0.25

    /// Scales the touch tolerances down when the gizmo itself is small.
    ///
    /// 1.0 at reference size and above (iPad and the test projector are
    /// unaffected); ~0.4 in iPhone landscape. Without it the tolerances were
    /// LARGER than the gizmo: the arrow gate compared the arm against the 44pt
    /// touch radius and skipped all three axes, and the 18pt pivot dead zone
    /// swallowed the plane handles at ~11pt — so a fully-opaque gizmo was
    /// completely un-grabbable and drags fell through to a camera orbit.
    static func shrinkFactor(longestArm: CGFloat) -> CGFloat {
        guard longestArm > 0 else { return 1 }
        return min(1, longestArm / referenceArmPoints)
    }

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
                        project: (SIMD3<Float>) -> CGPoint?,
                        ringsOnly: Bool = false) -> GizmoPart? {
        var best: (part: GizmoPart, score: CGFloat)?
        func consider(_ part: GizmoPart, _ distance: CGFloat, _ tol: CGFloat) {
            guard distance <= tol else { return }
            let score = distance / tol
            if best == nil || score < best!.score { best = (part, score) }
        }

        // How big is the gizmo on screen right now? Every tolerance below is
        // scaled by this, so the handles stay grabbable — and stay distinct —
        // at any viewport size.
        let center = project(.zero)
        var arms: [(part: GizmoPart, tip: CGPoint, length: CGFloat)] = []
        var longestArm: CGFloat = 0
        for part in axes {
            guard let tip = axisAnchor(part, project: project) else { continue }
            let length = center.map { hypot(tip.x - $0.x, tip.y - $0.y) } ?? 0
            arms.append((part, tip, length))
            longestArm = max(longestArm, length)
        }
        let shrink = shrinkFactor(longestArm: longestArm)
        // Floors keep a very small gizmo from having sub-pixel targets.
        let arrowTol = max(10, arrowHitRadius * shrink)
        let planeTol = max(6, planeHitRadius * shrink)
        let ringTol = max(12, ringHitRadius * shrink)
        let deadZone = pivotDeadZone * shrink

        // Rotate-a-face shows ONLY the rings; test them alone so the (invisible)
        // axis/plane targets can't win the hit near the centre and then get
        // filtered out, leaving the drag to fall through to a camera orbit.
        if ringsOnly {
            for part in rings {
                let poly = ringPolyline(part, project: project)
                if let d = distance(from: point, toPolyline: poly) { consider(part, d, ringTol) }
            }
            return best?.part
        }

        // An axis is grabbable along its whole projected LINE — from the pivot
        // out to the arrow — not just the arrowhead, so a grab anywhere on the
        // arrow lands. A foreshortened axis (arrow collapsed onto the pivot,
        // pointing into the screen) is skipped: the overlay fades it and
        // grabbing it there would be a surprise.
        // Dead-centre taps are the free-move pivot — grab nothing.
        if let center, hypot(point.x - center.x, point.y - center.y) < deadZone {
            return nil
        }
        for arm in arms {
            if center != nil {
                // Skip an axis that is FORESHORTENED — collapsed toward the
                // pivot because it points into the screen. Measured against
                // the longest arm, not against a touch radius: comparing an
                // arm to `arrowHitRadius` meant that on any viewport where the
                // whole gizmo was smaller than the touch target, every axis
                // was skipped.
                guard arm.length >= longestArm * foreshortenedFraction else { continue }
                // Start the grabbable segment partway out from the pivot, so a
                // tap dead-centre (over the free-move dot) does not grab a
                // random axis, while grabs along the arrow's line still land.
                let c = center!
                let start = CGPoint(x: c.x + (arm.tip.x - c.x) * 0.4,
                                    y: c.y + (arm.tip.y - c.y) * 0.4)
                consider(arm.part, distance(from: point, toSegment: start, arm.tip), arrowTol)
            } else {
                consider(arm.part, hypot(arm.tip.x - point.x, arm.tip.y - point.y), arrowTol)
            }
        }
        for part in planes {
            if let a = planeAnchor(part, project: project) {
                consider(part, hypot(a.x - point.x, a.y - point.y), planeTol)
            }
        }
        // Rings only if nothing closer already won on a point target.
        if best == nil {
            for part in rings {
                let poly = ringPolyline(part, project: project)
                let d = distance(from: point, toPolyline: poly)
                if let d { consider(part, d, ringTol) }
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
