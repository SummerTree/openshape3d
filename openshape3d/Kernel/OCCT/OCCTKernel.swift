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

/// Owns an OCCT solid handle (`TopoDS_Shape`), world-space. Freed when the
/// handle is released.
///
/// `@unchecked Sendable` — CAVEAT (2026-08-25 review, S1): the shape is NOT
/// deeply immutable. `renderMesh(from:)` runs `BRepMesh_IncrementalMesh`,
/// which stores triangulations into the faces' shared `TShape`, and handles
/// are aliased (undo snapshots retain the same instance; identity transforms
/// return `self`). This is only safe because every OCCT call currently runs
/// on the MainActor. Before moving any OCCT work off-main, all access to
/// handles MUST be serialized on one executor — do not rely on this
/// annotation for actual thread safety.
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
    /// A true circle, in plane-local coordinates.
    /// An exact conic boundary: a circle or an ellipse.
    ///
    /// One type rather than two, because to every caller these are the same
    /// thing — "this whole loop is a curve OCCT can build exactly, so ignore
    /// the polyline". A circle is just the case where the semi-axes are equal,
    /// and the bridge picks `gp_Circ` or `gp_Elips` from that.
    nonisolated struct ConicSpec: Sendable, Equatable {
        var center: SIMD2<Double>
        /// Semi-axes BEFORE `rotation`; either may be the larger one.
        var radiusX: Double
        var radiusY: Double
        var rotation: Double

        init(center: SIMD2<Double>, radiusX: Double, radiusY: Double, rotation: Double) {
            self.center = center
            self.radiusX = radiusX
            self.radiusY = radiusY
            self.rotation = rotation
        }

        init(center: SIMD2<Double>, radius: Double) {
            self.init(center: center, radiusX: radius, radiusY: radius, rotation: 0)
        }

        /// The conic a profile names, if it names one.
        init?(_ kind: Profile.Kind) {
            switch kind {
            case .polygonal:
                return nil
            case let .circle(center, radius):
                self.init(center: center, radius: radius)
            case let .ellipse(center, radiusX, radiusY, rotation):
                self.init(center: center, radiusX: radiusX,
                          radiusY: radiusY, rotation: rotation)
            }
        }
    }

    /// One inner boundary of an extrude profile.
    ///
    /// `circle` present = an analytic cylindrical wall; absent = the polyline
    /// it was drawn as. Carrying this per HOLE (rather than the single
    /// outer-loop `isCircle` flag the port shipped with) is what stops a plate
    /// with a Ø8 hole coming back with a 64-sided bore.
    nonisolated struct ExtrudeHole: Sendable {
        var loop: [SIMD2<Double>]
        /// The whole boundary as one exact curve, when it is one.
        var conic: ConicSpec?
        /// Exact boundary when the hole is neither a conic nor all-straight —
        /// a slot punched through a plate. See `Profile.Segment`.
        var segments: [Profile.Segment]

        init(loop: [SIMD2<Double>], conic: ConicSpec? = nil,
             segments: [Profile.Segment] = []) {
            self.loop = loop
            self.conic = conic
            self.segments = segments
        }
    }

    static func extrudeShape(
        outerLoop: [SIMD2<Double>], outerConic: ConicSpec? = nil,
        holes: [ExtrudeHole], zMin: Double, zMax: Double,
        origin: SIMD3<Double>, xAxis: SIMD3<Double>,
        yAxis: SIMD3<Double>, normal: SIMD3<Double>,
        outerSegments: [Profile.Segment] = []
    ) -> BRepHandle? {
        let basis = OCCTPlaneBasis(
            originX: origin.x, originY: origin.y, originZ: origin.z,
            xAxisX: xAxis.x, xAxisY: xAxis.y, xAxisZ: xAxis.z,
            yAxisX: yAxis.x, yAxisY: yAxis.y, yAxisZ: yAxis.z,
            normalX: normal.x, normalY: normal.y, normalZ: normal.z)
        let conicData = packConics(holes.map(\.conic))
        guard let shape = OCCTBridge.extrudedShape(
            withOuterLoop: packLoop(outerLoop),
            outerConic: packConics([outerConic]),
            holes: holes.map { packLoop($0.loop) },
            holeConics: conicData,
            outerSegments: packSegments(outerSegments),
            holeSegments: holes.map { packSegments($0.segments) },
            zMin: zMin, zMax: zMax, basis: basis) else { return nil }
        return BRepHandle(shape)
    }

    /// Plain polyline boundaries, for callers with no analytic information
    /// about their holes — `ReplaceFaceKit`'s swept prism takes its
    /// boundaries from a tessellated `PlanarFace`, which has no idea which of
    /// them were circles. Deliberately a NAMED helper rather than an overload
    /// of `extrudeShape`: an overload makes the common `holes: []` ambiguous.
    static func polylineHoles(_ loops: [[SIMD2<Double>]]) -> [ExtrudeHole] {
        loops.map { ExtrudeHole(loop: $0) }
    }

    /// The analytic solid for a whole extrude: the outer profile plus any
    /// EXTRA profiles fused into it.
    ///
    /// Multi-profile extrudes used to skip the B-rep path entirely (the call
    /// sites read `extras.isEmpty`), so selecting two regions and pulling them
    /// produced a mesh-only body — no analytic fillets, no exact STEP, and a
    /// silent degrade the moment a second region joined the selection. A union
    /// of prisms is just a union of prisms; there was no reason for it to be a
    /// cliff.
    ///
    /// Nil when any piece fails to build, so callers fall back to Euclid as a
    /// whole rather than shipping a partial solid.
    static func extrudeSolid(
        outer: Profile, holes: [Profile],
        extras: [(profile: Profile, holes: [Profile])],
        zMin: Double, zMax: Double,
        origin: SIMD3<Double>, xAxis: SIMD3<Double>,
        yAxis: SIMD3<Double>, normal: SIMD3<Double>
    ) -> BRepHandle? {
        func prism(_ profile: Profile, _ profileHoles: [Profile]) -> BRepHandle? {
            extrudeShape(
                outerLoop: profile.loop, outerConic: ConicSpec(profile.kind),
                holes: extrudeHoles(profileHoles), zMin: zMin, zMax: zMax,
                origin: origin, xAxis: xAxis, yAxis: yAxis, normal: normal,
                outerSegments: profile.segments)
        }
        guard var solid = prism(outer, holes) else { return nil }
        for extra in extras {
            guard let piece = prism(extra.profile, extra.holes),
                  let fused = boolean(solid, piece, op: 0) else { return nil }
            // Touching regions meet on shared faces; without this the fuse
            // leaves both of them plus a seam edge (same trap Replace Face
            // hit — see `unified`).
            solid = unified(fused)
        }
        return solid
    }

    /// One profile's packed arguments, shared by every profile-driven op so
    /// they cannot drift apart. Extrude, revolve, sweep and loft must all start
    /// from the SAME wires — a circle that stays round when extruded and goes
    /// faceted when revolved is exactly the inconsistency this avoids.
    private static func packedProfile(_ profile: Profile, holes: [Profile])
        -> (loop: Data, conic: Data, holeLoops: [Data], holeConics: Data,
            segments: Data, holeSegments: [Data]) {
        let extrudeHoles = extrudeHoles(holes)
        return (packLoop(profile.loop),
                packConics([ConicSpec(profile.kind)]),
                extrudeHoles.map { packLoop($0.loop) },
                packConics(extrudeHoles.map(\.conic)),
                packSegments(profile.segments),
                extrudeHoles.map { packSegments($0.segments) })
    }

    private static func planeBasis(_ plane: SketchPlane) -> OCCTPlaneBasis {
        let n = simd_normalize(simd_cross(plane.xAxis, plane.yAxis))
        return OCCTPlaneBasis(
            originX: plane.origin.x, originY: plane.origin.y, originZ: plane.origin.z,
            xAxisX: plane.xAxis.x, xAxisY: plane.xAxis.y, xAxisZ: plane.xAxis.z,
            yAxisX: plane.yAxis.x, yAxisY: plane.yAxis.y, yAxisZ: plane.yAxis.z,
            normalX: n.x, normalY: n.y, normalZ: n.z)
    }

    /// Revolve a profile about a world-space axis. Nil when OCCT refuses —
    /// most often a profile that crosses the axis, which is a real modelling
    /// error and which the mesh path reports as empty geometry.
    ///
    /// `angleRadians` is named for its units on purpose: the feature graph
    /// stores revolve angles in DEGREES (`KernelOps.revolve` ends with
    /// `intersectWithWedge(solid, degrees:)`), while OCCT wants radians. Passing
    /// 360 straight through would not fail loudly — a 360-radian revolve still
    /// closes into a full solid — so the mistake would have looked correct.
    static func revolveSolid(outer: Profile, holes: [Profile], plane: SketchPlane,
                             axisOrigin: SIMD3<Double>, axisDirection: SIMD3<Double>,
                             angleRadians: Double) -> BRepHandle? {
        let p = packedProfile(outer, holes: holes)
        var axis = [axisOrigin.x, axisOrigin.y, axisOrigin.z,
                    axisDirection.x, axisDirection.y, axisDirection.z]
        let axisData = axis.withUnsafeBytes { Data($0) }
        return OCCTBridge.revolvedShape(
            withOuterLoop: p.loop, outerConic: p.conic, holes: p.holeLoops,
            holeConics: p.holeConics, outerSegments: p.segments,
            holeSegments: p.holeSegments, basis: planeBasis(plane),
            axis: axisData, angle: angleRadians).map(BRepHandle.init)
    }

    /// Loft through ordered sections. Holes are dropped: OCCT's ThruSections
    /// takes ONE wire per section, so a section with inner loops cannot be
    /// expressed here — callers must fall back to the mesh for those.
    static func loftSolid(sections: [(profile: Profile, plane: SketchPlane)]) -> BRepHandle? {
        guard sections.count >= 2 else { return nil }
        var loops: [Data] = [], conics: [Data] = [], segments: [Data] = []
        var bases: [OCCTPlaneBasis] = []
        for section in sections {
            let p = packedProfile(section.profile, holes: [])
            loops.append(p.loop)
            conics.append(p.conic)
            segments.append(p.segments)
            bases.append(planeBasis(section.plane))
        }
        return OCCTBridge.loftedShape(
            withOuterLoops: loops, outerConics: conics,
            outerSegments: segments, bases: bases).map(BRepHandle.init)
    }

    /// Sweep a profile along a world-space polyline spine.
    static func sweepSolid(outer: Profile, holes: [Profile], plane: SketchPlane,
                           spine: [SIMD3<Double>]) -> BRepHandle? {
        guard spine.count >= 2 else { return nil }
        let p = packedProfile(outer, holes: holes)
        var flat = [Double](); flat.reserveCapacity(spine.count * 3)
        for point in spine { flat.append(point.x); flat.append(point.y); flat.append(point.z) }
        let spineData = flat.withUnsafeBytes { Data($0) }
        return OCCTBridge.sweptShape(
            withOuterLoop: p.loop, outerConic: p.conic, holes: p.holeLoops,
            holeConics: p.holeConics, outerSegments: p.segments,
            holeSegments: p.holeSegments, basis: planeBasis(plane),
            spine: spineData).map(BRepHandle.init)
    }

    /// Turn resolved profile holes into extrude boundaries, keeping the ones
    /// that are circles analytic. One place, because both the new-body and the
    /// boolean-into-target paths need it and they must not disagree.
    static func extrudeHoles(_ profiles: [Profile]) -> [ExtrudeHole] {
        profiles.map { profile in
            if let conic = ConicSpec(profile.kind) {
                return ExtrudeHole(loop: profile.loop, conic: conic)
            }
            return ExtrudeHole(loop: profile.loop, segments: profile.segments)
        }
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

    /// Reflect a solid in the plane through `origin` with `normal`.
    ///
    /// Deliberately not routed through `transformed(_:by:)`: `Transform3D` is
    /// translation + rotation + a single uniform scale and cannot represent a
    /// plane reflection at all. (A negative uniform scale is a point
    /// reflection — a different transform, and not what Mirror means.)
    static func mirrored(_ handle: BRepHandle,
                         origin: SIMD3<Double>, normal: SIMD3<Double>) -> BRepHandle? {
        OCCTBridge.mirroredShape(
            handle.shape,
            originX: origin.x, originY: origin.y, originZ: origin.z,
            normalX: normal.x, normalY: normal.y, normalZ: normal.z
        ).map(BRepHandle.init)
    }

    /// OCCT boolean of two solids. op: 0 = union, 1 = subtract (a − b), 2 = intersect.
    /// Map a `BooleanKind` to `OCCTBridge`'s op code (0 union, 1 subtract,
    /// 2 intersect).
    static func booleanOp(_ kind: BooleanKind) -> Int {
        switch kind {
        case .union: 0
        case .subtract: 1
        case .intersect: 2
        }
    }

    /// Compose two bodies' analytic solids with an OCCT boolean, in world
    /// space (each body's transform applied first, mirroring what
    /// `KernelOps.boolean` does for the Euclid meshes). Nil when either body
    /// is mesh-only or OCCT fails — the caller keeps the Euclid result.
    /// Shared by feature replay AND the live boolean tool, so both paths make
    /// the same kernel decision (2026-08-25 review, C4).
    static func composedBoolean(
        _ kind: BooleanKind, target: Body, tool: Body
    ) -> BRepHandle? {
        guard useOCCTAsSourceOfTruth,
              let a0 = target.brep, let b0 = tool.brep,
              let a = transformed(a0, by: target.transform),
              let b = transformed(b0, by: tool.transform)
        else { return nil }
        return boolean(a, b, op: booleanOp(kind))
    }

    /// Merge faces sharing one underlying surface (and the seams between
    /// them). A fuse against a coplanar face otherwise leaves BOTH faces and
    /// the seam edge — right shape, wrong topology, and the extra edges are
    /// selectable and blendable. Returns the input unchanged when OCCT
    /// declines, since the un-unified solid is still valid.
    static func unified(_ handle: BRepHandle) -> BRepHandle {
        OCCTBridge.unifiedShape(handle.shape).map(BRepHandle.init) ?? handle
    }

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

    /// 7 doubles per edge — `isArc, x1, y1, x2, y2, midX, midY` — matching
    /// `SegWire` in the bridge. Empty in, empty out: an all-straight loop has
    /// nothing to say here that its polyline does not already say exactly.
    /// 5 doubles per entry — `cx, cy, rx, ry, rotation` — parallel to the
    /// loops they describe. A non-positive `rx` means "no conic here, use the
    /// polyline", which is how one flat array carries the absent case too.
    private static func packConics(_ conics: [ConicSpec?]) -> Data {
        var flat = [Double](); flat.reserveCapacity(conics.count * 5)
        for conic in conics {
            flat.append(conic?.center.x ?? 0)
            flat.append(conic?.center.y ?? 0)
            flat.append(conic?.radiusX ?? 0)
            flat.append(conic?.radiusY ?? 0)
            flat.append(conic?.rotation ?? 0)
        }
        return flat.withUnsafeBytes { Data($0) }
    }

    private static func packSegments(_ segments: [Profile.Segment]) -> Data {
        guard !segments.isEmpty else { return Data() }
        var flat = [Double](); flat.reserveCapacity(segments.count * 7)
        for s in segments {
            flat.append(s.mid == nil ? 0 : 1)
            flat.append(s.start.x); flat.append(s.start.y)
            flat.append(s.end.x); flat.append(s.end.y)
            flat.append(s.mid?.x ?? 0); flat.append(s.mid?.y ?? 0)
        }
        return flat.withUnsafeBytes { Data($0) }
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
