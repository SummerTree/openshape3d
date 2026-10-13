//
//  DrawingProjection.swift
//  openshape3d
//
//  Drawings (spec §15): one orthographic view of the bodies as 2D lines,
//  split into visible and hidden. The lines are the bodies' feature edges
//  plus the silhouettes of curved surfaces as seen from this direction;
//  each is sampled along its length and every piece tested against the
//  triangles in front of it (hidden-line removal on the tessellation).
//  Pure value math, so the same code draws the sheet on every platform.
//

import Foundation
import simd

/// A direction to look at the model from, matching the viewport's standard
/// views: Front looks from +Z, Right from +X, Top from +Y with −Z up.
nonisolated enum DrawingViewDirection: String, CaseIterable, Codable, Sendable {
    case front, back, top, bottom, right, left, isometric

    var title: String {
        switch self {
        case .front: "Front"
        case .back: "Back"
        case .top: "Top"
        case .bottom: "Bottom"
        case .right: "Right"
        case .left: "Left"
        case .isometric: "Isometric"
        }
    }

    /// (right, up, toward the viewer); right × up = toward.
    var basis: (right: SIMD3<Double>, up: SIMD3<Double>, toward: SIMD3<Double>) {
        switch self {
        case .front: return (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .back: return (SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1))
        case .right: return (SIMD3(0, 0, -1), SIMD3(0, 1, 0), SIMD3(1, 0, 0))
        case .left: return (SIMD3(0, 0, 1), SIMD3(0, 1, 0), SIMD3(-1, 0, 0))
        case .top: return (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0))
        case .bottom: return (SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0))
        case .isometric:
            let toward = simd_normalize(SIMD3<Double>(1, 1, 1))
            let up = simd_normalize(SIMD3<Double>(0, 1, 0) - toward * simd_dot(SIMD3(0, 1, 0), toward))
            return (simd_cross(up, toward), up, toward)
        }
    }
}

nonisolated struct DrawingSegment: Equatable, Sendable {
    var a: SIMD2<Double>
    var b: SIMD2<Double>
}

nonisolated struct ProjectedView: Sendable {
    var visible: [DrawingSegment] = []
    var hidden: [DrawingSegment] = []
    /// Bounds of every line, visible or hidden (view coordinates, mm).
    var min = SIMD2<Double>(repeating: 0)
    var max = SIMD2<Double>(repeating: 0)

    /// A section view's cut faces as closed loops (outer boundaries and
    /// holes alike, view coordinates); the sheet hatches them even-odd.
    var sectionLoops: [[SIMD2<Double>]] = []

    var size: SIMD2<Double> { max - min }
    var isEmpty: Bool { visible.isEmpty && hidden.isEmpty }
}

/// One body ready to draw: its world-space triangles and feature edges.
nonisolated struct DrawingBodyInput: Sendable {
    var positions: [SIMD3<Double>]
    var indices: [UInt32]
    /// Feature-edge segment pairs, world space.
    var edges: [SIMD3<Double>]

    init(positions: [SIMD3<Double>], indices: [UInt32], edges: [SIMD3<Double>]) {
        self.positions = positions
        self.indices = indices
        self.edges = edges
    }

    /// From a document body: its render mesh and edges placed in the world.
    init(body: Body) {
        let t = body.transform
        positions = body.render.positions.map { t.applying(to: SIMD3<Double>($0)) }
        indices = body.render.indices
        edges = body.edges.segments.map { t.applying(to: SIMD3<Double>($0)) }
    }
}

