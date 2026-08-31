//
//  OCCTBridge.mm
//  openshape3d — OCCT B-rep port, Milestone 0 (spike)
//
//  Obj-C++ implementation of the narrow OCCT facade. This file is the ONLY
//  place OCCT's C++ headers are included; everything else in the app sees the
//  plain Obj-C interface in OCCTBridge.h.
//

#import "OCCTBridge.h"

#include <vector>
#include <algorithm>
#include <limits>
#include <set>
#include <cmath>
#include <Bnd_Box.hxx>
#include <BRepBndLib.hxx>
#include <cstdint>
#include <sstream>
#include <string>

#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepAlgoAPI_Defeaturing.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <TopTools_ListOfShape.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepFilletAPI_LocalOperation.hxx>
#include <STEPControl_Writer.hxx>
#include <STEPControl_Reader.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <GeomAPI_ProjectPointOnCurve.hxx>
#include <Geom_Curve.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedMapOfShape.hxx>

#include <Standard_Version.hxx>

#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <BRepOffsetAPI_ThruSections.hxx>
#include <BRepOffsetAPI_MakePipe.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <Poly_Triangle.hxx>
#include <TopAbs_Orientation.hxx>
#include <gp_Pnt2d.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <IMeshTools_Parameters.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <BRep_Tool.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <GeomAbs_SurfaceType.hxx>
#include <Poly_Triangulation.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Wire.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Ax2.hxx>
#include <gp_Circ.hxx>
#include <gp_Elips.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <gp_Dir.hxx>
#include <gp_Pnt.hxx>
#include <gp_Vec.hxx>
#include <gp_Trsf.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_BooleanOperation.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <ShapeFix_Shape.hxx>
#include <ShapeAnalysis_ShapeTolerance.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <Precision.hxx>
#include <Standard_Failure.hxx>
#include <GeomAbs_Shape.hxx>
#include <Message_ProgressIndicator.hxx>
#include <Message_ProgressScope.hxx>
#include <TopTools_FormatVersion.hxx>

// Opaque handle: a world-space solid. The C++ TopoDS_Shape ivar is destroyed
// automatically (ARC runs C++ ivar destructors in Obj-C++).
@interface OCCTShape () {
@public
    TopoDS_Shape _shape;
}
@end
@implementation OCCTShape
@end

@interface OCCTPlaneBasis () {
@public
    double _o[3], _x[3], _y[3], _n[3];
}
@end
@implementation OCCTPlaneBasis
- (instancetype)initWithOriginX:(double)ox originY:(double)oy originZ:(double)oz
                         xAxisX:(double)xx xAxisY:(double)xy xAxisZ:(double)xz
                         yAxisX:(double)yx yAxisY:(double)yy yAxisZ:(double)yz
                        normalX:(double)nx normalY:(double)ny normalZ:(double)nz {
    if ((self = [super init])) {
        _o[0]=ox; _o[1]=oy; _o[2]=oz;
        _x[0]=xx; _x[1]=xy; _x[2]=xz;
        _y[0]=yx; _y[1]=yy; _y[2]=yz;
        _n[0]=nx; _n[1]=ny; _n[2]=nz;
    }
    return self;
}
@end

@implementation OCCTOpStatus
@end

// Fill a caller-supplied status object (nil status = caller doesn't care).
static void OS3DSetStatus(OCCTOpStatus *status, OCCTOpCode code, NSString *detail) {
    if (status == nil) return;
    status.code = code;
    status.detail = detail;
}

// True when the shape has a bounding box with only finite coordinates. A
// shape carrying NaN/inf can parse cleanly and then spin forever inside
// BRepMesh_IncrementalMesh (an infinite loop no catch(...) reaches) — see the
// note in TessellateShape. Also the cheap first gate at every constructive-op
// entry, so degenerate operands are refused instead of propagated.
static bool OS3DFiniteBounds(const TopoDS_Shape &shape) {
    if (shape.IsNull()) return false;
    Bnd_Box bounds;
    BRepBndLib::Add(shape, bounds);
    if (bounds.IsVoid()) return false;
    Standard_Real xmin, ymin, zmin, xmax, ymax, zmax;
    bounds.Get(xmin, ymin, zmin, xmax, ymax, zmax);
    for (Standard_Real v : {xmin, ymin, zmin, xmax, ymax, zmax}) {
        if (!std::isfinite(v)) return false;
    }
    return true;
}

// Post-op contract (docs/FREECAD_PLAYBOOK.md I2): a builder's IsDone() is not
// a statement about the RESULT, so check it with BRepCheck_Analyzer; on
// failure make exactly one healing attempt (ShapeFix_Shape) and re-check.
// Returns a null shape when the result is still invalid — the caller must
// fail rather than store it, because a stored invalid solid becomes the
// body's source of truth and is persisted.
static TopoDS_Shape OS3DHealAndValidate(const TopoDS_Shape &result) {
    if (result.IsNull()) return result;
    if (BRepCheck_Analyzer(result).IsValid()) return result;
    Handle(ShapeFix_Shape) fixer = new ShapeFix_Shape(result);
    fixer->Perform();
    const TopoDS_Shape healed = fixer->Shape();
    if (!healed.IsNull() && BRepCheck_Analyzer(healed).IsValid()) return healed;
    return TopoDS_Shape();
}

// Unwrap the single solid from an op result. OCCT booleans hand back a
// COMPOUND even when it holds exactly one solid; storing the compound feeds
// downstream ops (shell, fillet) input they are not specified for. Returns
// the solid itself when there is exactly one, otherwise a null shape with
// `solidCount` saying whether that was 0 (empty result) or several.
static TopoDS_Shape OS3DExtractSingleSolid(const TopoDS_Shape &shape,
                                           int &solidCount) {
    solidCount = 0;
    TopoDS_Shape single;
    for (TopExp_Explorer ex(shape, TopAbs_SOLID); ex.More(); ex.Next()) {
        ++solidCount;
        if (solidCount == 1) single = ex.Current();
    }
    return solidCount == 1 ? single : TopoDS_Shape();
}

// A progress indicator whose only job is to abort a runaway kernel loop: the
// NaN fuzzing rounds proved BRepMesh_IncrementalMesh (and BRepTools::Read)
// can spin FOREVER on degenerate input — an infinite loop no catch(...)
// reaches, on the MainActor. Passed as `indicator->Start()` to any op that
// accepts a Message_ProgressRange; `Fired()` says the deadline tripped, so
// the caller returns a clean failure instead of trusting a half-built
// result. (FreeCAD wraps the same mechanism around its long ops —
// docs/FREECAD_PLAYBOOK.md H1.)
class OS3DDeadlineProgress : public Message_ProgressIndicator {
public:
    explicit OS3DDeadlineProgress(double seconds)
        : myDeadline(CFAbsoluteTimeGetCurrent() + seconds) {}
    Standard_Boolean UserBreak() Standard_OVERRIDE {
        return CFAbsoluteTimeGetCurrent() > myDeadline;
    }
    void Show(const Message_ProgressScope &, const Standard_Boolean) Standard_OVERRIDE {}
    bool Fired() const { return CFAbsoluteTimeGetCurrent() > myDeadline; }
private:
    double myDeadline;
};

// Generous against real work (normal tessellation is milliseconds), tight
// against a hang the user would otherwise force-quit out of.
static const double kOS3DKernelDeadlineSeconds = 5.0;

// Same-domain unification, shared by unifiedShape: and the boolean result
// path. (unifyEdges, unifyFaces, concatBSplines) — faces and edges, but do
// NOT merge B-spline geometry: that would change analytic surfaces into
// something else. Returns the input on any failure — the un-unified shape is
// still valid.
static TopoDS_Shape OS3DUnified(const TopoDS_Shape &shape) {
    try {
        ShapeUpgrade_UnifySameDomain unifier(
            shape, Standard_True, Standard_True, Standard_False);
        unifier.Build();
        const TopoDS_Shape result = unifier.Shape();
        return result.IsNull() ? shape : result;
    } catch (...) {
        return shape;
    }
}

@interface OCCTRenderMesh () {
@public
    NSInteger _vertexCount;
    NSInteger _triangleCount;
    NSData *_positions;
    NSData *_normals;
    NSData *_indices;
}
@end

static OCCTRenderMesh *EmptyRenderMesh() {
    OCCTRenderMesh *out = [OCCTRenderMesh new];
    out->_vertexCount = 0;
    out->_triangleCount = 0;
    out->_positions = [NSData data];
    out->_normals = [NSData data];
    out->_indices = [NSData data];
    return out;
}

