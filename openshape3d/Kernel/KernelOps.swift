//
//  KernelOps.swift
//  openshape3d
//
//  Solid-modeling operations on top of Euclid: profile extrusion and booleans.
//

import Foundation
import simd
import Euclid

nonisolated extension KernelOps {
    /// A cylinder along an arbitrary axis, base at `baseCenter`, extending
    /// `height` along `axisDir`. Used to radially grow/shrink a body that is a
    /// plain cylinder (curved-face push/pull).
    static func cylinderAlongAxis(
        baseCenter: SIMD3<Double>,
        axisDir: SIMD3<Double>,
        radius: Double,
        height: Double,
        slices: Int = 48
    ) -> Euclid.Mesh {
        // Euclid cylinder is centred at the origin along +Y; shift base to y=0.
        let cyl = Euclid.Mesh.cylinder(radius: radius, height: height, slices: slices)
            .translated(by: Vector(0, height / 2, 0))
        let rotation = Rotation(simd_quatd(from: SIMD3(0, 1, 0), to: simd_normalize(axisDir)))
        let transform = Euclid.Transform(
            rotation: rotation,
            translation: Vector(baseCenter.x, baseCenter.y, baseCenter.z)
        )
        return cyl.transformed(by: transform)
    }
}

/// Axis of revolution: a 2D line (point + direction) in sketch-plane
/// coordinates.
nonisolated struct RevolveAxis: Equatable, Sendable {
    var point: SIMD2<Double>
    var direction: SIMD2<Double>
}

