//
//  ProfileOffset.swift
//  openshape3d
//
//  Mitred 2D offset of a simple closed polygon — the load-bearing geometry for
//  the draft/taper extrude (docs/DRAFT_TAPER_DESIGN.md, playbook M1). A tapered
//  extrude lofts between the base profile and this offset copy at the far end,
//  where the offset distance is tan(angle)·height.
//
//  Pure value math, no kernel dependency, so it is unit-testable in isolation.
//

import Foundation
import simd

nonisolated enum ProfileOffset {

    /// Offset a simple closed polygon loop by `distance` (positive = OUTWARD /
    /// expand, negative = inward / contract), mitred at the corners. Input is a
    /// plane-local loop in traversal order (as `Profile.loop` / the detector
    /// emit); orientation is normalized internally, so the sign of `distance`
    /// means the same thing regardless of CW/CCW winding, and the result keeps
    /// the input's winding.
    ///
    /// Returns nil when the offset is not well-defined: fewer than three
    /// points, a corner whose edges are (anti)parallel so the mitre has no
    /// intersection, or an inward offset large enough to collapse or invert the
    /// loop (its signed area flips or vanishes). Draft angles are small, so the
    /// common case is a clean shrink/grow; the nil is the honest signal to fall
    /// back rather than ship a self-intersected profile.
    static func offsetLoop(_ loop: [SIMD2<Double>],
                           by distance: Double) -> [SIMD2<Double>]? {
        let n = loop.count
        guard n >= 3 else { return nil }
        if abs(distance) < 1e-12 { return loop }

        // Work CCW so "outward" is unambiguous, then restore the input winding.
        let area = Profile.signedArea(loop)
        guard abs(area) > 1e-12 else { return nil }
        let wasCW = area < 0
        let pts = wasCW ? Array(loop.reversed()) : loop

        // Each edge i (pts[i] -> pts[i+1]) offsets OUTWARD along its normal.
        // For a CCW polygon the interior is to the LEFT of the edge direction,
        // so outward is the right-hand normal (dy, -dx).
        struct Line { var p: SIMD2<Double>; var d: SIMD2<Double> }
        var lines: [Line] = []
        lines.reserveCapacity(n)
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            let edge = b - a
            let len = simd_length(edge)
            guard len > 1e-12 else { return nil }   // zero-length edge
            let dir = edge / len
            let outward = SIMD2(dir.y, -dir.x)
            lines.append(Line(p: a + outward * distance, d: dir))
        }

        // New vertex i is the intersection of offset edge (i-1) and edge i.
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let l0 = lines[(i - 1 + n) % n], l1 = lines[i]
            // Solve l0.p + t·l0.d = l1.p + s·l1.d for t, using the 2D cross.
            let denom = l0.d.x * l1.d.y - l0.d.y * l1.d.x
            guard abs(denom) > 1e-9 else { return nil }  // (anti)parallel corner
            let diff = l1.p - l0.p
            let t = (diff.x * l1.d.y - diff.y * l1.d.x) / denom
            out.append(l0.p + l0.d * t)
        }

        // An inward offset past the inradius FLIPS the loop through its centre:
        // each edge reverses direction, and the flipped loop keeps the same
        // winding sign (so an area-sign test alone misses it). The honest
        // signal is that every result edge must still run the SAME way as its
        // original — a collapsed (zero-length) or reversed edge fails this.
        for i in 0..<n {
            let origDir = pts[(i + 1) % n] - pts[i]
            let newDir = out[(i + 1) % n] - out[i]
            guard simd_dot(origDir, newDir) > 1e-12 else { return nil }
        }
        let result = wasCW ? Array(out.reversed()) : out
        let outArea = Profile.signedArea(result)
        guard abs(outArea) > 1e-9, (outArea > 0) == (area > 0) else { return nil }
        return result
    }
}
