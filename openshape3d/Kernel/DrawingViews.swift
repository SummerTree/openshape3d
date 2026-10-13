//
//  DrawingViews.swift
//  openshape3d
//
//  Drawings v2 (spec §15): section and detail views. A section view cuts
//  the bodies with a plane through a cutting line placed on a base view,
//  keeps the material behind the plane and draws it looking at the cut,
//  with the cut faces hatched. A detail view magnifies the part of a base
//  view inside a circle. Pure value math, shared by every platform.
//

import Foundation
import simd

/// A section view: a cutting line across a base view and the view it makes.
nonisolated struct DrawingSectionView: Identifiable, Codable, Equatable, Sendable {
    enum Cut: String, Codable, CaseIterable, Sendable {
        /// The cutting line runs up the base view; the section looks from the side.
        case vertical
        /// The cutting line runs across the base view; the section looks from above.
        case horizontal

        var title: String { self == .vertical ? "Vertical" : "Horizontal" }
    }

    var id = UUID()
    /// "A" — the view reads "SECTION A-A".
    var label: String
    /// The view the cutting line is drawn on: Front, Top or Right.
    var base: DrawingViewDirection = .front
    var cut: Cut = .vertical
    /// Where the line crosses the base view, 0…1 across its width (vertical)
    /// or height (horizontal).
    var position: Double = 0.5
    /// Look the other way: keep the material on the other side of the line.
    var flipped = false

    /// Bases a section can be cut on — the orthographic views on the sheet.
    static let bases: [DrawingViewDirection] = [.front, .top, .right]
}

/// A detail view: a circle on a base view, drawn magnified.
nonisolated struct DrawingDetailView: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    /// "B" — the view reads "DETAIL B (2:1)".
    var label: String
    var base: DrawingViewDirection = .front
    /// The circle's centre, 0…1 across the base view's width and height.
    /// New details start over the top-left corner, where there are edges to
    /// magnify (the middle of a view is often empty).
    var center = SIMD2<Double>(0.25, 0.75)
    /// The circle's radius as a fraction of the base view's larger side.
    var radius: Double = 0.2
    /// Drawn this many times the sheet scale.
    var magnification: Double = 2

    static let bases: [DrawingViewDirection] = [.front, .top, .right, .isometric]
    static let magnifications: [Double] = [2, 4, 5, 10]
}