// Tessellate a shape and extract SMOOTH per-vertex normals from each face's
// analytic surface. Shared by the cylinder and general-shape render paths.
//
// Exception barrier: BRepMesh_IncrementalMesh and BRepAdaptor_Surface::D1
// raise Standard_Failure (a C++ exception) on degenerate or corrupt shapes —
// e.g. a marginal boolean result or a blob from another OCCT version.
// Letting one unwind through the Obj-C++ frame into Swift is a hard crash,
// and this runs on the main success path (adoptBRep tessellates every OCCT
// result). An empty mesh reads as failure upstream: adoptBRep leaves the
// body on the Euclid path.
static OCCTRenderMesh *TessellateShape(const TopoDS_Shape &solid,
                                       double linearDeflection,
                                       double angularDeflection) {
  try {
    // Refuse non-finite geometry BEFORE meshing. A shape carrying NaN/inf
    // coordinates can parse cleanly (correct face counts and all) and then
    // spin forever inside BRepMesh_IncrementalMesh — an INFINITE LOOP, which
    // the catch(...) below cannot catch, on the MainActor, i.e. an
    // unrecoverable freeze on document open. Verified by fuzzing the BREP
    // reader (2026-08-25 review round 3). Also protects the internal path
    // when a degenerate kernel op emits a NaN.
    if (!OS3DFiniteBounds(solid)) return EmptyRenderMesh();

    // The finite-bounds gate above catches NaN COORDINATES; the deadline
    // catches everything else that makes the mesher spin (degenerate
    // pcurves, self-intersecting tolerance zones from a fuzzed blob). A
    // tripped deadline yields an empty mesh — the same recoverable failure
    // as any other bad shape — instead of a frozen MainActor. (The simple
    // constructor auto-Performs with no progress hook, so parameters go
    // through IMeshTools_Parameters.)
    OS3DDeadlineProgress *deadline = new OS3DDeadlineProgress(kOS3DKernelDeadlineSeconds);
    Handle(Message_ProgressIndicator) progress(deadline);
    IMeshTools_Parameters params;
    params.Deflection = linearDeflection;
    params.Angle = angularDeflection;
    params.Relative = Standard_False;
    params.InParallel = Standard_True;
    BRepMesh_IncrementalMesh mesher(solid, params, progress->Start());
    if (deadline->Fired()) return EmptyRenderMesh();

    std::vector<float> positions, normals;
    std::vector<uint32_t> indices;

    for (TopExp_Explorer ex(solid, TopAbs_FACE); ex.More(); ex.Next()) {
        TopoDS_Face face = TopoDS::Face(ex.Current());
        TopLoc_Location loc;
        Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
        if (tri.IsNull()) continue;

        const gp_Trsf trsf = loc.Transformation();
        const bool reversed = (face.Orientation() == TopAbs_REVERSED);
        const bool haveUV = tri->HasUVNodes();
        BRepAdaptor_Surface surf(face, Standard_False);
        const uint32_t base = (uint32_t)(positions.size() / 3);

        for (Standard_Integer i = 1; i <= tri->NbNodes(); ++i) {
            gp_Pnt p = tri->Node(i).Transformed(trsf);
            positions.push_back((float)p.X());
            positions.push_back((float)p.Y());
            positions.push_back((float)p.Z());

            gp_Vec n(0.0, 0.0, 1.0);
            if (haveUV) {
                gp_Pnt2d uv = tri->UVNode(i);
                gp_Pnt sp; gp_Vec du, dv;
                surf.D1(uv.X(), uv.Y(), sp, du, dv);
                gp_Vec cross = du.Crossed(dv);
                if (cross.Magnitude() > 1e-12) {
                    n = cross.Normalized();
                    if (reversed) n.Reverse();
                    n.Transform(trsf);
                }
            }
            normals.push_back((float)n.X());
            normals.push_back((float)n.Y());
            normals.push_back((float)n.Z());
        }

        for (Standard_Integer t = 1; t <= tri->NbTriangles(); ++t) {
            Standard_Integer a, b, c;
            tri->Triangle(t).Get(a, b, c);
            if (reversed) std::swap(b, c);
            indices.push_back(base + (uint32_t)(a - 1));
            indices.push_back(base + (uint32_t)(b - 1));
            indices.push_back(base + (uint32_t)(c - 1));
        }
    }

    OCCTRenderMesh *out = [OCCTRenderMesh new];
    out->_vertexCount = (NSInteger)(positions.size() / 3);
    out->_triangleCount = (NSInteger)(indices.size() / 3);
    out->_positions = [NSData dataWithBytes:positions.data() length:positions.size() * sizeof(float)];
    out->_normals = [NSData dataWithBytes:normals.data() length:normals.size() * sizeof(float)];
    out->_indices = [NSData dataWithBytes:indices.data() length:indices.size() * sizeof(uint32_t)];
    return out;
  } catch (...) {
    return EmptyRenderMesh();
  }
}

@implementation OCCTMeshResult {
@public
    NSInteger _triangleCount;
    NSInteger _vertexCount;
    double _volume;
}
- (NSInteger)triangleCount { return _triangleCount; }
- (NSInteger)vertexCount { return _vertexCount; }
- (double)volume { return _volume; }
@end

@implementation OCCTFaceTypeCounts {
@public
    NSInteger _planar;
    NSInteger _cylindrical;
    NSInteger _other;
}
- (NSInteger)planar { return _planar; }
- (NSInteger)cylindrical { return _cylindrical; }
- (NSInteger)other { return _other; }
@end

@implementation OCCTRenderMesh
- (NSInteger)vertexCount { return _vertexCount; }
- (NSInteger)triangleCount { return _triangleCount; }
- (NSData *)positions { return _positions; }
- (NSData *)normals { return _normals; }
- (NSData *)indices { return _indices; }
@end

@implementation OCCTBridge

+ (NSString *)occtVersion {
    return @OCC_VERSION_COMPLETE;
}

+ (OCCTMeshResult *)meshBoxWithSize:(double)size {
    TopoDS_Shape box = BRepPrimAPI_MakeBox(size, size, size).Shape();

    // Tessellate. Linear deflection 0.1 mm is fine for a spike sanity check.
    BRepMesh_IncrementalMesh mesher(box, 0.1);
    mesher.Perform();

    NSInteger tris = 0;
    NSInteger verts = 0;
    for (TopExp_Explorer ex(box, TopAbs_FACE); ex.More(); ex.Next()) {
        TopoDS_Face face = TopoDS::Face(ex.Current());
        TopLoc_Location loc;
        Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
        if (!tri.IsNull()) {
            tris += tri->NbTriangles();
            verts += tri->NbNodes();
        }
    }

    GProp_GProps props;
    BRepGProp::VolumeProperties(box, props);

    OCCTMeshResult *result = [OCCTMeshResult new];
    result->_triangleCount = tris;
    result->_vertexCount = verts;
    result->_volume = props.Mass();
    return result;
}

+ (OCCTFaceTypeCounts *)extrudeCircleFaceCountsWithRadius:(double)r
                                                   height:(double)height {
    // Circle on the XY plane → planar face → prism along +Z.
    gp_Ax2 axis(gp_Pnt(0.0, 0.0, 0.0), gp_Dir(0.0, 0.0, 1.0));
    gp_Circ circle(axis, r);
    TopoDS_Edge edge = BRepBuilderAPI_MakeEdge(circle);
    TopoDS_Wire wire = BRepBuilderAPI_MakeWire(edge);
    TopoDS_Face face = BRepBuilderAPI_MakeFace(wire);
    TopoDS_Shape solid = BRepPrimAPI_MakePrism(face, gp_Vec(0.0, 0.0, height));

    NSInteger planar = 0, cyl = 0, other = 0;
    for (TopExp_Explorer ex(solid, TopAbs_FACE); ex.More(); ex.Next()) {
        BRepAdaptor_Surface surf(TopoDS::Face(ex.Current()));
        switch (surf.GetType()) {
            case GeomAbs_Plane: planar++; break;
            case GeomAbs_Cylinder: cyl++; break;
            default: other++; break;
        }
    }

    OCCTFaceTypeCounts *counts = [OCCTFaceTypeCounts new];
    counts->_planar = planar;
    counts->_cylindrical = cyl;
    counts->_other = other;
    return counts;
}

