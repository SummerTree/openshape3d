//
//  SweepLoftKit.swift
//  openshape3d
//
//  Sweep (profile along a 3D spine), Loft (over ordered planar profiles),
//  and Helix path generation (plan §B1/§B2/§B16, spec §4.11/§4.5/§1.17).
//  Sweep transports the profile frame manually (parallel transport with
//  mitred corner sections) so sharp spine corners behave like the union of
//  the straight legs instead of self-folding. All math in Double; results
//  are healed with makeWatertight().
//

import Foundation
import simd
import Euclid

nonisolated enum SweepLoftKit {

    // MARK: - Sweep

    /// Sweep a closed profile (with optional holes) along a 3D polyline
    /// spine in world space. The profile is anchored at the spine start:
    /// its plane-local coordinates are taken relative to the projection of
    /// `spine[0]` onto the sketch plane, so a spine starting on the plane
    /// reproduces the profile exactly at the first section (Shapr3D's
    /// "profile positioned at the path start"). The section frame is the
    /// sketch-plane basis rotated onto the first tangent, then parallel-
    /// transported along the spine; interior corners get a section on the
    /// bisector plane stretched by 1/cos(halfAngle) (mitre joint).
    static func sweep(
        profile: Profile,
        holes: [Profile] = [],
        in plane: SketchPlane,
        alongPath spine: [SIMD3<Double>]
    ) -> Euclid.Mesh {
        let spine = deduplicated(spine)
        guard spine.count >= 2, profile.loop.count >= 3 else {
            return Euclid.Mesh([])
        }
        let anchor = plane.toLocal(spine[0])

        var solid = sweepLoop(
            profile.loop, relativeTo: anchor, in: plane, along: spine
        )
        guard !solid.polygons.isEmpty else { return solid }

        if !holes.isEmpty {
            // Extend the tool spine past both ends so the hole's caps don't
            // sit coplanar with the solid's caps (sliver-free subtract).
            let tool = extended(spine, by: max(length(of: spine) * 1e-3, 1e-6))
            for hole in holes where hole.loop.count >= 3 {
                let cutter = sweepLoop(
                    hole.loop, relativeTo: anchor, in: plane, along: tool
                )
                guard !cutter.polygons.isEmpty else { continue }
                solid = solid.subtracting(cutter).makeWatertight()
            }
        }
        return solid.makeWatertight()
    }

    /// Loft one closed loop along the spine: build transported sections and
    /// stitch them with Euclid's loft (which also caps the ends).
    private static func sweepLoop(
        _ loop: [SIMD2<Double>],
        relativeTo anchor: SIMD2<Double>,
        in plane: SketchPlane,
        along spine: [SIMD3<Double>]
    ) -> Euclid.Mesh {
        let sections = sweepSections(
            loop, relativeTo: anchor, in: plane, along: spine
        )
        guard sections.count >= 2 else { return Euclid.Mesh([]) }
        return Euclid.Mesh.loft(sections).makeWatertight()
    }

    /// Closed section paths along the spine (one per spine point), with
    /// mitre-stretched sections at interior corners.
    static func sweepSections(
        _ loop: [SIMD2<Double>],
        relativeTo anchor: SIMD2<Double>,
        in plane: SketchPlane,
        along spine: [SIMD3<Double>]
    ) -> [Euclid.Path] {
        guard spine.count >= 2, loop.count >= 3 else { return [] }
        let local = loop.map { $0 - anchor }
        let tangents = (0..<spine.count - 1).map {
            simd_normalize(spine[$0 + 1] - spine[$0])
        }

        // Initial frame: plane basis rotated so the normal lands on the
        // first tangent (minimal rotation — no spin about the tangent).
        let r0 = rotation(from: simd_normalize(plane.normal), to: tangents[0])
        var u = simd_act(r0, plane.xAxis)
        var v = simd_act(r0, plane.yAxis)

        func section(
            at point: SIMD3<Double>,
            stretch: (factor: Double, axis: SIMD3<Double>)? = nil
        ) -> Euclid.Path {
            var points = local.map { q -> PathPoint in
                var offset = u * q.x + v * q.y
                if let (factor, axis) = stretch {
                    offset += (factor - 1) * simd_dot(offset, axis) * axis
                }
                let w = point + offset
                return .point(w.x, w.y, w.z)
            }
            if let first = points.first {
                points.append(first)
            }
            return Euclid.Path(points)
        }

        var sections = [section(at: spine[0])]
        for i in 1..<spine.count - 1 {
            let turn = rotation(from: tangents[i - 1], to: tangents[i])
            let angle = turn.angle
            guard angle > 1e-9 else {
                sections.append(section(at: spine[i]))
                continue
            }
            let half = simd_quatd(angle: angle / 2, axis: turn.axis)
            u = simd_act(half, u)
            v = simd_act(half, v)
            // Mitre: widen the bisector-plane section along the in-plane
            // turn direction so the straight legs meet like extrusions.
            // Clamp for near-reversals (the mitre would go to infinity).
            let bisector = simd_normalize(tangents[i - 1] + tangents[i])
            let axis = simd_normalize(simd_cross(bisector, turn.axis))
            let factor = 1 / max(cos(angle / 2), 0.1)
            sections.append(section(at: spine[i], stretch: (factor, axis)))
            u = simd_act(half, u)
            v = simd_act(half, v)
        }
        sections.append(section(at: spine[spine.count - 1]))
        return sections
    }

    // MARK: - Loft

    /// Loft a solid through 2+ ordered planar profiles (spec §4.5,
    /// profiles-only tier). Outlines are resampled to a common vertex count
    /// (uniform arc-length) when counts differ so sections pair ring-to-ring
    /// without fan triangles; Euclid's loft handles start-vertex alignment
    /// on parallel sections and caps the ends. Holes are lofted as compound
    /// subpaths when every section carries the same number of holes;
    /// otherwise holes are ignored (v1).
    static func loft(
        profiles: [(profile: Profile, holes: [Profile], plane: SketchPlane)]
    ) -> Euclid.Mesh {
        guard profiles.count >= 2,
              profiles.allSatisfy({ $0.profile.loop.count >= 3 })
        else { return Euclid.Mesh([]) }

        let outers = commonCountLoops(profiles.map { ccwLoop($0.profile) })

        let holeCounts = Set(profiles.map { $0.holes.count })
        var holeFamilies: [[[SIMD2<Double>]]] = []
        if let count = holeCounts.first, holeCounts.count == 1, count > 0 {
            // holeFamilies[h][s] = hole h's loop on section s.
            holeFamilies = (0..<count).map { h in
                commonCountLoops(profiles.map { ccwLoop($0.holes[h]) })
            }
        }

        let sections = profiles.enumerated().map { s, entry -> Euclid.Path in
            let outer = closedWorldPath(outers[s], in: entry.plane)
            guard !holeFamilies.isEmpty else { return outer }
            let holes = holeFamilies.map { closedWorldPath($0[s], in: entry.plane) }
            return Euclid.Path(subpaths: [outer] + holes)
        }
        return Euclid.Mesh.loft(sections).makeWatertight()
    }

    /// Loop with positive (CCW) signed area.
    private static func ccwLoop(_ profile: Profile) -> [SIMD2<Double>] {
        profile.area < 0 ? profile.loop.reversed() : profile.loop
    }

    /// Resample all loops to a shared vertex count when they differ.
    private static func commonCountLoops(
        _ loops: [[SIMD2<Double>]]
    ) -> [[SIMD2<Double>]] {
        let counts = Set(loops.map(\.count))
        guard counts.count > 1, let target = counts.max() else { return loops }
        return loops.map { resampleClosedLoop($0, to: target) }
    }

    /// Uniform arc-length resampling of a closed loop to `count` points,
    /// starting at the loop's first vertex. Vertices whose arc length lands
    /// exactly on a sample position (e.g. square corners with a count
    /// divisible by 4) are preserved exactly.
    static func resampleClosedLoop(
        _ loop: [SIMD2<Double>], to count: Int
    ) -> [SIMD2<Double>] {
        guard loop.count >= 3, count >= 3, loop.count != count else {
            return loop
        }
        var cumulative = [0.0]
        cumulative.reserveCapacity(loop.count + 1)
        for i in 0..<loop.count {
            let step = simd_length(loop[(i + 1) % loop.count] - loop[i])
            cumulative.append(cumulative[i] + step)
        }
        guard let total = cumulative.last, total > 1e-12 else { return loop }

        var result = [SIMD2<Double>]()
        result.reserveCapacity(count)
        var segment = 0
        for i in 0..<count {
            let target = Double(i) / Double(count) * total
            while segment < loop.count - 1, cumulative[segment + 1] < target {
                segment += 1
            }
            let a = loop[segment]
            let b = loop[(segment + 1) % loop.count]
            let span = cumulative[segment + 1] - cumulative[segment]
            let t = span > 1e-12 ? (target - cumulative[segment]) / span : 0
            result.append(a + (b - a) * t)
        }
        return result
    }

    // MARK: - Shared helpers

    /// Closed Euclid path of a plane-local loop mapped into world space.
    static func closedWorldPath(
        _ loop: [SIMD2<Double>], in plane: SketchPlane
    ) -> Euclid.Path {
        var points = loop.map { p -> PathPoint in
            let w = plane.toWorld(p)
            return .point(w.x, w.y, w.z)
        }
        if let first = points.first {
            points.append(first)
        }
        return Euclid.Path(points)
    }

    /// Minimal rotation carrying unit vector `a` onto unit vector `b`
    /// (identity when parallel; a well-defined half-turn when opposite).
    static func rotation(
        from a: SIMD3<Double>, to b: SIMD3<Double>
    ) -> simd_quatd {
        let dot = simd_dot(a, b)
        if dot > 1 - 1e-12 {
            return simd_quatd(angle: 0, axis: SIMD3(1, 0, 0))
        }
        if dot < -1 + 1e-12 {
            let helper: SIMD3<Double> =
                abs(a.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            return simd_quatd(angle: .pi, axis: simd_normalize(simd_cross(a, helper)))
        }
        return simd_quatd(from: a, to: b)
    }

    /// Drop consecutive duplicate points (they would produce NaN tangents).
    private static func deduplicated(
        _ points: [SIMD3<Double>]
    ) -> [SIMD3<Double>] {
        var result = [SIMD3<Double>]()
        result.reserveCapacity(points.count)
        for p in points where result.last.map({ simd_length(p - $0) > 1e-12 }) ?? true {
            result.append(p)
        }
        return result
    }

    private static func length(of spine: [SIMD3<Double>]) -> Double {
        (0..<spine.count - 1).reduce(0) {
            $0 + simd_length(spine[$1 + 1] - spine[$1])
        }
    }

    /// Push both endpoints outward along their segment directions (the
    /// endpoints stay collinear with their segments, so the geometry only
    /// lengthens).
    private static func extended(
        _ spine: [SIMD3<Double>], by distance: Double
    ) -> [SIMD3<Double>] {
        var result = spine
        let n = spine.count
        result[0] -= simd_normalize(spine[1] - spine[0]) * distance
        result[n - 1] += simd_normalize(spine[n - 1] - spine[n - 2]) * distance
        return result
    }
}

// MARK: - Helix

nonisolated enum HelixKit {

    /// Tessellated helical polyline usable as a Sweep spine (spec §1.17).
    /// The helix coils about the plane normal through `center` (plane-local
    /// coordinates), starting on the plane at angle `startAt` (radians from
    /// the plane's x axis) and climbing `pitch` per turn along +normal
    /// (negative pitch descends). `clockwise` reverses the coil direction
    /// as seen looking down the plane normal. Returns turns × segmentsPerTurn
    /// segments (+1 point), with the final point exactly at the helix end.
    static func path(
        radius: Double,
        pitch: Double,
        turns: Double,
        clockwise: Bool = false,
        startAt startAngle: Double = 0,
        center: SIMD2<Double> = .zero,
        in plane: SketchPlane,
        segmentsPerTurn: Int = 48
    ) -> [SIMD3<Double>] {
        guard radius > 1e-12, turns > 1e-9, segmentsPerTurn >= 3 else {
            return []
        }
        let steps = max(1, Int((turns * Double(segmentsPerTurn)).rounded(.up)))
        let normal = simd_normalize(plane.normal)
        var points = [SIMD3<Double>]()
        points.reserveCapacity(steps + 1)
        for i in 0...steps {
            // Parameter in turns, clamped so a fractional last step still
            // ends exactly at `turns`.
            let t = min(Double(i) / Double(segmentsPerTurn), turns)
            let angle = startAngle + (clockwise ? -1 : 1) * t * 2 * .pi
            let q = center + radius * SIMD2(cos(angle), sin(angle))
            points.append(plane.toWorld(q) + normal * (pitch * t))
        }
        return points
    }
}

// MARK: - KernelOps facade

nonisolated extension KernelOps {

    /// Sweep a closed profile (with optional holes) along a 3D spine
    /// polyline in world space (plan §B1). See `SweepLoftKit.sweep`.
    static func sweep(
        profile: Profile,
        holes: [Profile] = [],
        in plane: SketchPlane,
        alongPath spine: [SIMD3<Double>]
    ) -> Euclid.Mesh {
        SweepLoftKit.sweep(
            profile: profile, holes: holes, in: plane, alongPath: spine
        )
    }

    /// Loft a solid through 2+ ordered planar profiles (plan §B2). See
    /// `SweepLoftKit.loft`.
    static func loft(
        profiles: [(profile: Profile, holes: [Profile], plane: SketchPlane)]
    ) -> Euclid.Mesh {
        SweepLoftKit.loft(profiles: profiles)
    }
}
