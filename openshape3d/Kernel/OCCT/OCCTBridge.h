//
//  OCCTBridge.h
//  openshape3d — OCCT B-rep port, Milestone 0 (spike)
//
//  Narrow Obj-C facade over OpenCASCADE. Swift links ONLY against this header,
//  never OCCT's C++ headers — keeping the template-heavy kernel behind a stable
//  C/Obj-C surface (see docs/OCCT_BREP_PORT_DESIGN.md). This M0 surface exists
//  only to prove the toolchain: mesh a box, and confirm an extruded circle
//  becomes ONE analytic cylindrical face (the fix for the 48-gon-prism bug).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Result of tessellating a B-rep solid into a triangle mesh.
@interface OCCTMeshResult : NSObject
@property (nonatomic, readonly) NSInteger triangleCount;
@property (nonatomic, readonly) NSInteger vertexCount;
/// Exact solid volume from `BRepGProp` (mm³), independent of tessellation.
@property (nonatomic, readonly) double volume;
@end

/// Count of faces by analytic surface type on a solid.
@interface OCCTFaceTypeCounts : NSObject
@property (nonatomic, readonly) NSInteger planar;
@property (nonatomic, readonly) NSInteger cylindrical;
@property (nonatomic, readonly) NSInteger other;
@end

/// A tessellated triangle mesh with SMOOTH per-vertex normals evaluated from the
/// analytic surface (not per-facet). Buffers are tightly packed:
///   positions/normals: `vertexCount` × 3 floats (x,y,z), plane-local
///   indices:           `triangleCount` × 3 uint32
@interface OCCTRenderMesh : NSObject
@property (nonatomic, readonly) NSInteger vertexCount;
@property (nonatomic, readonly) NSInteger triangleCount;
@property (nonatomic, readonly) NSData *positions;  // float32 x 3 x vertexCount
@property (nonatomic, readonly) NSData *normals;    // float32 x 3 x vertexCount
@property (nonatomic, readonly) NSData *indices;    // uint32  x 3 x triangleCount
@end

/// Opaque handle to a world-space OCCT solid (`TopoDS_Shape`). Reference type;
/// the underlying B-rep is freed on dealloc and is immutable after creation, so
/// it is safe to pass across the kernel/render boundary.
@interface OCCTShape : NSObject
@end

/// Orthonormal sketch-plane basis: world = origin + xAxis·x + yAxis·y + normal·z.
@interface OCCTPlaneBasis : NSObject
- (instancetype)initWithOriginX:(double)ox originY:(double)oy originZ:(double)oz
                         xAxisX:(double)xx xAxisY:(double)xy xAxisZ:(double)xz
                         yAxisX:(double)yx yAxisY:(double)yy yAxisZ:(double)yz
                        normalX:(double)nx normalY:(double)ny normalZ:(double)nz;
@end

@interface OCCTBridge : NSObject

/// OCCT version string (e.g. "7.8.1") — proves the library linked and runs.
+ (NSString *)occtVersion;

/// Build a box of the given edge length, tessellate it, and report triangle
/// count + exact volume. Volume should be size³.
+ (OCCTMeshResult *)meshBoxWithSize:(double)size;

/// Build a circle (radius `r`) on the XY plane, make a planar face, and extrude
/// it `height` along +Z into a solid. Returns the analytic face-type histogram:
/// a true cylinder is 2 planar caps + 1 cylindrical side + 0 other — the direct
/// proof the kernel keeps circles analytic instead of faceting them.
+ (OCCTFaceTypeCounts *)extrudeCircleFaceCountsWithRadius:(double)r
                                                   height:(double)height;

/// Build a true cylinder (analytic B-rep) centered at (`cx`,`cy`) in plane-local
/// space, spanning z ∈ [`zMin`,`zMax`], and tessellate it with SMOOTH normals.
/// `angularDeflection` (radians) controls how many facets wrap the circle
/// (smaller = rounder); `linearDeflection` bounds chord error. Returns a mesh in
/// plane-local coordinates — the caller maps it to world with the sketch-plane
/// basis. This is what makes an extruded circle render round.
+ (OCCTRenderMesh *)cylinderRenderMeshWithCenterX:(double)cx
                                          centerY:(double)cy
                                           radius:(double)r
                                             zMin:(double)zMin
                                             zMax:(double)zMax
                                 angularDeflection:(double)angularDeflection
                                  linearDeflection:(double)linearDeflection;

// MARK: - B-rep source of truth (extrude → boolean → render)

