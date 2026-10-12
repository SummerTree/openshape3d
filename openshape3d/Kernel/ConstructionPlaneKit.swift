//
//  ConstructionPlaneKit.swift
//  openshape3d
//
//  Construct ▸ Plane (spec §6.1): the seven ways to define a construction
//  plane, as pure geometry. Every input is already in WORLD space (the editor
//  resolves picks first), every output is a `SketchPlane` laid out with
//  `SketchPlane.readable`, and every degenerate input returns nil so the bar
//  can say "can't build a plane from this" instead of propagating NaNs.
//

import Foundation
import simd

/// The plane constructions offered under Construct ▸ Plane, in menu order.
nonisolated enum PlaneConstruction: String, CaseIterable, Codable, Sendable {
    case offset
    case midplane
    case threePoints
    case onCurveAtPoint
    case perpendicularToEdgeAtPoint
    case throughEdgeAtAngle
    case parallelToFaceAtPoint

    var title: String {
        switch self {
        case .offset: return "Offset Plane"
        case .midplane: return "Midplane"
        case .threePoints: return "Plane Through 3 Points"
        case .onCurveAtPoint: return "Plane on Curve at Point"
        case .perpendicularToEdgeAtPoint: return "Plane Perpendicular to Edge at Point"
        case .throughEdgeAtAngle: return "Plane Through Edge at Angle"
        case .parallelToFaceAtPoint: return "Plane Parallel to Face at Point"
        }
    }

    var symbol: String {
        switch self {
        case .offset: return "square.3.layers.3d.top.filled"
        case .midplane: return "square.3.layers.3d.middle.filled"
        case .threePoints: return "point.3.connected.trianglepath.dotted"
        case .onCurveAtPoint: return "point.topleft.down.to.point.bottomright.curvepath"
        case .perpendicularToEdgeAtPoint: return "arrow.up.and.line.horizontal.and.arrow.down"
        case .throughEdgeAtAngle: return "angle"
        case .parallelToFaceAtPoint: return "square.on.square"
        }
    }

    /// What each pick slot must be, in order.
    var slots: [ConstructionPickKind] {
        switch self {
        case .offset: return [.face]
        case .midplane: return [.face, .face]
        case .threePoints: return [.point, .point, .point]
        case .onCurveAtPoint: return [.curve]
        case .perpendicularToEdgeAtPoint: return [.edge, .point]
        case .throughEdgeAtAngle: return [.edge, .face]
        case .parallelToFaceAtPoint: return [.face, .point]
        }
    }

    var usesOffset: Bool { self == .offset }
    var usesAngle: Bool { self == .throughEdgeAtAngle }
    var usesCurvePosition: Bool { self == .onCurveAtPoint }
}

/// The kind of reference a construction pick slot accepts.
nonisolated enum ConstructionPickKind: String, Codable, Sendable {
    case point, face, edge, curve

    /// The bar's prompt while this slot is the next one to fill.
    var prompt: String {
        switch self {
        case .point: return "Tap a point"
        case .face: return "Tap a flat face or plane"
        case .edge: return "Tap a straight edge"
        case .curve: return "Tap an edge or curve"
        }
    }
}

/// One resolved reference, in world space.
nonisolated enum ConstructionPick: Equatable, Sendable {
    case point(SIMD3<Double>)
    /// A planar face or a construction plane; `origin` is the tapped point on it.
    case face(origin: SIMD3<Double>, normal: SIMD3<Double>)
    /// A straight edge; `at` is the tap projected onto it.
    case edge(start: SIMD3<Double>, end: SIMD3<Double>, at: SIMD3<Double>)
    /// An ordered polyline (a tessellated curve, or a single straight edge);
    /// `at` is the tap projected onto it.
    case curve(points: [SIMD3<Double>], at: SIMD3<Double>)

    var kind: ConstructionPickKind {
        switch self {
        case .point: return .point
        case .face: return .face
        case .edge: return .edge
        case .curve: return .curve
        }
    }
}