+ (OCCTRenderMesh *)cylinderRenderMeshWithCenterX:(double)cx
                                          centerY:(double)cy
                                           radius:(double)r
                                             zMin:(double)zMin
                                             zMax:(double)zMax
                                 angularDeflection:(double)angularDeflection
                                  linearDeflection:(double)linearDeflection {
    const double height = zMax - zMin;
    gp_Ax2 axis(gp_Pnt(cx, cy, zMin), gp_Dir(0.0, 0.0, 1.0));
    TopoDS_Shape solid = BRepPrimAPI_MakeCylinder(axis, r, height).Shape();
    return TessellateShape(solid, linearDeflection, angularDeflection);
}

// MARK: - B-rep source of truth

// Build a wire on the plane z=`z` from packed (x,y) doubles.
static TopoDS_Wire PolyWire(NSData *loop, double z) {
    const double *p = (const double *)loop.bytes;
    NSUInteger n = loop.length / (2 * sizeof(double));
    BRepBuilderAPI_MakePolygon poly;
    for (NSUInteger i = 0; i < n; ++i) poly.Add(gp_Pnt(p[2*i], p[2*i+1], z));
    poly.Close();
    return poly.Wire();
}

// Build a closed wire from one packed conic: `cx, cy, rx, ry, rotation`
// (see OCCTBridge.h). Null wire when `rx` is not positive — the caller then
// falls back to the polyline.
//
// `gp_Elips` REQUIRES its major radius first and refuses major < minor, and
// the sketch's own semi-axes are in no particular order, so the larger one is
// chosen here and the reference direction turned a quarter turn when that is
// the y semi-axis. Equal radii would make `gp_Elips` degenerate, so a circle
// is built as a circle — which is also what keeps a drilled hole reporting as
// a cylindrical face rather than a surface of extrusion.
static TopoDS_Wire ConicWire(const double *c, double z) {
    const double cx = c[0], cy = c[1], rx = c[2], ry = c[3], rot = c[4];
    if (!(rx > 1e-12) || !(ry > 1e-12)) return TopoDS_Wire();
    const gp_Pnt centre(cx, cy, z);
    const gp_Dir up(0.0, 0.0, 1.0);
    if (fabs(rx - ry) <= 1e-9 * fmax(rx, ry)) {
        gp_Ax2 ax(centre, up);
        BRepBuilderAPI_MakeEdge me{gp_Circ(ax, rx)};
        if (!me.IsDone()) return TopoDS_Wire();
        return BRepBuilderAPI_MakeWire(me.Edge()).Wire();
    }
    const bool xIsMajor = rx > ry;
    const double angle = xIsMajor ? rot : rot + M_PI_2;
    gp_Ax2 ax(centre, up, gp_Dir(cos(angle), sin(angle), 0.0));
    BRepBuilderAPI_MakeEdge me{
        gp_Elips(ax, xIsMajor ? rx : ry, xIsMajor ? ry : rx)};
    if (!me.IsDone()) return TopoDS_Wire();
    return BRepBuilderAPI_MakeWire(me.Edge()).Wire();
}

// Build a wire on the plane z=`z` from packed edges: 7 doubles each,
// `isArc, x1, y1, x2, y2, midX, midY` (see OCCTBridge.h).
//
// A tessellated arc reaches OCCT as a polyline and stays one forever after: a
// fillet on the rim then has one segment per facet, and STEP exports every
// one of them as a plane. Three points reconstruct the circle exactly, and
// GC_MakeArcOfCircle takes them in traversal order, so a chain walked
// backwards needs no sign flip anywhere.
//
// Returns a null wire on any bad edge; the caller falls back to the polyline
// rather than building half a boundary.
static TopoDS_Wire SegWire(NSData *segs, double z) {
    const NSUInteger stride = 7;
    const double *p = (const double *)segs.bytes;
    NSUInteger n = segs.length / (stride * sizeof(double));
    if (n < 2) return TopoDS_Wire();
    BRepBuilderAPI_MakeWire mw;
    for (NSUInteger i = 0; i < n; ++i) {
        const double *e = p + i * stride;
        gp_Pnt a(e[1], e[2], z), b(e[3], e[4], z);
        if (a.IsEqual(b, 1e-12)) return TopoDS_Wire();
        if (e[0] > 0.5) {
            gp_Pnt m(e[5], e[6], z);
            GC_MakeArcOfCircle mk(a, m, b);
            // Collinear samples have no circle through them; a "flat arc" is
            // a straight line and is built as one rather than failing.
            if (mk.IsDone()) {
                BRepBuilderAPI_MakeEdge me(mk.Value());
                if (!me.IsDone()) return TopoDS_Wire();
                mw.Add(me.Edge());
                continue;
            }
        }
        BRepBuilderAPI_MakeEdge me(a, b);
        if (!me.IsDone()) return TopoDS_Wire();
        mw.Add(me.Edge());
    }
    if (!mw.IsDone()) return TopoDS_Wire();
    return mw.Wire();
}

/// Build the profile FACE that every profile-driven op starts from, on the
/// plane z = `z` in profile-local space.
///
/// Factored out of `extrudedShapeWithOuterLoop:` so revolve, sweep and loft
/// begin from EXACTLY the same wires an extrude does — the analytic conic, the
/// exact arc segments, or the polyline, chosen in that order. Anything less
/// would mean a circle staying round when extruded and going faceted when
/// revolved, which is the sort of quiet inconsistency the B-rep work exists to
/// remove. Returns a null face on any failure.
static TopoDS_Face OS3DProfileFace(NSData *outerLoop,
                                   NSData *outerConic,
                                   NSArray<NSData *> *holes,
                                   NSData *holeConics,
                                   NSData *outerSegments,
                                   NSArray<NSData *> *holeSegments,
                                   double z) {
    TopoDS_Wire outerWire;
    if (outerConic != nil && outerConic.length >= 5 * sizeof(double)) {
        outerWire = ConicWire((const double *)outerConic.bytes, z);
    }
    if (outerWire.IsNull() && outerSegments != nil && outerSegments.length > 0) {
        outerWire = SegWire(outerSegments, z);
    }
    if (outerWire.IsNull()) {
        if (outerLoop.length < 3 * 2 * (NSInteger)sizeof(double)) return TopoDS_Face();
        outerWire = PolyWire(outerLoop, z);
    }
    if (outerWire.IsNull()) return TopoDS_Face();

    BRepBuilderAPI_MakeFace mf(outerWire, Standard_True);
    const double *conics = NULL;
    NSUInteger conicCount = 0;
    if (holeConics != nil) {
        conics = (const double *)holeConics.bytes;
        conicCount = holeConics.length / (5 * sizeof(double));
    }
    NSUInteger index = 0;
    for (NSData *hole in holes) {
        TopoDS_Wire hw;
        if (index < conicCount) hw = ConicWire(conics + index * 5, z);
        if (hw.IsNull()) {
            NSData *hs = (holeSegments != nil && index < holeSegments.count)
                ? holeSegments[index] : nil;
            if (hs != nil && hs.length > 0) hw = SegWire(hs, z);
        }
        if (hw.IsNull()) {
            if (hole.length < 3 * 2 * (NSInteger)sizeof(double)) { index++; continue; }
            hw = PolyWire(hole, z);
        }
        hw.Reverse();  // inner boundary opposes the outer sense
        mf.Add(hw);
        index++;
    }
    if (!mf.IsDone()) return TopoDS_Face();
    return mf.Face();
}

/// plane-local → world, from the basis columns.
static gp_Trsf OS3DBasisTransform(OCCTPlaneBasis *basis) {
    gp_Trsf t;
    t.SetValues(basis->_x[0], basis->_y[0], basis->_n[0], basis->_o[0],
                basis->_x[1], basis->_y[1], basis->_n[1], basis->_o[1],
                basis->_x[2], basis->_y[2], basis->_n[2], basis->_o[2]);
    return t;
}