nonisolated enum DrawingProjection {

    /// Project `bodies` as seen from `direction`.
    static func project(_ bodies: [DrawingBodyInput], direction: DrawingViewDirection) -> ProjectedView {
        project(bodies, basis: direction.basis)
    }

    /// Project `bodies` onto the plane of `basis` (right, up), looking along
    /// −toward — any view, not only the standard ones (section views).
    static func project(_ bodies: [DrawingBodyInput],
                        basis: (right: SIMD3<Double>, up: SIMD3<Double>, toward: SIMD3<Double>)) -> ProjectedView {
        let (r, u, v) = basis
        func flat(_ p: SIMD3<Double>) -> SIMD2<Double> { SIMD2(simd_dot(p, r), simd_dot(p, u)) }

        // Triangles in view space: 2D corners plus depth toward the viewer.
        var tris: [(a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>)] = []
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        for body in bodies {
            var i = 0
            while i + 2 < body.indices.count {
                let p = [body.positions[Int(body.indices[i])], body.positions[Int(body.indices[i + 1])],
                         body.positions[Int(body.indices[i + 2])]]
                i += 3
                let q = p.map { SIMD3(simd_dot($0, r), simd_dot($0, u), simd_dot($0, v)) }
                for x in q { lo = simd_min(lo, x); hi = simd_max(hi, x) }
                tris.append((q[0], q[1], q[2]))
            }
        }
        guard !tris.isEmpty else { return ProjectedView() }
        let diagonal = Swift.max(simd_length(hi - lo), 1e-6)
        let depthEps = diagonal * 2e-4

        // The lines to draw: feature edges, plus silhouettes where a mesh
        // edge separates a face turned toward the viewer from one turned away.
        var lines: [(SIMD3<Double>, SIMD3<Double>)] = []
        // Same edge twice (a feature edge that is also a silhouette): keyed
        // by its 3D ends, so a back edge never stands in for a front one.
        var seen = Set<[Int64]>()
        func key(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> [Int64] {
            func q(_ p: SIMD3<Double>) -> [Int64] {
                [p.x, p.y, p.z].map { MeshQuantize.key64($0, inverseQuantum: 1e4) }
            }
            let (s, t) = (q(a), q(b))
            return s.lexicographicallyPrecedes(t) ? s + t : t + s
        }
        func addLine(_ a: SIMD3<Double>, _ b: SIMD3<Double>) {
            guard simd_length(flat(b) - flat(a)) > diagonal * 1e-6 else { return } // seen end-on
            if seen.insert(key(a, b)).inserted { lines.append((a, b)) }
        }
        for body in bodies {
            let creases = CreaseTest(body)
            var i = 0
            while i + 1 < body.edges.count {
                let a = body.edges[i], b = body.edges[i + 1]
                i += 2
                if creases.isCrease(a, b) { addLine(a, b) }
            }
        }
        for (a, b) in silhouettes(bodies, toward: v) { addLine(a, b) }

        // Occlusion grid over the triangles' 2D boxes.
        let grid = TriangleGrid(tris: tris, lo: SIMD2(lo.x, lo.y), hi: SIMD2(hi.x, hi.y))
        func hiddenAt(_ p: SIMD3<Double>) -> Bool {
            let x = simd_dot(p, r), y = simd_dot(p, u), depth = simd_dot(p, v)
            return grid.occludes(x: x, y: y, depth: depth + depthEps)
        }

        var view = ProjectedView()
        let step = diagonal / 240
        for (a, b) in lines {
            let a2 = flat(a), b2 = flat(b)
            let n = Swift.max(1, Int((simd_length(b2 - a2) / step).rounded(.up)))
            // Classify each piece, then merge runs of the same kind.
            let states = (0..<n).map { hiddenAt(a + (b - a) * ((Double($0) + 0.5) / Double(n))) }
            var start = 0
            for k in 1...n where k == n || states[k] != states[start] {
                let seg = DrawingSegment(a: a2 + (b2 - a2) * (Double(start) / Double(n)),
                                         b: a2 + (b2 - a2) * (Double(k) / Double(n)))
                if states[start] { view.hidden.append(seg) } else { view.visible.append(seg) }
                start = k
            }
        }
        let tolerance = diagonal * 1e-4
        view.visible = dropCovered(view.visible, by: [], tolerance: tolerance)
        view.hidden = dropCovered(view.hidden, by: view.visible, tolerance: tolerance)

        var mn = SIMD2<Double>(repeating: .infinity), mx = -mn
        for s in view.visible + view.hidden {
            mn = simd_min(mn, simd_min(s.a, s.b))
            mx = simd_max(mx, simd_max(s.a, s.b))
        }
        if mn.x.isFinite { view.min = mn; view.max = mx }
        return view
    }

    /// Mesh edges between a triangle facing the viewer and one facing away —
    /// the outline a curved surface shows.
    static func silhouettes(_ bodies: [DrawingBodyInput], toward v: SIMD3<Double>) -> [(SIMD3<Double>, SIMD3<Double>)] {
        var out: [(SIMD3<Double>, SIMD3<Double>)] = []
        for body in bodies {
            // Weld split-normal duplicates so neighbours share vertex ids.
            var ids: [SIMD3<Int64>: Int] = [:]
            var canonical: [Int] = []
            var points: [SIMD3<Double>] = []
            for p in body.positions {
                let k = SIMD3(MeshQuantize.key64(p.x, inverseQuantum: 1e5),
                              MeshQuantize.key64(p.y, inverseQuantum: 1e5),
                              MeshQuantize.key64(p.z, inverseQuantum: 1e5))
                if let id = ids[k] { canonical.append(id) } else {
                    ids[k] = points.count
                    canonical.append(points.count)
                    points.append(p)
                }
            }
            var facing: [SIMD2<Int>: [Double]] = [:]
            var i = 0
            while i + 2 < body.indices.count {
                let t = [canonical[Int(body.indices[i])], canonical[Int(body.indices[i + 1])],
                         canonical[Int(body.indices[i + 2])]]
                i += 3
                let n = simd_cross(points[t[1]] - points[t[0]], points[t[2]] - points[t[0]])
                let len = simd_length(n)
                guard len > 1e-12 else { continue }
                let f = simd_dot(n / len, v)
                for k in 0..<3 {
                    let a = t[k], b = t[(k + 1) % 3]
                    facing[SIMD2(Swift.min(a, b), Swift.max(a, b)), default: []].append(f)
                }
            }
            for (edge, fs) in facing {
                // Only edges with a neighbour on each side: a lone triangle
                // edge in a solid is a T-junction from a mesh boolean, not
                // an outline.
                let flips = fs.count == 2 && (fs[0] > 1e-9) != (fs[1] > 1e-9)
                if flips { out.append((points[edge.x], points[edge.y])) }
            }
        }
        return out
    }

    /// Lines lying on another line add nothing but clutter: the back edge of
    /// a box behind its front edge, or an edge a mesh boolean left in pieces
    /// beside the whole. Longest first, each line is kept only if some part
    /// of it is not already drawn by `cover` or a line kept before it.
    private static func dropCovered(_ lines: [DrawingSegment], by cover: [DrawingSegment],
                                    tolerance: Double) -> [DrawingSegment] {
        guard !lines.isEmpty else { return lines }
        func onSegment(_ p: SIMD2<Double>, _ s: DrawingSegment) -> Bool {
            let d = s.b - s.a
            let l2 = simd_length_squared(d)
            guard l2 > 1e-18 else { return simd_distance(p, s.a) <= tolerance }
            let t = simd_dot(p - s.a, d) / l2
            guard t >= -1e-9, t <= 1 + 1e-9 else { return false }
            return simd_distance(p, s.a + d * t) <= tolerance
        }
        var kept: [DrawingSegment] = []
        let sorted = lines.sorted { simd_distance($0.a, $0.b) > simd_distance($1.a, $1.b) }
        for line in sorted {
            let probes = [line.a, line.a + (line.b - line.a) * 0.25, (line.a + line.b) / 2,
                          line.a + (line.b - line.a) * 0.75, line.b]
            let covered = probes.allSatisfy { p in
                cover.contains { onSegment(p, $0) } || kept.contains { onSegment(p, $0) }
            }
            if !covered { kept.append(line) }
        }
        return kept
    }
}

/// Buckets view-space triangles by their 2D bounds for occlusion queries.
nonisolated private struct TriangleGrid {
    let tris: [(a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>)]
    let lo: SIMD2<Double>
    let cell: Double
    let columns: Int
    let rows: Int
    var buckets: [[Int]]

    init(tris: [(a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>)], lo: SIMD2<Double>, hi: SIMD2<Double>) {
        self.tris = tris
        self.lo = lo
        let span = simd_max(hi - lo, SIMD2(repeating: 1e-9))
        let side = Swift.max(1, Int(Double(tris.count).squareRoot()))
        let cols = Swift.min(256, side), rws = Swift.min(256, side)
        cell = Swift.max(span.x / Double(cols), span.y / Double(rws), 1e-9)
        columns = Swift.max(1, Int((span.x / cell).rounded(.up)) + 1)
        rows = Swift.max(1, Int((span.y / cell).rounded(.up)) + 1)
        buckets = Array(repeating: [], count: columns * rows)
        for (i, t) in tris.enumerated() {
            let mn = SIMD2(Swift.min(t.a.x, t.b.x, t.c.x), Swift.min(t.a.y, t.b.y, t.c.y))
            let mx = SIMD2(Swift.max(t.a.x, t.b.x, t.c.x), Swift.max(t.a.y, t.b.y, t.c.y))
            let c0 = clampCol(mn.x), c1 = clampCol(mx.x), r0 = clampRow(mn.y), r1 = clampRow(mx.y)
            for row in r0...r1 { for col in c0...c1 { buckets[row * columns + col].append(i) } }
        }
    }

    private func clampCol(_ x: Double) -> Int { Swift.min(columns - 1, Swift.max(0, Int((x - lo.x) / cell))) }
    private func clampRow(_ y: Double) -> Int { Swift.min(rows - 1, Swift.max(0, Int((y - lo.y) / cell))) }

    /// True when some triangle covers (x, y) nearer the viewer than `depth`.
    func occludes(x: Double, y: Double, depth: Double) -> Bool {
        for i in buckets[clampRow(y) * columns + clampCol(x)] {
            let t = tris[i]
            let d = (t.b.y - t.c.y) * (t.a.x - t.c.x) + (t.c.x - t.b.x) * (t.a.y - t.c.y)
            guard abs(d) > 1e-18 else { continue }
            let w0 = ((t.b.y - t.c.y) * (x - t.c.x) + (t.c.x - t.b.x) * (y - t.c.y)) / d
            let w1 = ((t.c.y - t.a.y) * (x - t.c.x) + (t.a.x - t.c.x) * (y - t.c.y)) / d
            let w2 = 1 - w0 - w1
            let e = -1e-9
            guard w0 >= e, w1 >= e, w2 >= e else { continue }
            if w0 * t.a.z + w1 * t.b.z + w2 * t.c.z > depth { return true }
        }
        return false
    }
}

/// Whether an edge really separates surfaces turned different ways. A mesh
/// boolean can leave triangulation seams across a flat face that an edge
/// extractor reports as edges; a drawing must not show them. Looks up the
/// triangles that touch the edge's midpoint and keeps the edge only when
/// their normals disagree.
nonisolated private struct CreaseTest {
    let positions: [SIMD3<Double>]
    let triangles: [(Int, Int, Int, SIMD3<Double>)]
    var buckets: [SIMD3<Int>: [Int]] = [:]
    let cell: Double
    let tolerance: Double

    init(_ body: DrawingBodyInput) {
        positions = body.positions
        var tris: [(Int, Int, Int, SIMD3<Double>)] = []
        var lo = SIMD3<Double>(repeating: .infinity), hi = -lo
        for p in body.positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        var i = 0
        while i + 2 < body.indices.count {
            let a = Int(body.indices[i]), b = Int(body.indices[i + 1]), c = Int(body.indices[i + 2])
            i += 3
            let n = simd_cross(body.positions[b] - body.positions[a], body.positions[c] - body.positions[a])
            let l = simd_length(n)
            if l > 1e-14 { tris.append((a, b, c, n / l)) }
        }
        triangles = tris
        let diagonal = lo.x.isFinite ? Swift.max(simd_length(hi - lo), 1e-6) : 1
        tolerance = diagonal * 1e-5
        cell = diagonal / Swift.max(1, Double(tris.count).squareRoot()) * 2
        for (k, t) in tris.enumerated() {
            let pa = positions[t.0], pb = positions[t.1], pc = positions[t.2]
            let mn = simd_min(pa, simd_min(pb, pc)) - SIMD3(repeating: tolerance)
            let mx = simd_max(pa, simd_max(pb, pc)) + SIMD3(repeating: tolerance)
            let c0 = cellOf(mn), c1 = cellOf(mx)
            for x in c0.x...c1.x { for y in c0.y...c1.y { for z in c0.z...c1.z {
                buckets[SIMD3(x, y, z), default: []].append(k)
            } } }
        }
    }

    private func cellOf(_ p: SIMD3<Double>) -> SIMD3<Int> {
        SIMD3(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down)), Int((p.z / cell).rounded(.down)))
    }

    func isCrease(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        guard !triangles.isEmpty else { return true }
        let m = (a + b) / 2
        var normals: [SIMD3<Double>] = []
        for k in buckets[cellOf(m)] ?? [] {
            let t = triangles[k]
            let pa = positions[t.0], pb = positions[t.1], pc = positions[t.2]
            guard abs(simd_dot(m - pa, t.3)) <= tolerance else { continue }
            // Inside or on the triangle (barycentric, with slack).
            let v0 = pb - pa, v1 = pc - pa, v2 = m - pa
            let d00 = simd_dot(v0, v0), d01 = simd_dot(v0, v1), d11 = simd_dot(v1, v1)
            let d20 = simd_dot(v2, v0), d21 = simd_dot(v2, v1)
            let den = d00 * d11 - d01 * d01
            guard abs(den) > 1e-18 else { continue }
            let v = (d11 * d20 - d01 * d21) / den, w = (d00 * d21 - d01 * d20) / den
            let slack = 1e-6
            guard v >= -slack, w >= -slack, v + w <= 1 + slack else { continue }
            normals.append(t.3)
        }
        // Nothing found (an edge off the mesh): keep it rather than guess.
        guard let first = normals.first else { return true }
        let cosLimit = cos(2.0 * .pi / 180)
        return normals.contains { simd_dot($0, first) < cosLimit }
    }
}
