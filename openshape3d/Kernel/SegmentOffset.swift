//
//  SegmentOffset.swift
//  openshape3d
//
//  Exact 2D offset of a closed boundary made of LINES and circular ARCS —
//  the draft/taper extrude's section offset for rounded profiles (rounded
//  rectangles, slots, obrounds; docs/DRAFT_TAPER_DESIGN.md slice 3). Where
//  `ProfileOffset` mitres a polygon, this keeps every arc an ARC: a line
//  shifts along its outward normal, an arc becomes the concentric arc of
//  radius r ± d, and neighbours are re-joined exactly — tangent joints stay
//  sealed (which every fillet is by construction), and any other joint is
//  trimmed or extended to where the two offset carriers (the infinite line,
//  the full circle) actually meet. Lofted on the segments channel, the
//  drafted wall over an arc is then a true cone.
//
//  Nil means "not exactly offsettable": an arc that collapses, carriers that
//  no longer meet, a line that reverses, an arc whose trim flips it, or a
//  boundary whose area vanishes. The caller falls back to the polygon path.
//  Correct where it applies, honest where it does not.
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
    /// the result keeps the input's winding. Nil when not exactly offsettable
    /// (see the file comment).
    static func offset(_ segments: [Profile.Segment], by distance: Double) -> [Profile.Segment]? {
        let n = segments.count
        guard n >= 2 else { return nil }
        if abs(distance) < 1e-12 { return segments }
        // The exact offset of a cubic is not a cubic: a spline segment has no
        // exact offset here, so a boundary carrying one takes the polygon
        // path (docs/SPLINE_PROFILE_DESIGN.md — not a goal).
        guard !segments.contains(where: { $0.controlPoints != nil }) else { return nil }

        let area = Profile.signedArea(loop(from: segments))
        guard abs(area) > 1e-12 else { return nil }
        let wasCW = area < 0
        let segs = wasCW ? reversed(segments) : segments

        // 1. Offset every segment as if it were alone, keeping its carrier
        //    (line: point + direction; arc: centre + offset radius + turn
        //    direction) and its traversal tangent at each end.
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
                var piece = Piece(seg: Profile.Segment(start: moved(s.start), end: moved(s.end), mid: moved(mid)),
                                  isArc: true)
                piece.center = c
                piece.radius = r2
                piece.convex = convex
                piece.oldMidAngle = atan2(mid.y - c.y, mid.x - c.x)
                piece.tangentIn = tangent(at: s.start)
                piece.tangentOut = tangent(at: s.end)
                pieces.append(piece)
            } else {
                let edge = s.end - s.start
                let len = simd_length(edge)
                guard len > 1e-12 else { return nil }
                let dir = edge / len
                let outward = SIMD2(dir.y, -dir.x)
                var piece = Piece(seg: Profile.Segment(start: s.start + outward * distance,
                                                       end: s.end + outward * distance),
                                  isArc: false)
                piece.dir = dir
                piece.tangentIn = dir
                piece.tangentOut = dir
                pieces.append(piece)
            }
        }

        // 2. Joints. A tangent joint's two offset ends already coincide (the
        //    line's outward normal IS the arc's radial there): seal any
        //    floating-point daylight. Any other joint is trimmed or extended to
        //    where the two carriers meet, choosing the meeting point nearest
        //    the ORIGINAL joint so a circle's second intersection never wins.
        for i in 0..<n {
            let j = (i + 1) % n
            let joint: SIMD2<Double>
            if simd_dot(pieces[i].tangentOut, pieces[j].tangentIn) > 1 - 1e-6 {
                let gap = simd_length(pieces[i].seg.end - pieces[j].seg.start)
                guard gap <= 1e-4 else { return nil }
                joint = (pieces[i].seg.end + pieces[j].seg.start) / 2
            } else {
                guard let p = carrierIntersection(pieces[i], pieces[j], near: segs[i].end) else { return nil }
                joint = p
            }
            pieces[i].seg.end = joint
            pieces[j].seg.start = joint
        }

        // 2b. Consumed LINES. A short flat (a chamfer, a tessellated chord)
        //     under an offset deeper than its own mitres pulls its two joints
        //     past each other, so the piece now runs backwards. As in the
        //     polygon path, the line vanishes and its surviving neighbours
        //     meet: each run of consumed lines collapses onto the meeting point
        //     of the neighbours' carriers — kept as ε-length pieces so the
        //     piece COUNT survives (the draft lofts segment-for-segment), with
        //     both joints placed exactly ON the neighbouring carriers so an
        //     arc's ends stay on its circle. A consumed ARC is a different
        //     animal (its sweep is gone, not its length) and stays nil below.
        var collapsed = Set<Int>()
        let consumedLines = (0..<n).filter { i in
            !pieces[i].isArc
                && simd_dot(segs[i].end - segs[i].start, pieces[i].seg.end - pieces[i].seg.start) <= 1e-12
        }
        if !consumedLines.isEmpty {
            guard n - consumedLines.count >= 2 else { return nil }
            let consumedSet = Set(consumedLines)
            let eps = 1e-3
            for start in consumedLines where !collapsed.contains(start) {
                var first = start
                while consumedSet.contains((first - 1 + n) % n), (first - 1 + n) % n != start { first = (first - 1 + n) % n }
                var last = first
                while consumedSet.contains((last + 1) % n), (last + 1) % n != first { last = (last + 1) % n }
                var run = [first]
                while run.last! != last { run.append((run.last! + 1) % n) }
                let prev = (first - 1 + n) % n, next = (last + 1) % n
                guard prev != next else { return nil }
                let near = (segs[first].start + segs[last].end) / 2
                guard let meet = carrierIntersection(pieces[prev], pieces[next], near: near) else { return nil }
                let count = run.count + 1                       // joints prev|first … last|next
                let far = advance(pieces[next], from: meet, by: Double(count - 1) * eps)
                let points = (0..<count).map { k -> SIMD2<Double> in
                    let s = Double(k) / Double(count - 1)
                    return meet + (far - meet) * s
                }
                pieces[prev].seg.end = points[0]
                for (k, i) in run.enumerated() {
                    pieces[i].seg.start = points[k]
                    pieces[i].seg.end = points[k + 1]
                    collapsed.insert(i)
                }
                pieces[next].seg.start = points[count - 1]
            }
        }

        // 3. Arcs: re-derive `mid` from the final ends along the traversal
        //    direction, and require the ORIGINAL mid's direction to still lie
        //    on the arc — a trim that emptied or flipped the arc fails here.
        for i in 0..<n where pieces[i].isArc {
            let c = pieces[i].center, r = pieces[i].radius
            let a0 = atan2(pieces[i].seg.start.y - c.y, pieces[i].seg.start.x - c.x)
            let a1 = atan2(pieces[i].seg.end.y - c.y, pieces[i].seg.end.x - c.x)
            let sweep = pieces[i].convex ? ccw(a0, a1) : -ccw(a1, a0)
            guard abs(sweep) > 1e-9 else { return nil }
            let toOld = pieces[i].convex ? ccw(a0, pieces[i].oldMidAngle) : -ccw(pieces[i].oldMidAngle, a0)
            guard abs(toOld) <= abs(sweep) + 1e-9 else { return nil }
            let am = a0 + sweep / 2
            pieces[i].seg.mid = c + SIMD2(cos(am), sin(am)) * r
        }
        // Surviving lines still run their original way (the collapsed ones
        // are ε-stubs by construction); the boundary still encloses a
        // positive (CCW) area.
        for i in 0..<n where !pieces[i].isArc && !collapsed.contains(i) {
            let orig = segs[i].end - segs[i].start
            let new = pieces[i].seg.end - pieces[i].seg.start
            guard simd_dot(orig, new) > 1e-12 else { return nil }
        }
        let result = pieces.map(\.seg)
        guard Profile.signedArea(loop(from: result)) > 1e-9 else { return nil }
        return wasCW ? reversed(result) : result
    }

    // MARK: - Internals

    /// The point on `piece`'s carrier `dist` further along its traversal
    /// from `p` (a point already on the carrier): straight for a line, around
    /// the circle for an arc — CCW about the centre when convex, CW when not.
    private static func advance(_ piece: Piece, from p: SIMD2<Double>, by dist: Double) -> SIMD2<Double> {
        guard piece.isArc else { return p + piece.dir * dist }
        let r = piece.radius
        guard r > 1e-12 else { return p }
        let angle = (piece.convex ? 1.0 : -1.0) * dist / r
        let v = p - piece.center
        let rotated = SIMD2(v.x * cos(angle) - v.y * sin(angle), v.x * sin(angle) + v.y * cos(angle))
        return piece.center + rotated
    }

    private struct Piece {
        var seg: Profile.Segment
        var isArc: Bool
        var center = SIMD2<Double>(0, 0)   // arcs
        var radius = 0.0                   // arcs: the OFFSET radius
        var convex = true                  // arcs: CCW about the centre on a CCW loop
        var oldMidAngle = 0.0              // arcs: direction of the original mid
        var dir = SIMD2<Double>(0, 0)      // lines
        var tangentIn = SIMD2<Double>(0, 0)
        var tangentOut = SIMD2<Double>(0, 0)
    }

    /// CCW angular distance from `from` to `to`, in [0, 2π).
    private static func ccw(_ from: Double, _ to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
        if d < 0 { d += 2 * .pi }
        return d
    }

    /// Where two offset carriers meet, nearest `near`; nil if they do not.
    private static func carrierIntersection(_ a: Piece, _ b: Piece, near: SIMD2<Double>) -> SIMD2<Double>? {
        let candidates: [SIMD2<Double>]
        switch (a.isArc, b.isArc) {
        case (false, false):
            let denom = a.dir.x * b.dir.y - a.dir.y * b.dir.x
            guard abs(denom) > 1e-9 else { return nil }          // (anti)parallel corner
            let diff = b.seg.start - a.seg.start
            let t = (diff.x * b.dir.y - diff.y * b.dir.x) / denom
            candidates = [a.seg.start + a.dir * t]
        case (false, true):
            candidates = lineCircle(p: a.seg.start, d: a.dir, c: b.center, r: b.radius)
        case (true, false):
            candidates = lineCircle(p: b.seg.start, d: b.dir, c: a.center, r: a.radius)
        case (true, true):
            candidates = circleCircle(c1: a.center, r1: a.radius, c2: b.center, r2: b.radius)
        }
        return candidates.min { simd_length_squared($0 - near) < simd_length_squared($1 - near) }
    }

    private static func lineCircle(p: SIMD2<Double>, d: SIMD2<Double>,
                                   c: SIMD2<Double>, r: Double) -> [SIMD2<Double>] {
        let t0 = simd_dot(c - p, d)
        let q = p + d * t0
        let h2 = r * r - simd_length_squared(c - q)
        guard h2 > -1e-9 else { return [] }
        let h = h2.squareRoot().isNaN ? 0 : max(0, h2).squareRoot()
        return [q + d * h, q - d * h]
    }

    private static func circleCircle(c1: SIMD2<Double>, r1: Double,
                                     c2: SIMD2<Double>, r2: Double) -> [SIMD2<Double>] {
        let delta = c2 - c1
        let d = simd_length(delta)
        guard d > 1e-12, d <= r1 + r2 + 1e-9, d >= abs(r1 - r2) - 1e-9 else { return [] }
        let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let h = max(0, r1 * r1 - a * a).squareRoot()
        let m = c1 + delta * (a / d)
        let perp = SIMD2(-delta.y, delta.x) / d
        return [m + perp * h, m - perp * h]
    }

    /// The same boundary traversed the other way: order reversed, every
    /// segment's ends swapped; an arc's `mid` is a point on it either way.
    private static func reversed(_ segments: [Profile.Segment]) -> [Profile.Segment] {
        segments.reversed().map { Profile.Segment(start: $0.end, end: $0.start, mid: $0.mid) }
    }
}