+ (nullable OCCTShape *)extrudedShapeWithOuterLoop:(NSData *)outerLoop
                                        outerConic:(nullable NSData *)outerConic
                                             holes:(NSArray<NSData *> *)holes
                                        holeConics:(nullable NSData *)holeConics
                                     outerSegments:(nullable NSData *)outerSegments
                                      holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                              zMin:(double)zMin
                                              zMax:(double)zMax
                                             basis:(OCCTPlaneBasis *)basis {
    const double height = zMax - zMin;
    if (height <= 1e-9) return nil;
    try {
        const TopoDS_Face face = OS3DProfileFace(outerLoop, outerConic, holes,
                                                 holeConics, outerSegments,
                                                 holeSegments, zMin);
        if (face.IsNull()) return nil;

        TopoDS_Shape solid = BRepPrimAPI_MakePrism(
            face, gp_Vec(0.0, 0.0, height)).Shape();
        TopoDS_Shape world = BRepBuilderAPI_Transform(
            solid, OS3DBasisTransform(basis), Standard_True).Shape();

        OCCTShape *out = [OCCTShape new];
        out->_shape = world;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)primitiveShapeOfKind:(NSInteger)kind
                                           a:(double)a
                                           b:(double)b
                                           c:(double)c
                                   transform:(nullable NSData *)transform {
    try {
        TopoDS_Shape shape;
        switch (kind) {
            case 0:  // box: Euclid centers x/z and puts the base on y=0
                if (a <= 0 || b <= 0 || c <= 0) return nil;
                shape = BRepPrimAPI_MakeBox(gp_Pnt(-a / 2.0, 0.0, -b / 2.0), a, c, b).Shape();
                break;
            case 1:  // cylinder: base on y=0, axis +Y
                if (a <= 0 || b <= 0) return nil;
                shape = BRepPrimAPI_MakeCylinder(
                    gp_Ax2(gp_Pnt(0.0, 0.0, 0.0), gp_Dir(0.0, 1.0, 0.0)), a, b).Shape();
                break;
            default:  // sphere: centered at (0, r, 0) so it rests on y=0
                if (a <= 0) return nil;
                shape = BRepPrimAPI_MakeSphere(gp_Pnt(0.0, a, 0.0), a).Shape();
                break;
        }
        if (transform != nil && transform.length >= 12 * sizeof(double)) {
            const double *m = (const double *)transform.bytes;  // row-major 3x4
            gp_Trsf t;
            t.SetValues(m[0], m[1], m[2],  m[3],
                        m[4], m[5], m[6],  m[7],
                        m[8], m[9], m[10], m[11]);
            shape = BRepBuilderAPI_Transform(shape, t, Standard_True).Shape();
        }
        OCCTShape *out = [OCCTShape new];
        out->_shape = shape;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)revolvedShapeWithOuterLoop:(NSData *)outerLoop
                                        outerConic:(nullable NSData *)outerConic
                                             holes:(NSArray<NSData *> *)holes
                                        holeConics:(nullable NSData *)holeConics
                                     outerSegments:(nullable NSData *)outerSegments
                                      holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                             basis:(OCCTPlaneBasis *)basis
                                              axis:(NSData *)axis
                                             angle:(double)angle {
    if (axis.length < 6 * sizeof(double)) return nil;
    if (!(fabs(angle) > 1e-9)) return nil;
    const double *a = (const double *)axis.bytes;
    const double dl = sqrt(a[3]*a[3] + a[4]*a[4] + a[5]*a[5]);
    if (!(dl > 1e-12)) return nil;
    try {
        const TopoDS_Face face = OS3DProfileFace(outerLoop, outerConic, holes,
                                                 holeConics, outerSegments,
                                                 holeSegments, 0.0);
        if (face.IsNull()) return nil;
        // Into world space first, because the axis is given in world space —
        // cheaper and less error-prone than mapping the axis into the profile's
        // own frame.
        const TopoDS_Shape worldFace = BRepBuilderAPI_Transform(
            face, OS3DBasisTransform(basis), Standard_True).Shape();
        gp_Ax1 ax(gp_Pnt(a[0], a[1], a[2]), gp_Dir(a[3]/dl, a[4]/dl, a[5]/dl));
        BRepPrimAPI_MakeRevol mk(worldFace, ax, angle);
        mk.Build();
        if (!mk.IsDone()) return nil;
        const TopoDS_Shape solid = mk.Shape();
        if (solid.IsNull()) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = solid;
        return out;
    } catch (...) {
        // A profile that crosses or touches the axis is a legitimate user
        // mistake; the mesh path reports it as empty geometry.
        return nil;
    }
}

+ (nullable OCCTShape *)loftedShapeWithOuterLoops:(NSArray<NSData *> *)outerLoops
                                      outerConics:(NSArray<NSData *> *)outerConics
                                    outerSegments:(NSArray<NSData *> *)outerSegments
                                           bases:(NSArray<OCCTPlaneBasis *> *)bases {
    if (outerLoops.count < 2 || bases.count != outerLoops.count) return nil;
    try {
        BRepOffsetAPI_ThruSections mk(Standard_True /* solid */, Standard_False /* ruled */);
        for (NSUInteger i = 0; i < outerLoops.count; ++i) {
            NSData *conic = (i < outerConics.count && outerConics[i].length > 0)
                ? outerConics[i] : nil;
            NSData *segs = (i < outerSegments.count && outerSegments[i].length > 0)
                ? outerSegments[i] : nil;
            TopoDS_Wire wire;
            if (conic != nil && conic.length >= 5 * sizeof(double)) {
                wire = ConicWire((const double *)conic.bytes, 0.0);
            }
            if (wire.IsNull() && segs != nil) wire = SegWire(segs, 0.0);
            if (wire.IsNull()) {
                if (outerLoops[i].length < 3 * 2 * (NSInteger)sizeof(double)) return nil;
                wire = PolyWire(outerLoops[i], 0.0);
            }
            if (wire.IsNull()) return nil;
            const TopoDS_Shape placed = BRepBuilderAPI_Transform(
                wire, OS3DBasisTransform(bases[i]), Standard_True).Shape();
            mk.AddWire(TopoDS::Wire(placed));
        }
        mk.Build();
        if (!mk.IsDone()) return nil;
        const TopoDS_Shape solid = mk.Shape();
        if (solid.IsNull()) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = solid;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)sweptShapeWithOuterLoop:(NSData *)outerLoop
                                     outerConic:(nullable NSData *)outerConic
                                          holes:(NSArray<NSData *> *)holes
                                     holeConics:(nullable NSData *)holeConics
                                  outerSegments:(nullable NSData *)outerSegments
                                   holeSegments:(nullable NSArray<NSData *> *)holeSegments
                                          basis:(OCCTPlaneBasis *)basis
                                          spine:(NSData *)spine {
    const NSUInteger points = spine.length / (3 * sizeof(double));
    if (points < 2) return nil;
    const double *s = (const double *)spine.bytes;
    try {
        const TopoDS_Face face = OS3DProfileFace(outerLoop, outerConic, holes,
                                                 holeConics, outerSegments,
                                                 holeSegments, 0.0);
        if (face.IsNull()) return nil;
        const TopoDS_Shape worldFace = BRepBuilderAPI_Transform(
            face, OS3DBasisTransform(basis), Standard_True).Shape();

        BRepBuilderAPI_MakePolygon poly;
        for (NSUInteger i = 0; i < points; ++i) {
            poly.Add(gp_Pnt(s[3*i], s[3*i+1], s[3*i+2]));
        }
        if (!poly.IsDone()) return nil;
        const TopoDS_Wire spineWire = poly.Wire();
        if (spineWire.IsNull()) return nil;

        BRepOffsetAPI_MakePipe mk(spineWire, worldFace);
        mk.Build();
        if (!mk.IsDone()) return nil;
        const TopoDS_Shape solid = mk.Shape();
        if (solid.IsNull()) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = solid;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)mirroredShape:(OCCTShape *)shape
                              originX:(double)ox
                              originY:(double)oy
                              originZ:(double)oz
                              normalX:(double)nx
                              normalY:(double)ny
                              normalZ:(double)nz {
    if (shape == nil) return nil;
    const double len = sqrt(nx * nx + ny * ny + nz * nz);
    if (!(len > 1e-12)) return nil;
    try {
        // gp_Ax2's main direction is the plane NORMAL; SetMirror reflects in
        // the plane that system spans, which is what a mirror feature means.
        gp_Ax2 ax(gp_Pnt(ox, oy, oz), gp_Dir(nx / len, ny / len, nz / len));
        gp_Trsf t;
        t.SetMirror(ax);
        TopoDS_Shape out = BRepBuilderAPI_Transform(shape->_shape, t, Standard_True).Shape();
        if (out.IsNull()) return nil;
        OCCTShape *result = [OCCTShape new];
        result->_shape = out;
        return result;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)transformedShape:(OCCTShape *)shape
                                  matrix:(NSData *)transform {
    if (shape == nil || transform.length < 12 * sizeof(double)) return nil;
    try {
        const double *m = (const double *)transform.bytes;  // row-major 3x4
        gp_Trsf t;
        t.SetValues(m[0], m[1], m[2],  m[3],
                    m[4], m[5], m[6],  m[7],
                    m[8], m[9], m[10], m[11]);
        TopoDS_Shape moved = BRepBuilderAPI_Transform(shape->_shape, t, Standard_True).Shape();
        if (moved.IsNull()) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = moved;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)unifiedShape:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return nil;
    const TopoDS_Shape result = OS3DUnified(shape->_shape);
    if (result.IsNull()) return nil;
    OCCTShape *out = [OCCTShape new];
    out->_shape = result;
    return out;
}

+ (nullable OCCTShape *)booleanOfShape:(OCCTShape *)a
                             withShape:(OCCTShape *)b
                                    op:(NSInteger)op
                                status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"missing operand");
    if (a == nil || b == nil) return nil;
    try {
        // Garbage in was how "solid ops corrupt": an invalid operand doesn't
        // make the boolean FAIL, it makes the result subtly wrong, and that
        // result becomes a body's source of truth and gets persisted. So
        // check both operands up front (with one healing attempt each) —
        // the same gate FreeCAD's boolean wrapper applies
        // (docs/FREECAD_PLAYBOOK.md B1).
        TopoDS_Shape sa = a->_shape, sb = b->_shape;
        if (!OS3DFiniteBounds(sa) || !OS3DFiniteBounds(sb)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"an operand has empty or non-finite geometry");
            return nil;
        }
        if (!BRepCheck_Analyzer(sa).IsValid()) {
            sa = OS3DHealAndValidate(sa);
            if (sa.IsNull()) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"the target solid is invalid");
                return nil;
            }
        }
        if (!BRepCheck_Analyzer(sb).IsValid()) {
            sb = OS3DHealAndValidate(sb);
            if (sb.IsNull()) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"the tool solid is invalid");
                return nil;
            }
        }

        // Fuzzy tolerance scaled to the operands' combined extent — the
        // near-coincident faces two snapped-together bodies meet on need a
        // merge tolerance proportional to the model, and Precision::Confusion
        // alone (1e-7) is far below it. Retry once at 10× before giving up:
        // a bounded ladder, not a loop.
        Bnd_Box bounds;
        BRepBndLib::Add(sa, bounds);
        BRepBndLib::Add(sb, bounds);
        const double baseFuzzy =
            sqrt(bounds.SquareExtent()) * Precision::Confusion();

        TopTools_ListOfShape args, tools;
        args.Append(sa);
        tools.Append(sb);
        const BOPAlgo_Operation operation =
            op == 0 ? BOPAlgo_FUSE : (op == 1 ? BOPAlgo_CUT : BOPAlgo_COMMON);

        TopoDS_Shape result;
        std::string errorDump;
        for (const double fuzzy : {baseFuzzy, baseFuzzy * 10.0}) {
            BRepAlgoAPI_BooleanOperation builder;
            builder.SetArguments(args);
            builder.SetTools(tools);
            builder.SetOperation(operation);
            // Non-destructive: never let the builder modify the input
            // TShapes — handles are aliased by undo snapshots.
            builder.SetNonDestructive(Standard_True);
            builder.SetFuzzyValue(fuzzy);
            builder.Build();
            if (builder.IsDone() && !builder.HasErrors()) {
                result = builder.Shape();
                break;
            }
            std::ostringstream os;
            builder.DumpErrors(os);
            errorDump = os.str();
        }
        if (result.IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          [NSString stringWithFormat:@"boolean failed: %s",
                           errorDump.c_str()]);
            return nil;
        }

        // Normalize: unwrap the compound, merge coplanar seams, validate.
        // Downstream ops (shell, fillet) receive this shape as their input
        // and are only specified for a SOLID — feeding them the raw compound
        // was review finding R4-O3.
        int solidCount = 0;
        const TopoDS_Shape single = OS3DExtractSingleSolid(result, solidCount);
        if (solidCount == 0) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the operation leaves no solid");
            return nil;
        }
        TopoDS_Shape normalized = OS3DUnified(
            solidCount == 1 ? single : result);
        normalized = OS3DHealAndValidate(normalized);
        if (normalized.IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                          @"boolean result failed validity checking");
            return nil;
        }

        if (solidCount > 1) {
            OS3DSetStatus(status, OCCTOpCodeMultiSolid, nil);
            if (status != nil) status.solidCount = solidCount;
        } else {
            OS3DSetStatus(status, OCCTOpCodeOK, nil);
        }
        OCCTShape *out = [OCCTShape new];
        out->_shape = normalized;
        return out;
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