/// Build a world-space extruded solid from a closed profile. `outerLoop` is
/// packed doubles (x,y pairs) in plane-local coords; if `isCircle` an ANALYTIC
/// circle edge is used instead (→ a true cylinder). `holes` are inner boundary
/// loops (packed doubles). The solid spans plane-local z ∈ [`zMin`,`zMax`], then
/// is mapped to world by `basis`. Returns nil if the profile is degenerate.
/// `holeCircles`, when present, is 3 doubles PER HOLE (centre x, centre y,
/// radius) parallel to `holes`; a radius <= 0 means "not a circle, use the
/// polyline". A hole that IS a circle becomes an analytic cylindrical wall
/// instead of the tessellation it was drawn with — without this a plate with a
/// Ø8 hole comes back with a 64-sided bore that only looks round.
/// `outerConic` / `holeConics` describe a boundary that is one exact curve:
/// 5 packed doubles — `cx, cy, rx, ry, rotation` — where `rx`/`ry` are the
/// semi-axes in either order and a non-positive `rx` means "no conic here".
/// Equal semi-axes build a `gp_Circ`, unequal a `gp_Elips`. `holeConics` is
/// one such entry per hole, parallel to `holes`.
///
/// `outerSegments` / `holeSegments` describe a boundary EXACTLY, for loops
/// that contain an arc: 7 packed doubles per edge —
/// `isArc, x1, y1, x2, y2, midX, midY` — where `isArc` > 0.5 means a circular
/// arc from (x1,y1) to (x2,y2) passing through (midX,midY), and anything else
/// is a straight line (the mid pair is then ignored). Nil or empty falls back
/// to the polyline, which is already exact for an all-straight loop. A conic
/// wins over both, and every fallback is per-wire: one unusable boundary uses
/// its polyline without affecting the others.
+ (nullable OCCTShape *)extrudedShapeWithOuterLoop:(NSData *)outerLoop
                                        outerConic:(nullable NSData *)outerConic
                                             holes:(NSArray<NSData *> *)holes
                                        holeConics:(nullable NSData *)holeConics
                                     outerSegments:(nullable NSData *)outerSegments
                                      holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                              zMin:(double)zMin
                                              zMax:(double)zMax
                                             basis:(OCCTPlaneBasis *)basis;

/// Build a primitive matching Euclid's conventions exactly (base sits on y=0;
/// cylinder axis is +Y), so the B-rep coincides with the Euclid CSG mesh.
/// `kind`: 0 = box (a=width, b=depth, c=height), 1 = cylinder (a=radius,
/// b=height), 2 = sphere (a=radius). `transform` is 12 packed doubles
/// (row-major 3×4 placement) or nil for identity.
+ (nullable OCCTShape *)primitiveShapeOfKind:(NSInteger)kind
                                           a:(double)a
                                           b:(double)b
                                           c:(double)c
                                   transform:(nullable NSData *)transform;

/// Apply a rigid placement to a solid. `transform` is 12 packed doubles
/// (row-major 3×4). Needed because a `Body` carries its own transform, which
/// must be baked in before two solids can be booleaned in a common space.
/// Reflect a shape in the PLANE through `origin` with the given `normal`.
///
/// Separate from `transformedShape:` because a reflection cannot be expressed
/// as a `Transform3D` at all — that type is translation + a rotation
/// quaternion + a single uniform scale, and a plane mirror is none of those
/// (a negative uniform scale is a POINT reflection, which is a different
/// transform). `gp_Trsf::SetMirror(gp_Ax2)` does it properly.
+ (nullable OCCTShape *)mirroredShape:(OCCTShape *)shape
                              originX:(double)ox
                              originY:(double)oy
                              originZ:(double)oz
                              normalX:(double)nx
                              normalY:(double)ny
                              normalZ:(double)nz;

+ (nullable OCCTShape *)transformedShape:(OCCTShape *)shape
                                  matrix:(NSData *)transform;

/// Merge faces that lie on the SAME underlying surface, and the edges between
/// them. A fuse of two solids meeting on a shared plane leaves both original
/// faces plus the seam edge, so a box extended by a prism comes back with ten
/// planar faces instead of six — geometrically right, topologically wrong, and
/// the spurious edges are selectable and blendable. Nil on failure; callers
/// keep the un-unified solid, which is still valid.
+ (nullable OCCTShape *)unifiedShape:(OCCTShape *)shape;

