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

    /// Feature flag for the B-rep render path. When true, a circle extrude is
    /// displayed with OCCT's analytic-cylinder tessellation (smooth normals,
    /// truly round) instead of the Euclid 48-gon prism. Euclid still owns CSG.
    static let renderCircleExtrudesWithOCCT = true

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

    /// OCCT boolean of two solids. op: 0 = union, 1 = subtract (a − b), 2 = intersect.
    static func boolean(_ a: BRepHandle, _ b: BRepHandle, op: Int) -> BRepHandle? {
        OCCTBridge.boolean(of: a.shape, with: b.shape, op: op).map(BRepHandle.init)
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