/// Faces the user actually picked: for EACH picked point, the single NEAREST
/// face (when within `tolerance`). Same rationale as `OS3DNearestEdges` — at
/// 2% of the body diagonal, the old all-within-tolerance rule opened or
/// deleted the face on the OPPOSITE side of a thin plate.
///
/// Distance is the EXACT distance to the trimmed face
/// (`BRepExtrema_DistShapeShape`), not to samples on the surface's UV
/// bounding box. The old 5×5 UV grid measured the un-trimmed surface, so a
/// pick at the centroid of a triangular face could land 10+ mm from every
/// sample and be rejected, while a point under an overhanging face's UV box
/// could match a face it isn't even on (review finding R4-O2, closed here —
/// docs/FREECAD_PLAYBOOK.md FT1).
static std::set<Standard_Integer> OS3DNearestFaces(
    const TopTools_IndexedMapOfShape &faceMap,
    const double *pts, NSUInteger count, double tolerance
) {
    std::vector<double> bestDistance(count, std::numeric_limits<double>::max());
    std::vector<Standard_Integer> bestFace(count, 0);

    for (NSUInteger k = 0; k < count; ++k) {
        const TopoDS_Shape vertex = BRepBuilderAPI_MakeVertex(
            gp_Pnt(pts[3*k], pts[3*k+1], pts[3*k+2])).Shape();
        for (Standard_Integer i = 1; i <= faceMap.Extent(); ++i) {
            try {
                BRepExtrema_DistShapeShape dist(vertex, faceMap(i));
                if (!dist.IsDone() || dist.NbSolution() == 0) continue;
                const double d = dist.Value();
                if (d < bestDistance[k]) { bestDistance[k] = d; bestFace[k] = i; }
            } catch (...) {
                continue;  // an unmeasurable face simply can't win the pick
            }
        }
    }

    std::set<Standard_Integer> chosen;
    for (NSUInteger k = 0; k < count; ++k) {
        if (bestFace[k] != 0 && bestDistance[k] <= tolerance) {
            chosen.insert(bestFace[k]);
        }
    }
    return chosen;
}

+ (nullable OCCTShape *)defeaturedShape:(OCCTShape *)shape
                                 atWorldPoints:(NSData *)worldPoints
                                     tolerance:(double)tolerance
                                        status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"no input");
    if (shape == nil) return nil;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    if (count == 0) return nil;
    const double *pts = (const double *)worldPoints.bytes;

    try {
        if (!OS3DFiniteBounds(shape->_shape)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the body has empty or non-finite geometry");
            return nil;
        }
        TopTools_IndexedMapOfShape faceMap;
        TopExp::MapShapes(shape->_shape, TopAbs_FACE, faceMap);
        TopTools_ListOfShape toRemove;
        for (Standard_Integer i : OS3DNearestFaces(faceMap, pts, count, tolerance)) {
            toRemove.Append(TopoDS::Face(faceMap(i)));
        }
        if (toRemove.IsEmpty()) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                          @"no face within tolerance of the pick");
            return nil;
        }

        BRepAlgoAPI_Defeaturing defeat;
        defeat.SetShape(shape->_shape);
        defeat.AddFacesToRemove(toRemove);
        defeat.Build();
        if (!defeat.IsDone() || defeat.HasErrors()) {
            std::ostringstream os;
            defeat.DumpErrors(os);
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          [NSString stringWithFormat:
                           @"the solid can't be healed without these faces: %s",
                           os.str().c_str()]);
            return nil;
        }
        const TopoDS_Shape valid = OS3DHealAndValidate(defeat.Shape());
        if (valid.IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                          @"the healed solid failed validity checking");
            return nil;
        }

        OS3DSetStatus(status, OCCTOpCodeOK, nil);
        OCCTShape *out = [OCCTShape new];
        out->_shape = valid;
        return out;
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

