//
//  SegmentOffset.swift
//  openshape3d
//
//  Exact 2D offset of a closed boundary made of LINES and circular ARCS —
//  the draft/taper extrude's section offset for rounded profiles (rounded
//  rectangles, slots, obrounds; docs/DRAFT_TAPER_DESIGN.md slice 3). Where
//  `ProfileOffset` mitres a polygon, this keeps every arc an ARC: a line
//  shifts along its outward normal, an arc becomes the concentric arc of
//  radius r ± d, and the two stay joined exactly wherever the original joint
//  was tangent — which every fillet is by construction. Lofted on the
//  segments channel, the drafted wall over an arc is then a true cone.
//
//  Joints that are neither tangent nor line–line (a corner where an arc meets
//  something at an angle) have no offset that is both exact and simple; the
//  offset returns nil and the caller falls back to the polygon path. Correct
//  where it applies, honest where it does not.
//
//  Pure value math, no kernel dependency.
//

import Foundation
import simd

nonisolated enum SegmentOffset {

    /// The circle through three non-collinear points (circumcircle).
    static func circle(through a: SIMD2<Double>, _ m: SIMD2<Double>, _ b: SIMD2<Double>)
        -> (center: SIMD2<Double>, radius: Double)? {
        let d = 2 * (a.x * (m.y - b.y) + m.x * (b.y - a.y) + b.x * (a.y - m.y))
        guard abs(d) > 1e-12 else { return nil }
        let a2 = simd_length_squared(a), m2 = simd_length_squared(m), b2 = simd_length_squared(b)
        let ux = (a2 * (m.y - b.y) + m2 * (b.y - a.y) + b2 * (a.y - m.y)) / d
        let uy = (a2 * (b.x - m.x) + m2 * (a.x - b.x) + b2 * (m.x - a.x)) / d
        let c = SIMD2(ux, uy)
        return (c, simd_length(a - c))
    }

    /// Tessellate exact segments to a closed loop in traversal order. Arcs are
    /// sampled along the way round that passes through their `mid`, so the
    /// direction is never guessed from angles alone.
    static func loop(from segments: [Profile.Segment], arcPoints: Int = 16) -> [SIMD2<Double>] {
        var pts: [SIMD2<Double>] = []
        for s in segments {
            pts.append(s.start)
            guard let mid = s.mid, let (c, r) = circle(through: s.start, mid, s.end) else { continue }
            let a0 = atan2(s.start.y - c.y, s.start.x - c.x)
            let a1 = atan2(s.end.y - c.y, s.end.x - c.x)
            let am = atan2(mid.y - c.y, mid.x - c.x)
            func ccw(_ from: Double, _ to: Double) -> Double {
                var d = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
                if d < 0 { d += 2 * .pi }
                return d
            }
            var sweep = ccw(a0, a1)
            if ccw(a0, am) > sweep { sweep -= 2 * .pi }   // mid sits on the CW way round
            for i in 1..<max(arcPoints, 2) {
                let a = a0 + sweep * Double(i) / Double(arcPoints)
                pts.append(c + SIMD2(cos(a), sin(a)) * r)
            }
        }
        return pts
    }

    /// Offset a closed line/arc boundary by `distance` (positive = OUTWARD /
    /// expand, negative = inward / contract). Orientation is normalized
    /// internally so the sign means the same thing for CW and CCW input, and
    /// the result keeps the input's winding.
    ///
    /// Returns nil when the offset is not exactly and simply defined: a joint
    /// that is neither tangent nor line–line, an arc that would collapse
    /// (radius ≤ 0), a line that reverses, or a boundary whose area vanishes
    /// or flips. Nil means "fall back", never "ship a bad section".
    static func offset(_ segments: [Profile.Segment], by distance: Double) -> [Profile.Segment]? {
        let n = segments.count
        guard n >= 2 else { return nil }
        if abs(distance) < 1e-12 { return segments }

        let area = Profile.signedArea(loop(from: segments))
        guard abs(area) > 1e-12 else { return nil }
        let wasCW = area < 0
        let segs = wasCW ? reversed(segments) : segments

        // 1. Offset every segment as if it were alone, remembering its
        //    traversal tangent at each end for the joint test.
        struct Piece {
            var seg: Profile.Segment
            var isArc: Bool
            var tangentIn: SIMD2<Double>    // traversal direction at start
            var tangentOut: SIMD2<Double>   // traversal direction at end
        }
        var pieces: [Piece] = []
        pieces.reserveCapacity(n)
        for s in segs {
            if let mid = s.mid {
                guard let (c, r) = circle(through: s.start, mid, s.end) else { return nil }
                // On a CCW loop an arc that turns LEFT (CCW about its centre)
                // bulges outward — convex — so outward is a LARGER radius; an
                // arc that turns right is a concave notch and shrinks.
                let cross = (mid.x - s.start.x) * (s.end.y - mid.y) - (mid.y - s.start.y) * (s.end.x - mid.x)
                let convex = cross > 0
                let r2 = convex ? r + distance : r - distance
                guard r2 > 1e-9 else { return nil }          // the arc collapsed
                func moved(_ p: SIMD2<Double>) -> SIMD2<Double> { c + simd_normalize(p - c) * r2 }
                func tangent(at p: SIMD2<Double>) -> SIMD2<Double> {
                    let rad = simd_normalize(p - c)
                    let t = SIMD2(-rad.y, rad.x)                 // CCW traversal
                    return convex ? t : -t
                }
                pieces.append(Piece(
                    seg: Profile.Segment(start: moved(s.start), end: moved(s.end), mid: moved(mid)),
                    isArc: true, tangentIn: tangent(at: s.start), tangentOut: tangent(at: s.end)))
            } else {
                let edge = s.end - s.start
                let len = simd_length(edge)
                guard len > 1e-12 else { return nil }
                let dir = edge / len
                let outward = SIMD2(dir.y, -dir.x)
                pieces.append(Piece(
                    seg: Profile.Segment(start: s.start + outward * distance, end: s.end + outward * distance),
                    isArc: false, tangentIn: dir, tangentOut: dir))
            }
        }

        // 2. Joints. A tangent joint's two offset ends already coincide (the
        //    line's outward normal IS the arc's radial there); seal any
        //    floating-point daylight. A line–line corner mitres. Anything
        //    else is not exactly offsettable here.
        for i in 0..<n {
            let j = (i + 1) % n
            let tangent = simd_dot(pieces[i].tangentOut, pieces[j].tangentIn) > 1 - 1e-6
            if tangent {
                let gap = simd_length(pieces[i].seg.end - pieces[j].seg.start)
                guard gap <= 1e-4 else { return nil }
                let joint = (pieces[i].seg.end + pieces[j].seg.start) / 2
                pieces[i].seg.end = joint
                pieces[j].seg.start = joint
            } else if !pieces[i].isArc && !pieces[j].isArc {
                let p0 = pieces[i].seg.start, d0 = pieces[i].tangentOut
                let p1 = pieces[j].seg.start, d1 = pieces[j].tangentIn
                let denom = d0.x * d1.y - d0.y * d1.x
                guard abs(denom) > 1e-9 else { return nil }      // (anti)parallel corner
                let diff = p1 - p0
                let t = (diff.x * d1.y - diff.y * d1.x) / denom
                let corner = p0 + d0 * t
                pieces[i].seg.end = corner
                pieces[j].seg.start = corner
            } else {
                return nil
            }
        }

        // 3. Inversion and collapse: every line still runs its original way,
        //    and the boundary still encloses a positive (CCW) area.
        for i in 0..<n where !pieces[i].isArc {
            let orig = segs[i].end - segs[i].start
            let new = pieces[i].seg.end - pieces[i].seg.start
            guard simd_dot(orig, new) > 1e-12 else { return nil }
        }
        let result = pieces.map(\.seg)
        let outArea = Profile.signedArea(loop(from: result))
        guard outArea > 1e-9 else { return nil }
        return wasCW ? reversed(result) : result
    }

    /// The same boundary traversed the other way: order reversed, every
    /// segment's ends swapped; an arc's `mid` is a point on it either way.
    private static func reversed(_ segments: [Profile.Segment]) -> [Profile.Segment] {
        segments.reversed().map { Profile.Segment(start: $0.end, end: $0.start, mid: $0.mid) }
    }
}