nonisolated enum ConstructionPlaneKit {

    /// Parallel within ~0.6°.
    static let parallelCosine = 0.99995

    /// **Offset Plane** — the face plane moved `distance` along its normal.
    static func offset(
        origin: SIMD3<Double>, normal: SIMD3<Double>, distance: Double
    ) -> SketchPlane? {
        guard let n = unit(normal) else { return nil }
        return SketchPlane.readable(origin: origin + n * distance, normal: n)
    }

    /// **Midplane** — halfway between two parallel planes; for two planes
    /// that meet, the plane of symmetry through their common line (the
    /// bisector whose normal is `nA − nB`, which for two faces of a corner
    /// is the corner's mirror plane).
    static func midplane(
        aOrigin: SIMD3<Double>, aNormal: SIMD3<Double>,
        bOrigin: SIMD3<Double>, bNormal: SIMD3<Double>
    ) -> SketchPlane? {
        guard let nA = unit(aNormal), let nB = unit(bNormal) else { return nil }
        if abs(simd_dot(nA, nB)) >= parallelCosine {
            let gap = simd_dot(bOrigin - aOrigin, nA)
            // Coincident planes have no "between".
            guard abs(gap) > 1e-9 else { return nil }
            // Keep the origin over the middle of the two taps, not at A's tap.
            let mid = (aOrigin + bOrigin) / 2
            let onA = mid - nA * simd_dot(mid - aOrigin, nA)
            return SketchPlane.readable(origin: onA + nA * gap / 2, normal: nA)
        }
        guard let line = ConstructionAxisKit.intersection(
            planeAOrigin: aOrigin, planeANormal: nA,
            planeBOrigin: bOrigin, planeBNormal: nB
        ), let n = unit(nA - nB) else { return nil }
        // Origin: the point on the common line nearest the two taps.
        let mid = (aOrigin + bOrigin) / 2
        return SketchPlane.readable(origin: line.closestPoint(to: mid), normal: n)
    }

    /// **Plane Through 3 Points** — nil when they are collinear.
    static func throughPoints(
        _ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>
    ) -> SketchPlane? {
        let cross = simd_cross(b - a, c - a)
        let scale = max(simd_length(b - a), simd_length(c - a), 1e-12)
        guard simd_length(cross) > 1e-9 * scale * scale, let n = unit(cross) else { return nil }
        return SketchPlane.readable(origin: (a + b + c) / 3, normal: n)
    }

    /// **Plane on Curve at Point** — normal to the curve's tangent at the
    /// point `fraction` (0…1) of the way along it by length.
    static func onCurve(_ points: [SIMD3<Double>], fraction: Double) -> SketchPlane? {
        guard let (point, tangent) = sample(points, fraction: fraction) else { return nil }
        return SketchPlane.readable(origin: point, normal: tangent)
    }

    /// **Plane Perpendicular to Edge at Point** — the edge direction as the
    /// normal, through `point` (which need not lie on the edge).
    static func perpendicular(
        toEdgeFrom start: SIMD3<Double>, to end: SIMD3<Double>, at point: SIMD3<Double>
    ) -> SketchPlane? {
        guard let n = unit(end - start) else { return nil }
        return SketchPlane.readable(origin: point, normal: n)
    }

    /// **Plane Through Edge at Angle** — the plane that contains the edge,
    /// starting in the reference face's plane and turned `degrees` about the
    /// edge. Nil when the edge is parallel to the face normal (the face plane
    /// can't contain it, so there is no starting orientation).
    static func throughEdge(
        from start: SIMD3<Double>, to end: SIMD3<Double>,
        referenceNormal: SIMD3<Double>, degrees: Double
    ) -> SketchPlane? {
        guard let d = unit(end - start), let ref = unit(referenceNormal) else { return nil }
        // The reference normal with its along-edge part removed: the normal
        // of the plane through the edge that is closest to the face plane.
        guard let n0 = unit(ref - d * simd_dot(ref, d)) else { return nil }
        let turned = simd_quatd(angle: degrees * .pi / 180, axis: d).act(n0)
        return SketchPlane.readable(origin: (start + end) / 2, normal: turned)
    }

    /// **Plane Parallel to Face at Point** — the face normal through `point`.
    static func parallel(toFaceNormal normal: SIMD3<Double>, at point: SIMD3<Double>) -> SketchPlane? {
        guard let n = unit(normal) else { return nil }
        return SketchPlane.readable(origin: point, normal: n)
    }

    /// Builds the plane `construction` describes from filled `picks`, or nil
    /// when a slot is still empty or the references are degenerate.
    static func derive(
        _ construction: PlaneConstruction,
        picks: [ConstructionPick],
        offset: Double, degrees: Double, curveFraction: Double
    ) -> SketchPlane? {
        let slots = construction.slots
        guard picks.count == slots.count,
              zip(picks, slots).allSatisfy({ $0.kind == $1 })
        else { return nil }
        switch construction {
        case .offset:
            guard case let .face(o, n) = picks[0] else { return nil }
            return Self.offset(origin: o, normal: n, distance: offset)
        case .midplane:
            guard case let .face(oA, nA) = picks[0], case let .face(oB, nB) = picks[1] else { return nil }
            return midplane(aOrigin: oA, aNormal: nA, bOrigin: oB, bNormal: nB)
        case .threePoints:
            guard case let .point(a) = picks[0], case let .point(b) = picks[1],
                  case let .point(c) = picks[2] else { return nil }
            return throughPoints(a, b, c)
        case .onCurveAtPoint:
            guard case let .curve(points, _) = picks[0] else { return nil }
            return onCurve(points, fraction: curveFraction)
        case .perpendicularToEdgeAtPoint:
            guard case let .edge(s, e, _) = picks[0], case let .point(p) = picks[1] else { return nil }
            return perpendicular(toEdgeFrom: s, to: e, at: p)
        case .throughEdgeAtAngle:
            guard case let .edge(s, e, _) = picks[0], case let .face(_, n) = picks[1] else { return nil }
            return throughEdge(from: s, to: e, referenceNormal: n, degrees: degrees)
        case .parallelToFaceAtPoint:
            guard case let .face(_, n) = picks[0], case let .point(p) = picks[1] else { return nil }
            return parallel(toFaceNormal: n, at: p)
        }
    }

    // MARK: - Polylines

    /// Length fraction (0…1) of the point on `points` nearest `p`.
    static func fraction(of p: SIMD3<Double>, along points: [SIMD3<Double>]) -> Double {
        let total = length(points)
        guard points.count >= 2, total > 1e-12 else { return 0 }
        var best = (distance: Double.infinity, along: 0.0)
        var walked = 0.0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let seg = b - a
            let len = simd_length(seg)
            guard len > 1e-12 else { continue }
            let t = min(max(simd_dot(p - a, seg) / (len * len), 0), 1)
            let d = simd_length(p - (a + seg * t))
            if d < best.distance { best = (d, walked + t * len) }
            walked += len
        }
        return best.along / total
    }

    /// The point `fraction` of the way along `points` and the unit tangent
    /// there. At an interior vertex the tangent averages the two segments so a
    /// tessellated arc gives its true tangent rather than one facet's.
    static func sample(
        _ points: [SIMD3<Double>], fraction: Double
    ) -> (point: SIMD3<Double>, tangent: SIMD3<Double>)? {
        guard points.count >= 2 else { return nil }
        let total = length(points)
        guard total > 1e-12 else { return nil }
        let target = min(max(fraction, 0), 1) * total
        var walked = 0.0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let len = simd_length(b - a)
            guard len > 1e-12 else { continue }
            if walked + len >= target - 1e-12 || i == points.count - 1 {
                let t = min(max((target - walked) / len, 0), 1)
                var tangent = (b - a) / len
                // Blend with the neighbouring segment near a vertex.
                if t > 0.999, i + 1 < points.count, let next = unit(points[i + 1] - b) {
                    tangent = tangent + next
                } else if t < 0.001, i >= 2, let prev = unit(a - points[i - 2]) {
                    tangent = tangent + prev
                }
                guard let unitTangent = unit(tangent) else { return nil }
                return (a + (b - a) * t, unitTangent)
            }
            walked += len
        }
        return nil
    }

    static func length(_ points: [SIMD3<Double>]) -> Double {
        guard points.count >= 2 else { return 0 }
        return (1..<points.count).reduce(0) { $0 + simd_length(points[$1] - points[$1 - 1]) }
    }

    /// Orders unordered segments that form one open or closed chain into a
    /// polyline. Nil when they don't form a single chain.
    static func polyline(
        from segments: [(SIMD3<Double>, SIMD3<Double>)], tolerance: Double = 1e-6
    ) -> [SIMD3<Double>]? {
        guard var remaining = Optional(segments), !remaining.isEmpty else { return nil }
        func same(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool { simd_length(a - b) <= tolerance }
        let first = remaining.removeFirst()
        var chain = [first.0, first.1]
        var grew = true
        while grew, !remaining.isEmpty {
            grew = false
            for (i, s) in remaining.enumerated() {
                if same(s.0, chain.last!) { chain.append(s.1) }
                else if same(s.1, chain.last!) { chain.append(s.0) }
                else if same(s.1, chain.first!) { chain.insert(s.0, at: 0) }
                else if same(s.0, chain.first!) { chain.insert(s.1, at: 0) }
                else { continue }
                remaining.remove(at: i)
                grew = true
                break
            }
        }
        return remaining.isEmpty ? chain : nil
    }

    private static func unit(_ v: SIMD3<Double>) -> SIMD3<Double>? {
        let len = simd_length(v)
        guard len > 1e-12, len.isFinite else { return nil }
        return v / len
    }
}