+ (OCCTFaceTypeCounts *)faceTypeCountsOfShape:(OCCTShape *)shape {
    NSInteger planar = 0, cyl = 0, other = 0;
    if (shape != nil) {
        try {
            for (TopExp_Explorer ex(shape->_shape, TopAbs_FACE); ex.More(); ex.Next()) {
                BRepAdaptor_Surface surf(TopoDS::Face(ex.Current()));
                switch (surf.GetType()) {
                    case GeomAbs_Plane: planar++; break;
                    case GeomAbs_Cylinder: cyl++; break;
                    default: other++; break;
                }
            }
        } catch (...) {
            // Same exception barrier as TessellateShape: a corrupt shape
            // (e.g. deserialized from a newer OCCT) must not crash the app.
            planar = 0; cyl = 0; other = 0;
        }
    }
    OCCTFaceTypeCounts *counts = [OCCTFaceTypeCounts new];
    counts->_planar = planar;
    counts->_cylindrical = cyl;
    counts->_other = other;
    return counts;
}

/// Edges the user actually picked: for EACH picked point, the single NEAREST
/// edge (when it is within `tolerance`), rather than every edge that happens
/// to fall inside the tolerance ball.
///
/// The all-within-tolerance rule was a real defect: tolerance is 1–2% of the
/// body's AABB diagonal, so on an ordinary 100×100×1 mm plate it is 1.4–2.8 mm
/// against a 1 mm thickness — picking one rim also rounded the rim on the
/// opposite face (2026-08-25 review round 4). Nearest-wins keeps a
/// tessellated rim working (its many midpoints all resolve to the same OCCT
/// edge) while making the pick unambiguous on thin parts.
static std::set<Standard_Integer> OS3DNearestEdges(
    const TopTools_IndexedMapOfShape &edgeMap,
    const double *pts, NSUInteger count, double tolerance
) {
    std::vector<double> bestDistance(count, std::numeric_limits<double>::max());
    std::vector<Standard_Integer> bestEdge(count, 0);

    for (Standard_Integer i = 1; i <= edgeMap.Extent(); ++i) {
        const TopoDS_Edge edge = TopoDS::Edge(edgeMap(i));
        if (BRep_Tool::Degenerated(edge)) continue;

        BRepAdaptor_Curve curve(edge);
        const double first = curve.FirstParameter();
        const double last = curve.LastParameter();

        // The TRUE distance to the curve, by projection — not the distance to
        // the nearest of a handful of samples.
        //
        // This used to sample 16 points along the parameter range, which is
        // ample for a straight edge and badly wrong for a circle: on a Ø10 rim
        // the samples sit ~2 mm apart, so a point ON the rim can measure up to
        // ~1 mm from the nearest one. Tolerance is 1% of the body diagonal —
        // 0.185 mm there — so most taps on a cylinder's rim were rejected as
        // "no edge near here" and the fillet silently did nothing. Measured:
        // of the first 8 rim segments only 2 resolved; at a 1 mm tolerance 7
        // did, which is the sampling gap showing through.
        Standard_Real curveFirst = 0, curveLast = 0;
        Handle(Geom_Curve) geom = BRep_Tool::Curve(edge, curveFirst, curveLast);
        for (NSUInteger k = 0; k < count; ++k) {
            const gp_Pnt target(pts[3*k], pts[3*k+1], pts[3*k+2]);
            // Endpoints first: a projection can legitimately find nothing when
            // the nearest point on the trimmed curve is an end.
            double d = std::min(curve.Value(first).Distance(target),
                                curve.Value(last).Distance(target));
            if (!geom.IsNull()) {
                try {
                    GeomAPI_ProjectPointOnCurve proj(target, geom, curveFirst, curveLast);
                    if (proj.NbPoints() > 0) d = std::min(d, (double)proj.LowerDistance());
                } catch (...) {
                    // Fall back to the endpoint distance already computed.
                }
            }
            if (d < bestDistance[k]) { bestDistance[k] = d; bestEdge[k] = i; }
        }
    }

    std::set<Standard_Integer> chosen;
    for (NSUInteger k = 0; k < count; ++k) {
        if (bestEdge[k] != 0 && bestDistance[k] <= tolerance) {
            chosen.insert(bestEdge[k]);
        }
    }
    return chosen;
}

// Keep only the edges a blend can actually be built on. Policy re-derived
// from PartDesign's dress-up edge filter (docs/FREECAD_PLAYBOOK.md F2): an
// edge must join exactly two DISTINCT faces (a seam — the vertical closure of
// a cylinder wall — has the same face on both sides and nothing to blend; a
// free edge has one), must not be degenerate (an apex "edge" has zero
// length), and must meet its faces with only C0 continuity — ChFi3d picks up
// tangent-continuous neighbours by chain propagation on its own, and adding
// one explicitly is a failure mode, not a request it honours. Handing ChFi3d
// an edge that violates any of these is how the SIGTRAP-in-`Polygon.clip`
// class of crash started upstream of here.
//
// When the filter empties the pick, `reason` gets the first rejection so the
// caller can say WHY nothing was blendable.
static std::set<Standard_Integer> OS3DBlendableEdges(
    const TopoDS_Shape &shape,
    const TopTools_IndexedMapOfShape &edgeMap,
    const std::set<Standard_Integer> &candidates,
    NSString *__strong *reason
) {
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);

    std::set<Standard_Integer> out;
    NSString *why = nil;
    for (Standard_Integer i : candidates) {
        const TopoDS_Edge edge = TopoDS::Edge(edgeMap(i));
        if (BRep_Tool::Degenerated(edge)) {
            if (why == nil) why = @"the picked edge is degenerate";
            continue;
        }
        if (!edgeFaces.Contains(edge)) {
            if (why == nil) why = @"the picked edge is not attached to a face";
            continue;
        }
        const TopTools_ListOfShape &faces = edgeFaces.FindFromKey(edge);
        if (faces.Extent() != 2) {
            if (why == nil) why = @"the picked edge does not join two faces";
            continue;
        }
        const TopoDS_Face f1 = TopoDS::Face(faces.First());
        const TopoDS_Face f2 = TopoDS::Face(faces.Last());
        if (f1.IsSame(f2)) {
            if (why == nil) why = @"the picked edge is a seam, not a boundary";
            continue;
        }
        if (BRep_Tool::Continuity(edge, f1, f2) != GeomAbs_C0) {
            if (why == nil) {
                why = @"the faces already meet smoothly here — "
                      @"blend a neighbouring sharp edge instead";
            }
            continue;
        }
        out.insert(i);
    }
    if (out.empty() && reason != NULL && *reason == nil) *reason = why;
    return out;
}

// Shared tail of the fillet and chamfer paths: count the picked edges the
// builder actually blended (via its Generated() history — the only per-edge
// success signal MakeChamfer exposes), refuse partial builds outright, then
// unwrap/validate the result. Returns nil with `status` filled on any
// failure. `faultyContours` is the fillet builder's own count (-1 when the
// builder doesn't expose one).
static OCCTShape *OS3DFinishBlend(BRepFilletAPI_LocalOperation &mk,
                                  const TopTools_IndexedMapOfShape &edgeMap,
                                  const std::set<Standard_Integer> &edges,
                                  NSInteger faultyContours,
                                  OCCTOpStatus *status) {
    const NSInteger requested = (NSInteger)edges.size();
    if (!mk.IsDone() || faultyContours > 0) {
        const NSInteger failed =
            faultyContours > 0 ? faultyContours : requested;
        OS3DSetStatus(status, OCCTOpCodePartialResult,
                      @"the size is too large for the local geometry");
        if (status != nil) {
            status.failedCount = failed;
            status.requestedCount = requested;
        }
        return nil;
    }

    // IsDone() with zero faulty contours can STILL mean an edge was quietly
    // dropped: check that every requested edge generated blend geometry.
    NSInteger blended = 0;
    for (Standard_Integer i : edges) {
        if (!mk.Generated(edgeMap(i)).IsEmpty()) ++blended;
    }
    if (blended < requested) {
        OS3DSetStatus(status, OCCTOpCodePartialResult,
                      @"the size is too large for the local geometry");
        if (status != nil) {
            status.failedCount = requested - blended;
            status.requestedCount = requested;
        }
        return nil;
    }

    int solidCount = 0;
    const TopoDS_Shape single = OS3DExtractSingleSolid(mk.Shape(), solidCount);
    if (solidCount != 1) {
        OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                      @"the blend did not produce a single solid");
        if (status != nil) status.solidCount = solidCount;
        return nil;
    }
    const TopoDS_Shape valid = OS3DHealAndValidate(single);
    if (valid.IsNull()) {
        OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                      @"the blended solid failed validity checking");
        return nil;
    }
    OS3DSetStatus(status, OCCTOpCodeOK, nil);
    OCCTShape *out = [OCCTShape new];
    out->_shape = valid;
    return out;
}

