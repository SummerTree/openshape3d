//
//  ShellKit.swift
//  openshape3d
//
//  Shell (spec §4.4), mesh-kernel version: hollow a solid to a uniform wall
//  thickness, optionally opening selected planar faces. The inner cavity is
//  the body with every vertex offset inward so each adjacent face PLANE moves
//  by the wall thickness (least-squares over the vertex's distinct face
//  normals — exact for prismatic solids, mitred elsewhere). Each open face is
//  then cut with a prism over the face outline inset by the thickness, so the
//  rim around the opening keeps full wall width.
//

import Foundation
import simd
import Euclid

nonisolated extension KernelOps {

    /// Hollow `mesh` to a wall of `thickness`, opening `openFaces` (empty =
    /// fully enclosed hollow, Shapr3D's whole-body Shell). `mesh` and the
    /// faces share one (body-local) coordinate space. Returns an EMPTY mesh
    /// when the request is degenerate or the thickness eats the body — the
    /// caller treats empty as "invalid thickness" (red-arrow validity).
    static func shell(
        mesh: Euclid.Mesh,
        thickness: Double,
        openFaces: [PlanarFace] = []
    ) -> Euclid.Mesh {
        guard thickness > 1e-6, !mesh.polygons.isEmpty else { return Euclid.Mesh([]) }

        guard let inner = offsetInward(mesh: mesh, by: thickness) else {
            return Euclid.Mesh([])
        }
        // The cavity must be a real solid strictly smaller than the body;
        // a collapsed/inverted cavity means the wall ate the body.
        let innerVolume = signedVolume(inner)
        guard innerVolume > 1e-9, innerVolume < signedVolume(mesh) else {
            return Euclid.Mesh([])
        }

        var result = mesh.subtracting(inner).makeWatertight()

        for face in openFaces {
            guard let tool = openingPrism(for: face, thickness: thickness) else {
                // The inset outline collapsed — the face is too small to keep
                // a full-width rim, so the whole shell is invalid (Shapr3D
                // refuses rather than thinning the rim).
                return Euclid.Mesh([])
            }
            result = result.subtracting(tool).makeWatertight()
        }
        return result
    }

    // MARK: - Inner cavity (vertex offset)

    /// The body with every welded vertex moved inward so each adjacent face
    /// plane shifts by `distance`: solve `nᵢ · d = -distance` over the
    /// vertex's distinct polygon normals in least squares. One normal gives
    /// `d = -distance·n` (face interior), two the mitred edge offset, three+
    /// the corner intersection. Nil when the offset degenerates.
    private static func offsetInward(
        mesh: Euclid.Mesh, by distance: Double
    ) -> Euclid.Mesh? {
        let quantum = 1e-6

        struct Key: Hashable {
            let x, y, z: Int64
            init(_ p: Vector, _ inv: Double) {
                x = Int64((p.x * inv).rounded())
                y = Int64((p.y * inv).rounded())
                z = Int64((p.z * inv).rounded())
            }
        }
        let inv = 1 / quantum

        // Distinct adjacent plane normals per welded vertex.
        var normals = [Key: [SIMD3<Double>]]()
        for polygon in mesh.polygons {
            let pn = polygon.plane.normal
            let n = SIMD3(pn.x, pn.y, pn.z)
            for vertex in polygon.vertices {
                let key = Key(vertex.position, inv)
                var list = normals[key] ?? []
                if !list.contains(where: { simd_dot($0, n) > 0.9995 }) {
                    list.append(n)
                    normals[key] = list
                }
            }
        }

        // Per-vertex displacement: d = (Σ nᵢnᵢᵀ + εI)⁻¹ · Σ nᵢ·(-t).
        var displacement = [Key: SIMD3<Double>]()
        let maxShift = distance * 8   // mitre blow-up guard (near-parallel planes)
        for (key, list) in normals {
            var a = simd_double3x3(diagonal: SIMD3(repeating: 1e-9))
            var b = SIMD3<Double>()
            for n in list {
                a += simd_double3x3(columns: (n * n.x, n * n.y, n * n.z))
                b += n * -distance
            }
            var d = a.inverse * b
            let len = simd_length(d)
            if len > maxShift { d *= maxShift / len }
            displacement[key] = d
        }

        var polygons = [Euclid.Polygon]()
        polygons.reserveCapacity(mesh.polygons.count)
        for polygon in mesh.polygons {
            let vertices = polygon.vertices.map { vertex -> Euclid.Vertex in
                let d = displacement[Key(vertex.position, inv)] ?? .init()
                let p = vertex.position
                return Euclid.Vertex(Vector(p.x + d.x, p.y + d.y, p.z + d.z), vertex.normal)
            }
            // Offsetting can collapse a polygon (thin features); skip those —
            // makeWatertight heals small gaps, the volume check catches big ones.
            if let moved = Euclid.Polygon(vertices) {
                polygons.append(moved)
            }
        }
        guard !polygons.isEmpty else { return nil }
        return Euclid.Mesh(polygons).makeWatertight()
    }

    /// Signed volume via the divergence theorem (positive for an outward-
    /// oriented closed mesh).
    private static func signedVolume(_ mesh: Euclid.Mesh) -> Double {
        var total = 0.0
        for polygon in mesh.polygons {
            let vertices = polygon.vertices
            guard vertices.count >= 3 else { continue }
            let pa = vertices[0].position
            let a = SIMD3(pa.x, pa.y, pa.z)
            for i in 1..<(vertices.count - 1) {
                let pb = vertices[i].position
                let pc = vertices[i + 1].position
                let b = SIMD3(pb.x, pb.y, pb.z)
                let c = SIMD3(pc.x, pc.y, pc.z)
                total += simd_dot(a, simd_cross(b, c)) / 6
            }
        }
        return total
    }

    // MARK: - Face openings

    /// The cut prism for one open face: the outline inset by `thickness`
    /// (holes grown by it), extruded from just outside the face down past the
    /// cavity ceiling so opening and cavity merge. Nil when the inset outline
    /// collapses.
    private static func openingPrism(
        for face: PlanarFace, thickness: Double
    ) -> Euclid.Mesh? {
        guard let outline = offsetLoop(face.outline, by: -thickness),
              abs(Profile.signedArea(outline)) > 1e-9
        else { return nil }

        // Grown holes that swallow the outline kill the opening too.
        var holes = [[SIMD2<Double>]]()
        for hole in face.holes {
            if let grown = offsetLoop(hole, by: thickness) {
                holes.append(grown)
            }
        }

        let n = face.normal
        let normal = SIMD3(Double(n.x), Double(n.y), Double(n.z))
        let pad = thickness * 0.5 + 0.001
        let plane = SketchPlane(
            origin: face.origin - normal * (thickness + pad),
            xAxis: face.basisX,
            yAxis: face.basisY
        )
        let profile = Profile(loop: outline, kind: .polygonal, sourceEntityIDs: [])
        let holeProfiles = holes.map {
            Profile(loop: $0, kind: .polygonal, sourceEntityIDs: [])
        }
        let prism = KernelOps.extrude(
            profile: profile, holes: holeProfiles, in: plane,
            distance: thickness + 2 * pad
        )
        return prism.polygons.isEmpty ? nil : prism
    }

    /// Offset a simple closed loop: positive `amount` GROWS the enclosed
    /// region, negative shrinks it. Mitred joins; vertices whose adjacent
    /// offset edges reversed direction (collapsed through the far wall) drop
    /// out. Nil when fewer than 3 vertices survive or the loop inverted.
    static func offsetLoop(
        _ loop: [SIMD2<Double>], by amount: Double
    ) -> [SIMD2<Double>]? {
        guard loop.count >= 3 else { return nil }
        // Normalize to CCW so "outward" is a fixed side.
        let ccw = Profile.signedArea(loop) >= 0 ? loop : Array(loop.reversed())
        let n = ccw.count

        // Offset line per edge: point + outward normal · amount.
        // CCW travel keeps the interior on the LEFT, so outward = right
        // normal = (dy, -dx).
        var offsetPoints = [SIMD2<Double>]()
        offsetPoints.reserveCapacity(n)
        for i in 0..<n {
            let prev = ccw[(i + n - 1) % n]
            let point = ccw[i]
            let next = ccw[(i + 1) % n]
            var dirIn = point - prev
            var dirOut = next - point
            let lenIn = simd_length(dirIn), lenOut = simd_length(dirOut)
            guard lenIn > 1e-12, lenOut > 1e-12 else { continue }
            dirIn /= lenIn; dirOut /= lenOut
            let normalIn = SIMD2(dirIn.y, -dirIn.x)
            let normalOut = SIMD2(dirOut.y, -dirOut.x)
            // Mitre: the offset vertex w satisfies w·nIn = w·nOut = amount
            // (signed distance `amount` from BOTH adjacent edges). 2×2 solve;
            // near-parallel edges (det → 0) fall back to the shared normal.
            let det = normalIn.x * normalOut.y - normalIn.y * normalOut.x
            if abs(det) < 1e-9 {
                offsetPoints.append(point + normalOut * amount)
            } else {
                let w = SIMD2(
                    amount * (normalOut.y - normalIn.y) / det,
                    amount * (normalIn.x - normalOut.x) / det
                )
                offsetPoints.append(point + w)
            }
        }

        // Drop vertices whose adjacent edge FLIPPED direction relative to the
        // source loop (they collapsed through the opposite wall).
        guard offsetPoints.count == n else { return nil }
        var result = [SIMD2<Double>]()
        for i in 0..<n {
            let a = offsetPoints[i]
            let b = offsetPoints[(i + 1) % n]
            let sa = ccw[i]
            let sb = ccw[(i + 1) % n]
            if simd_dot(b - a, sb - sa) > 0 {
                result.append(a)
            }
        }
        guard result.count >= 3, Profile.signedArea(result) > 1e-12 else { return nil }
        return result
    }
}