nonisolated enum DrawingViewKit {

    typealias Basis = (right: SIMD3<Double>, up: SIMD3<Double>, toward: SIMD3<Double>)

    /// The cut a section makes, in the base view's 2D coordinates and in
    /// the world.
    struct SectionCut {
        /// The cutting line across the base view (view coordinates), from
        /// one side of the view's bounds to the other.
        var line: (a: SIMD2<Double>, b: SIMD2<Double>)
        /// The direction of sight in the base view (unit, view coordinates):
        /// where the cutting line's arrows point.
        var sight: SIMD2<Double>
        /// The cutting plane; `basis.toward` points at the viewer, and the
        /// material behind it (opposite `toward`) is kept.
        var origin: SIMD3<Double>
        var basis: Basis
    }

    /// Where `section`'s cutting plane lies, given the base view's bounds.
    /// The section is seen the way the standard view looking the same way
    /// sees the part (upright, unmirrored): a cut looking left reads like
    /// Right, one looking down like Top.
    static func cut(_ section: DrawingSectionView, baseView: ProjectedView) -> SectionCut {
        let base = section.base.basis
        let t = Swift.min(1, Swift.max(0, section.position))
        let sign: Double = section.flipped ? -1 : 1
        let line: (a: SIMD2<Double>, b: SIMD2<Double>)
        let sight: SIMD2<Double>
        let normal: SIMD3<Double>
        let offset: Double
        if section.cut == .vertical {
            offset = baseView.min.x + baseView.size.x * t
            line = (SIMD2(offset, baseView.min.y), SIMD2(offset, baseView.max.y))
            sight = SIMD2(-sign, 0)
            normal = base.right
        } else {
            offset = baseView.min.y + baseView.size.y * t
            line = (SIMD2(baseView.min.x, offset), SIMD2(baseView.max.x, offset))
            sight = SIMD2(0, -sign)
            normal = base.up
        }
        let toward = normal * sign
        let basis = DrawingViewDirection.allCases
            .first { $0 != .isometric && simd_dot($0.basis.toward, toward) > 0.999 }?.basis
            ?? (simd_cross(base.up, toward), base.up, toward)
        return SectionCut(line: line, sight: sight, origin: normal * offset, basis: basis)
    }

    /// The section view: the material behind the cutting plane, seen
    /// looking at the cut, with the cut faces as `sectionLoops`.
    static func section(_ bodies: [DrawingBodyInput], cut: SectionCut) -> ProjectedView {
        let plane = SketchPlane(origin: cut.origin, xAxis: cut.basis.right, yAxis: cut.basis.up)
        var kept: [DrawingBodyInput] = []
        var loops: [[SIMD3<Double>]] = []
        for body in bodies {
            var clipped = clip(body, origin: cut.origin, toward: cut.basis.toward)
            let cap = SectionCapKit.cap(positions: body.positions.map { SIMD3<Float>($0) }, indices: body.indices,
                                        matrix: matrix_identity_double4x4, plane: plane)
            // The cut faces close the clipped body: they hide what lies
            // behind them and their outline is drawn as an edge.
            let start = UInt32(clipped.positions.count)
            for (k, p) in cap.triangles.enumerated() {
                clipped.positions.append(SIMD3<Double>(p))
                clipped.indices.append(start + UInt32(k))
            }
            for region in cap.regions {
                for loop in [region.outer] + region.holes {
                    let world = loop.map(plane.toWorld)
                    loops.append(world)
                    for i in world.indices {
                        clipped.edges.append(world[i])
                        clipped.edges.append(world[(i + 1) % world.count])
                    }
                }
            }
            if !clipped.indices.isEmpty { kept.append(clipped) }
        }
        var view = DrawingProjection.project(kept, basis: cut.basis)
        let (r, u) = (cut.basis.right, cut.basis.up)
        view.sectionLoops = loops.map { $0.map { SIMD2(simd_dot($0, r), simd_dot($0, u)) } }
        return view
    }

    /// `body` cut by the plane through `origin` facing `toward`, keeping the
    /// side behind it. Triangles crossing the plane are trimmed; a crossing
    /// is computed from its edge's ends in a fixed order, so the two
    /// triangles sharing that edge get the identical point.
    static func clip(_ body: DrawingBodyInput, origin: SIMD3<Double>, toward: SIMD3<Double>) -> DrawingBodyInput {
        func side(_ p: SIMD3<Double>) -> Double { simd_dot(p - origin, toward) }
        func crossing(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            let (p, q) = [a.x, a.y, a.z].lexicographicallyPrecedes([b.x, b.y, b.z]) ? (a, b) : (b, a)
            let sp = side(p), sq = side(q)
            return p + (q - p) * (sp / (sp - sq))
        }
        var out = DrawingBodyInput(positions: [], indices: [], edges: [])
        var i = 0
        while i + 2 < body.indices.count {
            let tri = [body.positions[Int(body.indices[i])], body.positions[Int(body.indices[i + 1])],
                       body.positions[Int(body.indices[i + 2])]]
            i += 3
            var polygon: [SIMD3<Double>] = []
            for k in 0..<3 {
                let a = tri[k], b = tri[(k + 1) % 3]
                let inA = side(a) <= 0, inB = side(b) <= 0
                if inA { polygon.append(a) }
                if inA != inB { polygon.append(crossing(a, b)) }
            }
            guard polygon.count >= 3 else { continue }
            let start = UInt32(out.positions.count)
            out.positions += polygon
            for k in 1..<(polygon.count - 1) {
                out.indices += [start, start + UInt32(k), start + UInt32(k + 1)]
            }
        }
        i = 0
        while i + 1 < body.edges.count {
            let a = body.edges[i], b = body.edges[i + 1]
            i += 2
            let inA = side(a) <= 0, inB = side(b) <= 0
            if inA && inB {
                out.edges += [a, b]
            } else if inA != inB {
                let x = crossing(a, b)
                out.edges += inA ? [a, x] : [x, b]
            }
        }
        return out
    }

    // MARK: - Detail views

    /// The detail circle on the base view (view coordinates).
    static func detailCircle(_ detail: DrawingDetailView, baseView: ProjectedView)
        -> (center: SIMD2<Double>, radius: Double) {
        let c = baseView.min + baseView.size * simd_clamp(detail.center, SIMD2(repeating: 0), SIMD2(repeating: 1))
        let r = Swift.max(baseView.size.x, baseView.size.y) * Swift.min(1, Swift.max(0.02, detail.radius))
        return (c, Swift.max(r, 1e-6))
    }

    /// The part of `segment` inside the circle, or nil.
    static func clip(_ segment: DrawingSegment, center: SIMD2<Double>, radius: Double) -> DrawingSegment? {
        let d = segment.b - segment.a
        let f = segment.a - center
        let a = simd_length_squared(d)
        guard a > 1e-18 else {
            return simd_length(f) <= radius ? segment : nil
        }
        let b = 2 * simd_dot(f, d)
        let c = simd_length_squared(f) - radius * radius
        let disc = b * b - 4 * a * c
        guard disc > 0 else { return nil }
        let root = disc.squareRoot()
        let t0 = Swift.max(0, (-b - root) / (2 * a)), t1 = Swift.min(1, (-b + root) / (2 * a))
        guard t1 - t0 > 1e-9 else { return nil }
        return DrawingSegment(a: segment.a + d * t0, b: segment.a + d * t1)
    }

    /// The base view inside the detail circle, as a view of its own (same
    /// coordinates; bounds are the circle's square).
    static func detail(_ detail: DrawingDetailView, baseView: ProjectedView) -> ProjectedView {
        let (c, r) = detailCircle(detail, baseView: baseView)
        var view = ProjectedView()
        view.visible = baseView.visible.compactMap { clip($0, center: c, radius: r) }
        view.hidden = baseView.hidden.compactMap { clip($0, center: c, radius: r) }
        view.min = c - SIMD2(repeating: r)
        view.max = c + SIMD2(repeating: r)
        return view
    }

    // MARK: - Hatching

    /// 45° hatch lines `spacing` apart filling `loops` even-odd (sheet mm).
    static func hatch(_ loops: [[SIMD2<Double>]], spacing: Double) -> [(SIMD2<Double>, SIMD2<Double>)] {
        let along = simd_normalize(SIMD2<Double>(1, 1)), across = SIMD2(-along.y, along.x)
        var lo = Double.infinity, hi = -Double.infinity
        for loop in loops { for p in loop { lo = Swift.min(lo, simd_dot(p, across)); hi = Swift.max(hi, simd_dot(p, across)) } }
        guard lo.isFinite, spacing > 0, hi - lo < spacing * 5000 else { return [] }
        var out: [(SIMD2<Double>, SIMD2<Double>)] = []
        var offset = (lo / spacing).rounded(.down) * spacing + spacing / 2
        while offset < hi {
            var hits: [Double] = []
            for loop in loops where loop.count >= 3 {
                for i in loop.indices {
                    let p = loop[i], q = loop[(i + 1) % loop.count]
                    let sp = simd_dot(p, across) - offset, sq = simd_dot(q, across) - offset
                    // Half-open, so a vertex on the line counts once.
                    guard (sp < 0) != (sq < 0) else { continue }
                    let x = p + (q - p) * (sp / (sp - sq))
                    hits.append(simd_dot(x, along))
                }
            }
            hits.sort()
            var k = 0
            while k + 1 < hits.count {
                if hits[k + 1] - hits[k] > 1e-9 {
                    out.append((along * hits[k] + across * offset, along * hits[k + 1] + across * offset))
                }
                k += 2
            }
            offset += spacing
        }
        return out
    }
}