+ (nullable OCCTShape *)filletedShape:(OCCTShape *)shape
                        atWorldPoints:(NSData *)worldPoints
                               radius:(double)radius
                            tolerance:(double)tolerance
                               status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"no input");
    if (shape == nil || radius <= 0.0) return nil;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    if (count == 0) return nil;
    const double *pts = (const double *)worldPoints.bytes;

    try {
        if (!OS3DFiniteBounds(shape->_shape)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the body has empty or non-finite geometry");
            return nil;
        }
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        if (edgeMap.Extent() == 0) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                          @"the body has no edges");
            return nil;
        }

        const std::set<Standard_Integer> chosen =
            OS3DNearestEdges(edgeMap, pts, count, tolerance);
        if (chosen.empty()) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                          @"no edge within tolerance of the pick");
            return nil;
        }
        NSString *reason = nil;
        const std::set<Standard_Integer> qualified =
            OS3DBlendableEdges(shape->_shape, edgeMap, chosen, &reason);
        if (qualified.empty()) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, reason);
            return nil;
        }

        BRepFilletAPI_MakeFillet mk(shape->_shape);
        for (Standard_Integer i : qualified) {
            mk.Add(radius, TopoDS::Edge(edgeMap(i)));
        }
        mk.Build();
        return OS3DFinishBlend(mk, edgeMap, qualified,
                               mk.IsDone() ? mk.NbFaultyContours() : -1,
                               status);
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

// One fully-checked fillet attempt at `radius` on the given edges: built,
// contour-complete, per-edge generated, single-solid, analyzer-valid. The
// bisection's probe — identical checks to the committing path, so what the
// clamp says fits IS what Apply builds.
static bool OS3DFilletBuilds(const TopoDS_Shape &shape,
                             const TopTools_IndexedMapOfShape &edgeMap,
                             const std::set<Standard_Integer> &edges,
                             double radius) {
    try {
        BRepFilletAPI_MakeFillet mk(shape);
        for (Standard_Integer i : edges) {
            mk.Add(radius, TopoDS::Edge(edgeMap(i)));
        }
        mk.Build();
        if (!mk.IsDone() || mk.NbFaultyContours() > 0) return false;
        for (Standard_Integer i : edges) {
            if (mk.Generated(edgeMap(i)).IsEmpty()) return false;
        }
        int solidCount = 0;
        const TopoDS_Shape single = OS3DExtractSingleSolid(mk.Shape(), solidCount);
        if (solidCount != 1) return false;
        return BRepCheck_Analyzer(single).IsValid();
    } catch (...) {
        return false;
    }
}

+ (double)maxFilletRadiusForShape:(OCCTShape *)shape
                    atWorldPoints:(NSData *)worldPoints
                        tolerance:(double)tolerance {
    if (shape == nil) return 0.0;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    if (count == 0) return 0.0;
    const double *pts = (const double *)worldPoints.bytes;

    try {
        if (!OS3DFiniteBounds(shape->_shape)) return 0.0;
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        if (edgeMap.Extent() == 0) return 0.0;
        const std::set<Standard_Integer> chosen =
            OS3DNearestEdges(edgeMap, pts, count, tolerance);
        if (chosen.empty()) return 0.0;
        NSString *reason = nil;
        const std::set<Standard_Integer> qualified =
            OS3DBlendableEdges(shape->_shape, edgeMap, chosen, &reason);
        if (qualified.empty()) return 0.0;

        // Upper bracket: half the body diagonal, tightened by the local
        // curvature of any cylindrical/spherical face adjacent to a chosen
        // edge — a blend can never exceed the radius of the surface it eats
        // into.
        Bnd_Box bounds;
        BRepBndLib::Add(shape->_shape, bounds);
        double hi = 0.5 * sqrt(bounds.SquareExtent());
        TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
        TopExp::MapShapesAndAncestors(shape->_shape, TopAbs_EDGE, TopAbs_FACE,
                                      edgeFaces);
        for (Standard_Integer i : qualified) {
            const TopoDS_Edge edge = TopoDS::Edge(edgeMap(i));
            if (!edgeFaces.Contains(edge)) continue;
            for (TopTools_ListOfShape::Iterator it(edgeFaces.FindFromKey(edge));
                 it.More(); it.Next()) {
                BRepAdaptor_Surface surf(TopoDS::Face(it.Value()));
                if (surf.GetType() == GeomAbs_Cylinder) {
                    hi = std::min(hi, surf.Cylinder().Radius());
                } else if (surf.GetType() == GeomAbs_Sphere) {
                    hi = std::min(hi, surf.Sphere().Radius());
                }
            }
        }
        if (!(hi > 0)) return 0.0;

        // ~7-step bisection over real builds. `lo` is always a radius that
        // BUILT; a tiny probe first so a hopeless pick returns 0 fast.
        if (OS3DFilletBuilds(shape->_shape, edgeMap, qualified, hi)) return hi;
        double lo = 0.0;
        const double probe = std::min(hi * 0.01, 0.05);
        if (probe > 0 && OS3DFilletBuilds(shape->_shape, edgeMap, qualified, probe)) {
            lo = probe;
        } else {
            return 0.0;
        }
        for (int step = 0; step < 7; ++step) {
            const double mid = 0.5 * (lo + hi);
            if (OS3DFilletBuilds(shape->_shape, edgeMap, qualified, mid)) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        return lo;
    } catch (...) {
        return 0.0;
    }
}

+ (nullable OCCTShape *)chamferedShape:(OCCTShape *)shape
                        atWorldPoints:(NSData *)worldPoints
                             distance:(double)distance
                            tolerance:(double)tolerance
                                status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"no input");
    if (shape == nil || distance <= 0.0) return nil;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    if (count == 0) return nil;
    const double *pts = (const double *)worldPoints.bytes;

    try {
        if (!OS3DFiniteBounds(shape->_shape)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the body has empty or non-finite geometry");
            return nil;
        }
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        if (edgeMap.Extent() == 0) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                          @"the body has no edges");
            return nil;
        }

        // Nearest-wins, same rule as the fillet path (see OS3DNearestEdges).
        const std::set<Standard_Integer> chosen =
            OS3DNearestEdges(edgeMap, pts, count, tolerance);
        if (chosen.empty()) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                          @"no edge within tolerance of the pick");
            return nil;
        }
        NSString *reason = nil;
        const std::set<Standard_Integer> qualified =
            OS3DBlendableEdges(shape->_shape, edgeMap, chosen, &reason);
        if (qualified.empty()) {
            OS3DSetStatus(status, OCCTOpCodeNoTargetMatched, reason);
            return nil;
        }

        BRepFilletAPI_MakeChamfer mk(shape->_shape);
        for (Standard_Integer i : qualified) {
            // Symmetric chamfer: equal setback on both adjacent faces.
            mk.Add(distance, TopoDS::Edge(edgeMap(i)));
        }
        mk.Build();
        // MakeChamfer has no NbFaultyContours; the Generated() check in
        // OS3DFinishBlend is the per-edge signal.
        return OS3DFinishBlend(mk, edgeMap, qualified, -1, status);
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

// Exact volume via BRepGProp; 0 on any failure. Shared by the public
// volumeOfShape: and the shell sanity check.
static double OS3DVolume(const TopoDS_Shape &shape) {
    if (shape.IsNull()) return 0.0;
    try {
        GProp_GProps props;
        BRepGProp::VolumeProperties(shape, props);
        return props.Mass();
    } catch (...) {
        return 0.0;
    }
}

