//
//  OCCTKernel.swift
//  openshape3d — OCCT B-rep port, Milestone 1
//
//  Thin Swift-native wrapper over the Obj-C++ `OCCTBridge` facade. Everything
//  in the app (and `@testable` tests) talks to OCCT through this type, so the
//  Obj-C surface never leaks into feature/kernel code. As real ops are ported
//  (extrude, boolean, …) they land here, routed behind the `OS3D_BREP` flag
//  from `KernelOps`. For now it exposes the Milestone-0 spike surface so the
//  wiring is verifiable in-suite.
//

import Foundation
import simd

/// Owns an OCCT solid handle (`TopoDS_Shape`), world-space. The underlying B-rep
/// is immutable after creation, so this is safe to share across the kernel/
/// render boundary — hence `@unchecked Sendable` (the audited wrapper the design
/// doc calls for). Freed when the handle is released.
nonisolated final class BRepHandle: @unchecked Sendable {
    let shape: OCCTShape
    init(_ shape: OCCTShape) { self.shape = shape }
}

/// Namespace for OCCT-backed geometry. `nonisolated` — kernel work runs off the
/// main actor, same contract as `KernelOps`.
nonisolated enum OCCTKernel {

    /// Tessellation quality for B-rep render meshes. Angular deflection (radians)
    /// governs facets-around-a-curve → roundness; it's size-independent.
    static let renderAngularDeflection = 0.08
    static let renderLinearDeflection = 0.1

    /// Master switch for the B-rep path. When true, solids that OCCT can build
    /// (extrudes, primitives, and booleans between them) carry an analytic
    /// `Body.brep` and derive BOTH their render and CSG meshes from it. Flip to
    /// false to fall back to the pure-Euclid kernel everywhere.
    static let useOCCTAsSourceOfTruth = true

    /// The linked OCCT version (proves the xcframework is present + linked).
    static var version: String { OCCTBridge.occtVersion() }

    /// A smooth, world-space render mesh for an extruded circle. The cylinder is
    /// built analytically in plane-local space (circle `center`/`radius`, spanning
    /// plane-local z ∈ [`zMin`,`zMax`]) then mapped to world through the sketch
    /// plane's orthonormal basis — matching where `KernelOps.extrude` places the
    /// Euclid solid, so geometry and display coincide.
    static func cylinderRenderMesh(
        center: SIMD2<Double>, radius: Double, zMin: Double, zMax: Double,
        origin: SIMD3<Double>, xAxis: SIMD3<Double>,
        yAxis: SIMD3<Double>, normal: SIMD3<Double>
    ) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        // ~0.08 rad angular deflection ≈ 80 facets around the circle (visually
        // round); linear deflection bounds chord error to a fraction of the size.
        let ang = 0.08
        let lin = max(radius, zMax - zMin) * 0.002
        let mesh = OCCTBridge.cylinderRenderMesh(
            withCenterX: center.x, centerY: center.y, radius: radius,
            zMin: zMin, zMax: zMax, angularDeflection: ang, linearDeflection: lin)

        let localPos = mesh.positions.floatArray()
        let localNrm = mesh.normals.floatArray()
        let indices = mesh.indices.uint32Array()

        let ox = SIMD3<Float>(Float(xAxis.x), Float(xAxis.y), Float(xAxis.z))
        let oy = SIMD3<Float>(Float(yAxis.x), Float(yAxis.y), Float(yAxis.z))
        let oz = SIMD3<Float>(Float(normal.x), Float(normal.y), Float(normal.z))
        let org = SIMD3<Float>(Float(origin.x), Float(origin.y), Float(origin.z))

        // Rotate a plane-local vector into world by the orthonormal basis.
        func rotate(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let a: SIMD3<Float> = ox * p.x
            let b: SIMD3<Float> = oy * p.y
            let c: SIMD3<Float> = oz * p.z
            return a + b + c
        }

        let n = mesh.vertexCount
        var positions = [SIMD3<Float>](); positions.reserveCapacity(n)
        var normals = [SIMD3<Float>](); normals.reserveCapacity(n)
        for v in 0..<n {
            let lp = SIMD3<Float>(localPos[3*v], localPos[3*v+1], localPos[3*v+2])
            let ln = SIMD3<Float>(localNrm[3*v], localNrm[3*v+1], localNrm[3*v+2])
            positions.append(org + rotate(lp))
            normals.append(simd_normalize(rotate(ln)))
        }
        return (positions, normals, indices)
    }

    /// Plane-local z-span an extrude occupies, matching `KernelOps.extrude`'s
    /// placement: one-sided sits on the plane (`[min(0,d), max(0,d)]`), symmetric
    /// straddles it (`[-|d|, +|d|]`).
    static func extrudeZRange(distance d: Double, symmetric: Bool) -> (zMin: Double, zMax: Double) {
        symmetric ? (-abs(d), abs(d)) : (min(0, d), max(0, d))
    }

    // MARK: - B-rep source of truth (extrude → boolean → render)

    /// Build a world-space OCCT solid for an extruded profile. `outerLoop` is the
    /// plane-local boundary; when `isCircle` an analytic circle is used (true
    /// cylinder). `holes` are polygonal inner boundaries. Returns nil on failure.
    static func extrudeShape(
        outerLoop: [SIMD2<Double>], isCircle: Bool,
        circleCenter: SIMD2<Double>, circleRadius: Double,
        holes: [[SIMD2<Double>]], zMin: Double, zMax: Double,
        origin: SIMD3<Double>, xAxis: SIMD3<Double>,
        yAxis: SIMD3<Double>, normal: SIMD3<Double>
    ) -> BRepHandle? {
        let basis = OCCTPlaneBasis(
            originX: origin.x, originY: origin.y, originZ: origin.z,
            xAxisX: xAxis.x, xAxisY: xAxis.y, xAxisZ: xAxis.z,
            yAxisX: yAxis.x, yAxisY: yAxis.y, yAxisZ: yAxis.z,
            normalX: normal.x, normalY: normal.y, normalZ: normal.z)
        guard let shape = OCCTBridge.extrudedShape(
            withOuterLoop: packLoop(outerLoop), isCircle: isCircle,
            circleCenterX: circleCenter.x, circleCenterY: circleCenter.y,
            circleRadius: circleRadius, holes: holes.map(packLoop),
            zMin: zMin, zMax: zMax, basis: basis) else { return nil }
        return BRepHandle(shape)
    }

    /// Build the analytic OCCT solid for a primitive, matching Euclid's placement
    /// conventions so B-rep and CSG mesh coincide. `placement` is baked in.
    static func primitiveShape(_ spec: PrimitiveSpec, placement: Transform3D) -> BRepHandle? {
        let kind: Int, a: Double, b: Double, c: Double
        switch spec {
        case let .box(width, depth, height): kind = 0; a = width; b = depth; c = height
        case let .cylinder(radius, height):  kind = 1; a = radius; b = height; c = 0
        case let .sphere(radius):            kind = 2; a = radius; b = 0; c = 0
        }
        var data: Data?
        if placement != .identity {
            let m = placement.matrix  // simd is column-major: m[col][row]
            var flat = [Double]()
            for r in 0..<3 { for col in 0..<4 { flat.append(m[col][r]) } }
            data = flat.withUnsafeBytes { Data($0) }
        }
        return OCCTBridge.primitiveShape(ofKind: kind, a: a, b: b, c: c, transform: data)
            .map(BRepHandle.init)
    }

    /// True when a primitive has curved faces worth re-rendering through OCCT.
    /// A box looks identical either way, so it keeps the Euclid render mesh.
    static func hasCurvedFaces(_ spec: PrimitiveSpec) -> Bool {
        switch spec {
        case .box: return false
        case .cylinder, .sphere: return true
        }
    }

    /// Bake a `Body.transform` into a solid. A body's `brep` lives in the SAME
    /// space as its `render` mesh (body-local), so any op combining two bodies
    /// must place both into a common space first — exactly what
    /// `KernelOps.boolean` does for the Euclid meshes. Identity is a no-op.
    static func transformed(_ handle: BRepHandle, by transform: Transform3D) -> BRepHandle? {
        guard transform != .identity else { return handle }
        let m = transform.matrix  // simd is column-major: m[col][row]
        var flat = [Double]()
        for r in 0..<3 { for col in 0..<4 { flat.append(m[col][r]) } }
        let data = flat.withUnsafeBytes { Data($0) }
        return OCCTBridge.transformedShape(handle.shape, matrix: data).map(BRepHandle.init)
    }

    /// OCCT boolean of two solids. op: 0 = union, 1 = subtract (a − b), 2 = intersect.
    static func boolean(_ a: BRepHandle, _ b: BRepHandle, op: Int) -> BRepHandle? {
        OCCTBridge.boolean(of: a.shape, with: b.shape, op: op).map(BRepHandle.init)
    }

    /// Remove the faces nearest `points` and heal the solid (spec §4.16 Delete
    /// Face). Nil when nothing matched or OCCT couldn't close the result — the
    /// caller should surface a recoverable failure rather than mutate the body.
    static func removingFaces(_ handle: BRepHandle, at points: [SIMD3<Double>],
                              tolerance: Double) -> BRepHandle? {
        guard !points.isEmpty else { return nil }
        var flat = [Double](); flat.reserveCapacity(points.count * 3)
        for p in points { flat.append(p.x); flat.append(p.y); flat.append(p.z) }
        let data = flat.withUnsafeBytes { Data($0) }
        return OCCTBridge.defeaturedShape(handle.shape, atWorldPoints: data,
                                               tolerance: tolerance)
            .map(BRepHandle.init)
    }

    /// Analytic face-type histogram of a solid — how we assert that geometry
    /// stayed exact through an operation.
    static func faceTypeCounts(_ handle: BRepHandle)
        -> (planar: Int, cylindrical: Int, other: Int) {
        let c = OCCTBridge.faceTypeCounts(of: handle.shape)
        return (c.planar, c.cylindrical, c.other)
    }

    /// Round the analytic edges nearest `points` to `radius`. `points` are world
    /// positions on the edges to blend (mesh-edge midpoints from the picker);
    /// `tolerance` should scale with the body (a fraction of its bounding box),
    /// since a tessellated chord sits slightly inside the true arc.
    ///
    /// Returns nil when nothing matched or OCCT couldn't build the blend (e.g.
    /// the radius exceeds what the geometry allows) — callers fall back to the
    /// mesh blend rather than failing the user's action.
    static func fillet(_ handle: BRepHandle, at points: [SIMD3<Double>],
                       radius: Double, tolerance: Double) -> BRepHandle? {
        guard !points.isEmpty, radius > 0 else { return nil }
        var flat = [Double](); flat.reserveCapacity(points.count * 3)
        for p in points { flat.append(p.x); flat.append(p.y); flat.append(p.z) }
        let data = flat.withUnsafeBytes { Data($0) }
        return OCCTBridge.filletedShape(handle.shape, atWorldPoints: data,
                                        radius: radius, tolerance: tolerance)
            .map(BRepHandle.init)
    }

    /// Bevel the analytic edges nearest `points` by `distance` (spec §4.3
    /// chamfer). Same fallback contract as `fillet`.
    static func chamfer(_ handle: BRepHandle, at points: [SIMD3<Double>],
                        distance: Double, tolerance: Double) -> BRepHandle? {
        guard !points.isEmpty, distance > 0 else { return nil }
        return OCCTBridge.chamferedShape(handle.shape, atWorldPoints: pack(points),
                                         distance: distance, tolerance: tolerance)
            .map(BRepHandle.init)
    }

    /// Hollow a solid to `thickness`, opening the faces nearest `points` (spec
    /// §4.4 Shell). Empty `points` = fully-enclosed hollow. Correct on curved
    /// walls, unlike the mesh inset. Nil when the thickness is out of range.
    static func shell(_ handle: BRepHandle, openingAt points: [SIMD3<Double>],
                      thickness: Double, tolerance: Double) -> BRepHandle? {
        guard thickness > 0 else { return nil }
        return OCCTBridge.shelledShape(handle.shape, atWorldPoints: pack(points),
                                       thickness: thickness, tolerance: tolerance)
            .map(BRepHandle.init)
    }

    private static func pack(_ points: [SIMD3<Double>]) -> Data {
        var flat = [Double](); flat.reserveCapacity(points.count * 3)
        for p in points { flat.append(p.x); flat.append(p.y); flat.append(p.z) }
        return flat.withUnsafeBytes { Data($0) }
    }

    // MARK: - STEP interchange (spec §12.1 / §12.2)

    /// Write solids to a STEP AP214 file. Unlike STL/OBJ/3MF (which export
    /// triangles), STEP carries the EXACT B-rep, so analytic surfaces survive
    /// into other CAD. False if any transfer or the write fails.
    @discardableResult
    static func writeSTEP(_ handles: [BRepHandle], to url: URL) -> Bool {
        guard !handles.isEmpty else { return false }
        return OCCTBridge.writeSTEP(handles.map(\.shape), toPath: url.path)
    }

    /// Read every solid from a STEP file; empty when the file is unreadable or
    /// holds no solids, so the caller surfaces a recoverable import error.
    static func readSTEP(from url: URL) -> [BRepHandle] {
        OCCTBridge.readSTEP(fromPath: url.path).map(BRepHandle.init)
    }

    /// Serialize a solid so the analytic geometry survives a document reload.
    static func serialize(_ handle: BRepHandle) -> Data? {
        OCCTBridge.serializedShape(handle.shape)
    }

    /// Restore a solid from `serialize(_:)`. Nil on any failure — callers keep
    /// the persisted render mesh, so a bad/incompatible blob degrades to the
    /// pre-B-rep behaviour instead of breaking the document.
    static func deserialize(_ data: Data) -> BRepHandle? {
        OCCTBridge.shape(fromSerialized: data).map(BRepHandle.init)
    }

    /// Smooth world-space render mesh for a B-rep solid.
    static func renderMesh(from handle: BRepHandle)
        -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32]) {
        let mesh = OCCTBridge.renderMesh(
            from: handle.shape,
            angularDeflection: renderAngularDeflection,
            linearDeflection: renderLinearDeflection)
        let p = mesh.positions.floatArray()
        let nn = mesh.normals.floatArray()
        let indices = mesh.indices.uint32Array()
        let n = mesh.vertexCount
        var positions = [SIMD3<Float>](); positions.reserveCapacity(n)
        var normals = [SIMD3<Float>](); normals.reserveCapacity(n)
        for v in 0..<n {
            positions.append(SIMD3<Float>(p[3*v], p[3*v+1], p[3*v+2]))
            normals.append(SIMD3<Float>(nn[3*v], nn[3*v+1], nn[3*v+2]))
        }
        return (positions, normals, indices)
    }

    private static func packLoop(_ pts: [SIMD2<Double>]) -> Data {
        var flat = [Double](); flat.reserveCapacity(pts.count * 2)
        for p in pts { flat.append(p.x); flat.append(p.y) }
        return flat.withUnsafeBytes { Data($0) }
    }

    /// Tessellate a box; returns (triangleCount, exact volume).
    static func meshBox(size: Double) -> (triangles: Int, volume: Double) {
        let r = OCCTBridge.meshBox(withSize: size)
        return (r.triangleCount, r.volume)
    }

    /// Face-type histogram of an extruded circle. A true cylinder is
    /// (planar: 2 caps, cylindrical: 1 wall, other: 0) — the analytic-surface
    /// guarantee the Euclid mesh path can't give.
    static func extrudedCircleFaceCounts(radius: Double, height: Double)
        -> (planar: Int, cylindrical: Int, other: Int) {
        let c = OCCTBridge.extrudeCircleFaceCounts(withRadius: radius, height: height)
        return (c.planar, c.cylindrical, c.other)
    }
}