nonisolated enum KernelOps {

    /// Extrude a closed profile (with optional holes) along the plane normal.
    /// Positive distance pulls along +normal; negative pushes the other way.
    /// The profile face stays on the sketch plane. `symmetric` centers the
    /// solid on the plane instead: `distance` is the per-side value, so the
    /// total depth is 2× (Shapr3D's Symmetric sides).
    static func extrude(
        profile: Profile,
        holes: [Profile] = [],
        in plane: SketchPlane,
        distance: Double,
        symmetric: Bool = false
    ) -> Euclid.Mesh {
        let depth = abs(distance) * (symmetric ? 2 : 1)
        guard depth > 1e-6 else { return Euclid.Mesh([]) }

        var solid = extrudeLoop(profile, depth: depth)
        for hole in holes {
            // Cut holes with a slightly deeper tool so coplanar caps don't
            // leave slivers.
            let tool = extrudeLoop(hole, depth: depth * 1.002)
            solid = solid.subtracting(tool).makeWatertight()
        }

        // Euclid centers extrusion on the path plane: symmetric extrudes stay
        // centered; one-sided shifts so the base sits on the sketch plane.
        let offset = symmetric ? 0 : distance / 2
        solid = solid.translated(by: Vector(0, 0, offset))

        // Map plane-local (x, y, z=normal) into world space.
        let transform = planeToWorld(plane)
        return solid.transformed(by: transform)
    }

    /// A slightly overlapped extrude prism (union of all profile prisms) for use
    /// as a boolean CUT tool: the prism is padded ~0.001–0.002 past the flush
    /// extent so coplanar / flush cut faces merge cleanly instead of leaving
    /// hanging thin walls. Shared by the live extrude-cut (EditorViewModel) and
    /// the feature-graph replay so both produce identical cut geometry.
    static func overlapExtrudeTool(
        profile: Profile,
        holes: [Profile],
        extraProfiles: [(profile: Profile, holes: [Profile])],
        in plane: SketchPlane,
        distance: Double,
        symmetric: Bool
    ) -> Euclid.Mesh {
        let n = plane.normal
        let sign: Double = distance >= 0 ? 1 : -1
        func tool(_ profile: Profile, _ holes: [Profile]) -> Euclid.Mesh {
            if symmetric {
                // Symmetric solids straddle the plane: pad both sides.
                return extrude(
                    profile: profile, holes: holes, in: plane,
                    distance: distance + sign * 0.001, symmetric: true)
            }
            return extrude(
                profile: profile, holes: holes, in: plane,
                distance: distance + sign * 0.002
            ).translated(by: Vector(-n.x * sign * 0.001, -n.y * sign * 0.001, -n.z * sign * 0.001))
        }
        var solid = tool(profile, holes)
        for extra in extraProfiles {
            solid = solid.union(tool(extra.profile, extra.holes))
        }
        return solid
    }

    private static func extrudeLoop(_ profile: Profile, depth: Double) -> Euclid.Mesh {
        let path = closedPath(for: profile)
        return Euclid.Mesh.extrude(path, depth: depth)
    }

    /// Closed CCW path in plane-local XY.
    static func closedPath(for profile: Profile) -> Euclid.Path {
        var points = profile.loop.map { PathPoint.point($0.x, $0.y) }
        if let first = points.first {
            points.append(first)
        }
        return Euclid.Path(points)
    }

    /// Rotation+translation mapping plane-local coordinates (x→xAxis, y→yAxis,
    /// z→normal) into world space.
    static func planeToWorld(_ plane: SketchPlane) -> Euclid.Transform {
        let x = plane.xAxis
        let y = plane.yAxis
        let z = plane.normal
        // Build a quaternion from the orthonormal basis matrix.
        let matrix = simd_double3x3(
            SIMD3(x.x, x.y, x.z),
            SIMD3(y.x, y.y, y.z),
            SIMD3(z.x, z.y, z.z)
        )
        let quaternion = simd_quatd(matrix)
        return Euclid.Transform(
            rotation: Rotation(quaternion),
            translation: Vector(plane.origin.x, plane.origin.y, plane.origin.z)
        )
    }

    // MARK: - Revolve

    /// Revolve a closed profile (with optional holes) about a 2D axis line in
    /// the sketch plane. `angle` is degrees; >= 360 is a full revolution,
    /// partial angles sweep right-handed about the axis direction (viewed with
    /// the profile on the local +x side). Profiles crossing the axis are
    /// rejected with an empty mesh (Shapr3D errors there too).
    static func revolve(
        profile: Profile,
        holes: [Profile] = [],
        in plane: SketchPlane,
        axis: RevolveAxis,
        angle: Double = 360
    ) -> Euclid.Mesh {
        guard angle > 1e-6 else { return Euclid.Mesh([]) }
        let dirLength = simd_length(axis.direction)
        guard dirLength > 1e-12 else { return Euclid.Mesh([]) }
        let d = axis.direction / dirLength

        // Signed distance from the axis line, positive on the +perp side.
        var perp = SIMD2(d.y, -d.x)
        let tolerance = 1e-7
        let signed = profile.loop.map { simd_dot($0 - axis.point, perp) }
        let minS = signed.min() ?? 0
        let maxS = signed.max() ?? 0
        if minS < -tolerance, maxS > tolerance { return Euclid.Mesh([]) }
        // Degenerate: profile collapsed onto the axis.
        guard max(maxS, -minS) > tolerance else { return Euclid.Mesh([]) }
        if maxS <= tolerance {
            // Mirror so the profile lands on lathe's required +x side. Winding
            // flips too; Euclid's latheProfile normalizes it.
            perp = -perp
        }

        // Lathe space: x = radial distance, y = along the axis. Euclid lathe
        // revolves an XY path around the Y axis (x >= 0), with the point at
        // sweep angle a landing on (x·cos a, y, -x·sin a).
        func lathePath(_ p: Profile) -> Euclid.Path {
            var points = p.loop.map { point -> PathPoint in
                let r = point - axis.point
                return PathPoint.point(max(0, simd_dot(r, perp)), simd_dot(r, d))
            }
            if let first = points.first {
                points.append(first)
            }
            return Euclid.Path(points)
        }

        var solid = Euclid.Mesh.lathe(lathePath(profile), slices: 48)
        for hole in holes {
            // Hole loops are strictly inside the profile, so the revolved
            // tool surfaces never coincide with the solid's — no offset fudge.
            let tool = Euclid.Mesh.lathe(lathePath(hole), slices: 48)
            solid = solid.subtracting(tool).makeWatertight()
        }

        if angle < 360 - 1e-9 {
            solid = intersectWithWedge(solid, degrees: angle)
        }

        // Lathe space → plane-local (x, y, z=normal) → world.
        let e0 = SIMD3(perp.x, perp.y, 0.0)
        let e1 = SIMD3(d.x, d.y, 0.0)
        let matrix = simd_double3x3(e0, e1, simd_cross(e0, e1))
        let latheToPlane = Euclid.Transform(
            rotation: Rotation(simd_quatd(matrix)),
            translation: Vector(axis.point.x, axis.point.y, 0)
        )
        return solid
            .transformed(by: latheToPlane)
            .transformed(by: planeToWorld(plane))
    }

    /// Intersect a lathed solid (axis = +y through the origin) with a wedge
    /// spanning `degrees` of the sweep, starting at the +x half-plane and
    /// rotating toward -z (Euclid's lathe sweep direction).
    private static func intersectWithWedge(
        _ solid: Euclid.Mesh,
        degrees: Double
    ) -> Euclid.Mesh {
        let bounds = solid.bounds
        let radius = max(bounds.min.length, bounds.max.length) * 1.5
        guard radius > 0 else { return solid }

        // Half-space { dot(p, normal) <= 0 } as a large cube; normals stay in
        // the xz-plane so the y basis vector is always valid.
        func halfSpace(_ normal: SIMD3<Double>) -> Euclid.Mesh {
            let cube = Euclid.Mesh.cube(
                center: Vector(0, 0, -radius),
                size: Vector(radius * 4, radius * 4, radius * 2)
            )
            let e0 = SIMD3(normal.z, 0, -normal.x)
            let matrix = simd_double3x3(e0, SIMD3(0, 1, 0), normal)
            return cube.rotated(by: Rotation(simd_quatd(matrix)))
        }

        let theta = degrees * Double.pi / 180
        // Start plane keeps z <= 0; end plane is { z >= 0 } rotated by theta.
        let startKeep = SIMD3<Double>(0, 0, 1)
        let endKeep = SIMD3<Double>(-sin(theta), 0, -cos(theta))
        if theta <= Double.pi + 1e-9 {
            return solid
                .intersection(halfSpace(startKeep))
                .intersection(halfSpace(endKeep))
                .makeWatertight()
        }
        // Reflex wedge: subtract the complementary (< 180°) wedge instead.
        let complement = halfSpace(-startKeep).intersection(halfSpace(-endKeep))
        return solid.subtracting(complement).makeWatertight()
    }

    // MARK: - Mirror

    /// Reflect a mesh across a plane (spec §5.6): mirror positions and
    /// normals, flip winding so faces stay outward, and heal the result.
    static func mirror(mesh: Euclid.Mesh, across plane: SketchPlane) -> Euclid.Mesh {
        let n = simd_normalize(plane.normal)
        let origin = plane.origin

        func reflectPoint(_ v: Vector) -> Vector {
            let p = SIMD3(v.x, v.y, v.z)
            let r = p - 2 * simd_dot(p - origin, n) * n
            return Vector(r.x, r.y, r.z)
        }
        func reflectDirection(_ v: Vector) -> Vector {
            let d = SIMD3(v.x, v.y, v.z)
            let r = d - 2 * simd_dot(d, n) * n
            return Vector(r.x, r.y, r.z)
        }

        var polygons = [Euclid.Polygon]()
        polygons.reserveCapacity(mesh.polygons.count)
        for polygon in mesh.polygons {
            let vertices = polygon.vertices.reversed().map { vertex in
                Euclid.Vertex(reflectPoint(vertex.position), reflectDirection(vertex.normal))
            }
            if let mirrored = Euclid.Polygon(vertices) {
                polygons.append(mirrored)
            }
        }
        return Euclid.Mesh(polygons).makeWatertight()
    }

    // MARK: - Booleans

    static func boolean(
        _ kind: BooleanKind,
        target: Body,
        tool: Body,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Euclid.Mesh {
        let a = target.euclidMesh().transformed(by: target.transform.euclid)
        let b = tool.euclidMesh().transformed(by: tool.transform.euclid)
        let result: Euclid.Mesh
        switch kind {
        case .union:
            result = a.union(b, isCancelled: isCancelled)
        case .subtract:
            result = a.subtracting(b, isCancelled: isCancelled)
        case .intersect:
            result = a.intersection(b, isCancelled: isCancelled)
        }
        // CSG can leave T-junction cracks along cut seams; heal them.
        return result.makeWatertight()
    }
}

// MARK: - Chamfer / Fillet (edge blends)

nonisolated extension KernelOps {

    /// Chamfer a single convex straight edge by `setback` (the flat width on
    /// each face). Builds a triangular "corner wedge" prism — cross-section
    /// `(edgePoint, edgePoint + tangentA·setback, edgePoint + tangentB·setback)`
    /// lying in the plane perpendicular to the edge — extruded along the edge and
    /// subtracted from `mesh`. `normalA`/`normalB` are the OUTWARD normals of the
    /// two faces meeting at the edge; the mesh and edge share one coordinate
    /// space. Returns `mesh` unchanged for a degenerate/non-convex request.
    static func chamferEdge(
        mesh: Euclid.Mesh,
        p0: SIMD3<Double>,
        p1: SIMD3<Double>,
        normalA: SIMD3<Double>,
        normalB: SIMD3<Double>,
        setback: Double
    ) -> Euclid.Mesh {
        guard let tool = cornerWedge(
            p0: p0, p1: p1, normalA: normalA, normalB: normalB,
            setback: setback, round: nil
        ) else { return mesh }
        return mesh.subtracting(tool).makeWatertight()
    }

    /// Fillet (round) a single convex straight edge to `radius`. Subtracts the
    /// corner wedge MINUS the fillet cylinder, so the cylinder's surface remains
    /// as the rounded blend. The setback equals `radius` for the tangent arc on
    /// a right-angle edge; general edges use the same setback (a v1 prismatic
    /// approximation). Returns `mesh` unchanged for a degenerate request.
    static func filletEdge(
        mesh: Euclid.Mesh,
        p0: SIMD3<Double>,
        p1: SIMD3<Double>,
        normalA: SIMD3<Double>,
        normalB: SIMD3<Double>,
        radius: Double
    ) -> Euclid.Mesh {
        guard let tool = cornerWedge(
            p0: p0, p1: p1, normalA: normalA, normalB: normalB,
            setback: radius, round: radius
        ) else { return mesh }
        return mesh.subtracting(tool).makeWatertight()
    }

    /// The corner-removal tool shared by chamfer and fillet. Without `round` it
    /// is the solid triangular wedge (chamfer). With `round`, the fillet cylinder
    /// (radius = round, axis = the edge, tangent to both faces) is subtracted
    /// from the wedge so the rounded surface survives the body subtraction.
    private static func cornerWedge(
        p0: SIMD3<Double>,
        p1: SIMD3<Double>,
        normalA: SIMD3<Double>,
        normalB: SIMD3<Double>,
        setback: Double,
        round: Double?
    ) -> Euclid.Mesh? {
        guard setback > 1e-6 else { return nil }
        let axis = p1 - p0
        let edgeLen = simd_length(axis)
        guard edgeLen > 1e-6 else { return nil }
        let e = axis / edgeLen

        let nA = simd_normalize(normalA)
        let nB = simd_normalize(normalB)

        // Tangents into each face, perpendicular to the edge, oriented so each
        // points INTO its face and away from the other face.
        var tA = simd_cross(nA, e)
        var tB = simd_cross(nB, e)
        let lA = simd_length(tA), lB = simd_length(tB)
        guard lA > 1e-6, lB > 1e-6 else { return nil }
        tA /= lA; tB /= lB
        if simd_dot(tA, nB) > 0 { tA = -tA }
        if simd_dot(tB, nA) > 0 { tB = -tB }

        let apex = (p0 + p1) / 2
        let sa = apex + tA * setback
        let sb = apex + tB * setback
        let overlap = max(edgeLen * 0.02, 1e-3)
        let depth = edgeLen + 2 * overlap

        // Cross-section in the plane perpendicular to the edge. A chamfer removes
        // the triangle (apex, sa, sb) — the sharp corner behind the flat. A
        // fillet removes the corner PARALLELOGRAM (apex, sa, far, sb) out to the
        // tangent points and then keeps the fillet cylinder, so the rounded
        // surface survives. Euclid centers the extrusion on the path plane
        // (normal = ±edge); depth = edgeLen + 2·overlap spans the edge cleanly.
        func extrudeSection(_ pts: [SIMD3<Double>]) -> Euclid.Mesh {
            var path = pts.map { PathPoint.point($0.x, $0.y, $0.z) }
            if let first = path.first { path.append(first) }
            return Euclid.Mesh.extrude(Euclid.Path(path), depth: depth)
        }

        guard let radius = round else {
            let wedge = extrudeSection([apex, sa, sb])
            return wedge.polygons.isEmpty ? nil : wedge
        }

        // Fillet: parallelogram corner minus the tangent cylinder.
        let far = apex + tA * setback + tB * setback
        var corner = extrudeSection([apex, sa, far, sb])
        if corner.polygons.isEmpty { return nil }

        // Cylinder tangent to both faces, on the inward bisector at distance
        // radius / sin(halfAngle) from the apex. cos(2·halfAngle) = nA·nB.
        let cosFull = max(-0.999, min(0.999, simd_dot(nA, nB)))
        let halfAngle = (Double.pi - acos(cosFull)) / 2
        let sinHalf = max(sin(halfAngle), 1e-3)
        var bis = tA + tB
        let bl = simd_length(bis)
        guard bl > 1e-6 else { return nil }
        bis /= bl
        let center = apex + bis * (radius / sinHalf)
        // Center the cylinder along the edge to match Euclid's centered
        // extrusion of the corner parallelogram (base sits depth/2 back).
        let cyl = cylinderAlongAxis(
            baseCenter: center - e * (depth / 2), axisDir: e, radius: radius, height: depth
        )
        corner = corner.subtracting(cyl).makeWatertight()
        return corner.polygons.isEmpty ? nil : corner
    }
}

// MARK: - Planar face push/pull (feature-graph replay)

nonisolated extension KernelOps {

    /// Push/pull a body's planar `face` by `distance` along the face normal — the
    /// pure-geometry core of `EditorViewModel.faceModifiedMesh`'s planar branch,
    /// extracted so the feature graph can replay it.
    ///
    /// `mesh` and `face` must live in the SAME coordinate space (the face's
    /// `origin`/`basisX`/`basisY`/`outline` were measured from `mesh`); unlike
    /// the live tool there is no body transform to bake in.
    ///
    /// - `distance > 0` (outward pull): unions a flush prism extruded from the
    ///   face outline (with holes) by `distance` along the normal.
    /// - `distance < 0` (inward push): truncates the body with the half-space at
    ///   the face plane moved `|distance|` inward, keeping the interior (−normal)
    ///   side. The half-space cut is coincident-wall safe — it leaves no hanging
    ///   walls the way a same-cross-section boolean subtract would.
    /// - `distance == 0`: returns `mesh` unchanged.
    static func pushPullPlanarFace(
        mesh: Euclid.Mesh,
        face: FaceTopology.PlanarFace,
        distance: Double
    ) -> Euclid.Mesh {
        guard distance != 0 else { return mesh }

        // Reconstruct the sketch plane + profile the live face push/pull builds
        // from the picked planar face.
        let plane = SketchPlane(
            origin: face.origin, xAxis: face.basisX, yAxis: face.basisY
        )
        let profile = Profile(
            loop: face.outline, kind: .polygonal, sourceEntityIDs: []
        )
        let holes = face.holes.map {
            Profile(loop: $0, kind: .polygonal, sourceEntityIDs: [])
        }
        // plane.normal == basisX × basisY == the face normal (mirrors the
        // viewmodel, which reads context.plane.normal).
        let n = plane.normal

        if distance < 0 {
            // Move the face plane into the body; keep the interior (−n) side.
            let cutOrigin = plane.origin + n * distance
            let cutPlane = SketchPlane(
                origin: cutOrigin, xAxis: plane.xAxis, yAxis: plane.yAxis
            )
            return SplitKit.split(mesh: mesh, byPlane: cutPlane).other
        } else {
            let prism = KernelOps.extrude(
                profile: profile, holes: holes, in: plane, distance: distance
            )
            guard !prism.polygons.isEmpty else { return mesh }
            return mesh.union(prism).makeWatertight()
        }
    }
}