+ (nullable OCCTShape *)shelledShape:(OCCTShape *)shape
                       atWorldPoints:(NSData *)worldPoints
                           thickness:(double)thickness
                           tolerance:(double)tolerance
                              status:(nullable OCCTOpStatus *)status {
    OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"no input");
    if (shape == nil || thickness == 0.0) return nil;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    const double *pts = count > 0 ? (const double *)worldPoints.bytes : NULL;

    try {
        if (!OS3DFiniteBounds(shape->_shape)) {
            OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                          @"the body has empty or non-finite geometry");
            return nil;
        }
        // MakeThickSolid is specified for a SOLID. A body stored before
        // boolean results were normalized can still carry a one-solid
        // COMPOUND — unwrap it here so the op stays in contract.
        int inputSolids = 0;
        TopoDS_Shape input = OS3DExtractSingleSolid(shape->_shape, inputSolids);
        if (input.IsNull()) input = shape->_shape;

        // Faces to open: those with a sample within tolerance of a picked point.
        // Empty selection => fully-enclosed hollow.
        TopTools_ListOfShape openFaces;
        if (count > 0) {
            // Nearest-wins (see OS3DNearestFaces): the old rule opened every
            // face within tolerance, which on a thin plate meant picking the
            // top also opened the bottom.
            TopTools_IndexedMapOfShape faceMap;
            TopExp::MapShapes(input, TopAbs_FACE, faceMap);
            for (Standard_Integer i : OS3DNearestFaces(faceMap, pts, count, tolerance)) {
                openFaces.Append(TopoDS::Face(faceMap(i)));
            }
            // The caller ASKED for openings but nothing matched. Falling
            // through to the fully-enclosed branch silently sealed the body:
            // IsDone() passes, a valid closed hollow comes back, and the user
            // gets a shell with no opening and no diagnostic (2026-08-25
            // review round 4). Refuse instead, so the error surfaces.
            if (openFaces.IsEmpty()) {
                OS3DSetStatus(status, OCCTOpCodeNoTargetMatched,
                              @"no face within tolerance of the pick");
                return nil;
            }
        }

        TopoDS_Shape built;
        if (openFaces.IsEmpty()) {
            // Fully-enclosed hollow: offset the solid inward and SUBTRACT the
            // shrunken copy. (ByJoin with an empty closing-face list hands
            // back the original solid, and MakeThickSolidBySimple refuses a
            // closed solid outright — it never worked; the mesh fallback was
            // silently covering for it until eval stopped degrading.)
            BRepOffsetAPI_MakeOffsetShape off;
            off.PerformByJoin(input, -fabs(thickness), 1.0e-3);
            if (!off.IsDone() || off.Shape().IsNull()) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"the wall thickness is out of range for this shape");
                return nil;
            }
            int innerSolids = 0;
            TopoDS_Shape inner = OS3DExtractSingleSolid(off.Shape(), innerSolids);
            if (inner.IsNull()) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"the wall thickness is out of range for this shape");
                return nil;
            }
            BRepAlgoAPI_Cut cut(input, inner);
            if (!cut.IsDone() || cut.HasErrors()) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"hollowing failed on this shape");
                return nil;
            }
            built = cut.Shape();
        } else {
            BRepOffsetAPI_MakeThickSolid mk;
            mk.MakeThickSolidByJoin(input, openFaces, -fabs(thickness), 1.0e-3);
            if (!mk.IsDone()) {
                OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                              @"the wall thickness is out of range for this shape");
                return nil;
            }
            built = mk.Shape();
        }

        int solidCount = 0;
        TopoDS_Shape result = OS3DExtractSingleSolid(built, solidCount);
        if (result.IsNull()) result = built;
        const TopoDS_Shape valid = OS3DHealAndValidate(result);
        if (valid.IsNull()) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                          @"the shelled solid failed validity checking");
            return nil;
        }
        // A shell REMOVES material by definition. A "hollow" whose volume
        // didn't shrink is the sealed-body failure mode wearing a valid
        // topology — refuse it (docs/FREECAD_PLAYBOOK.md B2).
        const double before = OS3DVolume(input);
        const double after = OS3DVolume(valid);
        if (before > 0 && after >= before * (1.0 - 1e-9)) {
            OS3DSetStatus(status, OCCTOpCodeInvalidResult,
                          @"the shell removed no material");
            return nil;
        }

        OS3DSetStatus(status, OCCTOpCodeOK, nil);
        OCCTShape *out = [OCCTShape new];
        out->_shape = valid;
        return out;
    } catch (Standard_Failure &e) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused,
                      [NSString stringWithFormat:@"%s", e.GetMessageString()]);
        return nil;
    } catch (...) {
        OS3DSetStatus(status, OCCTOpCodeKernelRefused, @"kernel exception");
        return nil;
    }
}

+ (double)volumeOfShape:(OCCTShape *)shape {
    if (shape == nil) return 0.0;
    return OS3DVolume(shape->_shape);
}

+ (double)maxToleranceOfShape:(OCCTShape *)shape {
    if (shape == nil || shape->_shape.IsNull()) return 0.0;
    try {
        ShapeAnalysis_ShapeTolerance analysis;
        // mode > 0 = the MAXIMAL tolerance any sub-shape carries.
        return analysis.Tolerance(shape->_shape, 1);
    } catch (...) {
        return 0.0;
    }
}

+ (BOOL)writeSTEPShapes:(NSArray<OCCTShape *> *)shapes toPath:(NSString *)path {
    if (shapes.count == 0 || path.length == 0) return NO;
    try {
        STEPControl_Writer writer;
        for (OCCTShape *s in shapes) {
            if (s == nil || s->_shape.IsNull()) continue;
            if (writer.Transfer(s->_shape, STEPControl_AsIs) != IFSelect_RetDone) return NO;
        }
        return writer.Write(path.fileSystemRepresentation) == IFSelect_RetDone;
    } catch (...) {
        return NO;
    }
}

+ (NSArray<OCCTShape *> *)readSTEPFromPath:(NSString *)path {
    NSMutableArray<OCCTShape *> *out = [NSMutableArray array];
    if (path.length == 0) return out;
    try {
        STEPControl_Reader reader;
        if (reader.ReadFile(path.fileSystemRepresentation) != IFSelect_RetDone) return out;
        reader.TransferRoots();
        // Imported geometry is a TRUST BOUNDARY: heal-and-validate each
        // solid on the way in (one ShapeFix pass — FreeCAD heals at import
        // too, docs/FREECAD_PLAYBOOK.md H1) and DROP what still doesn't
        // validate, so a dirty export can't seed a body every later op
        // chokes on.
        const auto append = [out](const TopoDS_Shape &candidate) {
            if (!OS3DFiniteBounds(candidate)) return;
            const TopoDS_Shape valid = OS3DHealAndValidate(candidate);
            if (valid.IsNull()) return;
            OCCTShape *w = [OCCTShape new];
            w->_shape = valid;
            [out addObject:w];
        };
        for (Standard_Integer i = 1; i <= reader.NbShapes(); ++i) {
            const TopoDS_Shape shape = reader.Shape(i);
            if (shape.IsNull()) continue;
            // A STEP root can be a compound; emit each solid separately so each
            // becomes its own body.
            TopExp_Explorer solids(shape, TopAbs_SOLID);
            if (solids.More()) {
                for (; solids.More(); solids.Next()) append(solids.Current());
            } else {
                append(shape);
            }
        }
    } catch (...) {
        return [NSMutableArray array];
    }
    return out;
}

+ (nullable NSData *)serializedShape:(OCCTShape *)shape {
    if (shape == nil) return nil;
    try {
        // No triangulation in the blob (the mesh is derived state, re-built
        // on load — persisting it bloated every save), and the format
        // version PINNED so stored documents don't silently change format
        // when the linked OCCT is upgraded (review R4-O5,
        // docs/FREECAD_PLAYBOOK.md P1).
        std::ostringstream os;
        BRepTools::Write(shape->_shape, os,
                         /*withTriangles*/ Standard_False,
                         /*withNormals*/ Standard_False,
                         TopTools_FormatVersion_VERSION_2);
        const std::string s = os.str();
        if (s.empty()) return nil;
        return [NSData dataWithBytes:s.data() length:s.size()];
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)shapeFromSerialized:(NSData *)data {
    if (data.length == 0) return nil;
    try {
        std::istringstream is(std::string((const char *)data.bytes, data.length));
        TopoDS_Shape shape;
        BRep_Builder builder;
        // A stored blob is a TRUST BOUNDARY (docs/FREECAD_PLAYBOOK.md H1):
        // fuzzing proved a few flipped bytes can parse into a shape that
        // hangs the mesher or quietly carries invalid topology into every
        // downstream op. Deadline the read, then gate on finite bounds and
        // validity (with one heal attempt). A refused blob degrades to the
        // persisted render mesh — the documented fallback — not a crash.
        OS3DDeadlineProgress *deadline =
            new OS3DDeadlineProgress(kOS3DKernelDeadlineSeconds);
        Handle(Message_ProgressIndicator) progress(deadline);
        BRepTools::Read(shape, is, builder, progress->Start());
        if (deadline->Fired() || shape.IsNull()) return nil;
        if (!OS3DFiniteBounds(shape)) return nil;
        const TopoDS_Shape valid = OS3DHealAndValidate(shape);
        if (valid.IsNull()) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = valid;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (OCCTRenderMesh *)renderMeshFromShape:(OCCTShape *)shape
                       angularDeflection:(double)angularDeflection
                        linearDeflection:(double)linearDeflection {
    return TessellateShape(shape->_shape, linearDeflection, angularDeflection);
}

@end