nonisolated extension Body {
    /// Adopt an OCCT solid as this body's SOURCE OF TRUTH.
    ///
    /// Both the render mesh and the CSG (`euclid`) mesh are derived from the same
    /// OCCT tessellation, so what you see and what booleans/blends actually cut
    /// can never disagree. Ops not yet ported to OCCT keep working — they just
    /// operate on the accurate tessellation of the analytic solid instead of a
    /// coarse 48-gon. Returns false (leaving the body untouched) if the solid
    /// fails to tessellate, so callers fall back to the Euclid path.
    @discardableResult
    mutating func adoptBRep(_ handle: BRepHandle) -> Bool {
        let m = OCCTKernel.renderMesh(from: handle)
        guard !m.positions.isEmpty, !m.indices.isEmpty else { return false }
        let mesh = RenderMesh(positions: m.positions, normals: m.normals, indices: m.indices)
        brep = handle
        render = mesh
        edges = FeatureEdgeExtractor.edges(from: mesh)
        euclid = EuclidBridge.euclidMesh(from: mesh)
        return true
    }
}

private extension Data {
    /// Reinterpret the packed bytes as tightly-packed `Float`s.
    func floatArray() -> [Float] {
        withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    /// Reinterpret the packed bytes as tightly-packed `UInt32`s.
    func uint32Array() -> [UInt32] {
        withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
    }
}