/// Boolean of two world-space shapes. `op`: 0 = union (fuse), 1 = subtract
/// (cut a from ... i.e. a − b), 2 = intersect (common). Nil on failure.
+ (nullable OCCTShape *)booleanOfShape:(OCCTShape *)a
                             withShape:(OCCTShape *)b
                                    op:(NSInteger)op;

/// Remove the faces nearest `worldPoints` and heal the result
/// (`BRepAlgoAPI_Defeaturing`) — spec §4.16 Delete Face. A face counts as picked
/// when a sample on it lies within `tolerance` of a point. Nil when nothing
/// matched or the solid couldn't be healed (OCCT refuses when removal would
/// leave an unclosable gap), so callers can report a recoverable failure.
+ (nullable OCCTShape *)defeaturedShape:(OCCTShape *)shape
                                 atWorldPoints:(NSData *)worldPoints
                                     tolerance:(double)tolerance;

/// Analytic face-type histogram of any solid — the check that geometry stayed
/// exact through an operation (e.g. a filleted cylinder keeps ONE cylindrical
/// wall and gains a curved blend face).
+ (OCCTFaceTypeCounts *)faceTypeCountsOfShape:(OCCTShape *)shape;

/// Round the edges that pass near `worldPoints` to `radius`
/// (`BRepFilletAPI_MakeFillet`). `worldPoints` is packed doubles (x,y,z triples)
/// — typically the midpoints of the mesh edges the user picked. An edge counts
/// as picked when any sample along it lies within `tolerance` of a point.
///
/// Because a tessellated rim is many mesh segments but ONE analytic edge, this
/// gives tangent-chain propagation for free: picking a single segment of a
/// cylinder's rim rounds the entire circular edge. Nil if nothing matched or the
/// blend failed (radius too large for the geometry), so callers can fall back.
+ (nullable OCCTShape *)filletedShape:(OCCTShape *)shape
                        atWorldPoints:(NSData *)worldPoints
                               radius:(double)radius
                            tolerance:(double)tolerance;

/// Bevel the edges near `worldPoints` by `distance`
/// (`BRepFilletAPI_MakeChamfer`) — the chamfer half of spec §4.3. Same
/// edge-matching and tangent-chain behaviour as `filletedShape:`.
+ (nullable OCCTShape *)chamferedShape:(OCCTShape *)shape
                        atWorldPoints:(NSData *)worldPoints
                             distance:(double)distance
                            tolerance:(double)tolerance;

/// Hollow a solid to a wall of `thickness`, opening the faces near
/// `worldPoints` (`BRepOffsetAPI_MakeThickSolid`) — spec §4.4 Shell. Pass an
/// empty `worldPoints` for a fully-enclosed hollow. Correct on CURVED walls,
/// unlike the mesh inset approximation. Nil when OCCT can't offset the solid
/// (thickness out of the valid range), so the caller can report it.
+ (nullable OCCTShape *)shelledShape:(OCCTShape *)shape
                       atWorldPoints:(NSData *)worldPoints
                           thickness:(double)thickness
                           tolerance:(double)tolerance;

// MARK: - STEP interchange (spec §12.1 / §12.2)

/// Write `shapes` to a STEP AP214 file at `path`. Exports EXACT B-rep geometry
/// (analytic surfaces survive), unlike the mesh formats. NO on failure.
+ (BOOL)writeSTEPShapes:(NSArray<OCCTShape *> *)shapes toPath:(NSString *)path;

/// Read every solid from the STEP file at `path`. Empty array on failure — the
/// caller reports an unreadable/unsupported file rather than crashing.
+ (NSArray<OCCTShape *> *)readSTEPFromPath:(NSString *)path;

/// Serialize a solid to OCCT's BRep text format, so the analytic geometry can be
/// stored in the document and survive a reload. Nil on failure.
+ (nullable NSData *)serializedShape:(OCCTShape *)shape;

/// Rebuild a solid from `serializedShape:` output. Nil on failure (including a
/// blob written by a different/incompatible OCCT version — callers fall back to
/// the persisted render mesh).
+ (nullable OCCTShape *)shapeFromSerialized:(NSData *)data;

/// Tessellate a world-space shape into a smooth-normalled render mesh (world
/// coordinates). Same deflection semantics as the cylinder method.
+ (OCCTRenderMesh *)renderMeshFromShape:(OCCTShape *)shape
                       angularDeflection:(double)angularDeflection
                        linearDeflection:(double)linearDeflection;

@end

NS_ASSUME_NONNULL_END
