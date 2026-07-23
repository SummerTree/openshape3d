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
#include <cstdint>
#include <sstream>
#include <string>

#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepAlgoAPI_Defeaturing.hxx>
#include <TopTools_ListOfShape.hxx>
#include <BRepAdaptor_Curve.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedMapOfShape.hxx>

#include <Standard_Version.hxx>

#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
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
#include <gp_Dir.hxx>
#include <gp_Pnt.hxx>
#include <gp_Vec.hxx>
#include <gp_Trsf.hxx>
#include <BRepBuilderAPI_MakePolygon.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Common.hxx>

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

@interface OCCTRenderMesh () {
@public
    NSInteger _vertexCount;
    NSInteger _triangleCount;
    NSData *_positions;
    NSData *_normals;
    NSData *_indices;
}
@end

// Tessellate a shape and extract SMOOTH per-vertex normals from each face's
// analytic surface. Shared by the cylinder and general-shape render paths.
static OCCTRenderMesh *TessellateShape(const TopoDS_Shape &solid,
                                       double linearDeflection,
                                       double angularDeflection) {
    BRepMesh_IncrementalMesh mesher(solid, linearDeflection, Standard_False,
                                    angularDeflection, Standard_True);
    mesher.Perform();

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

+ (nullable OCCTShape *)extrudedShapeWithOuterLoop:(NSData *)outerLoop
                                          isCircle:(BOOL)isCircle
                                     circleCenterX:(double)ccx
                                     circleCenterY:(double)ccy
                                      circleRadius:(double)cr
                                             holes:(NSArray<NSData *> *)holes
                                              zMin:(double)zMin
                                              zMax:(double)zMax
                                             basis:(OCCTPlaneBasis *)basis {
    const double height = zMax - zMin;
    if (height <= 1e-9) return nil;
    try {
        // Outer face on the z=zMin plane (analytic circle when applicable).
        TopoDS_Wire outerWire;
        if (isCircle) {
            gp_Ax2 ax(gp_Pnt(ccx, ccy, zMin), gp_Dir(0.0, 0.0, 1.0));
            outerWire = BRepBuilderAPI_MakeWire(
                BRepBuilderAPI_MakeEdge(gp_Circ(ax, cr)).Edge()).Wire();
        } else {
            if (outerLoop.length < 3 * 2 * (NSInteger)sizeof(double)) return nil;
            outerWire = PolyWire(outerLoop, zMin);
        }
        BRepBuilderAPI_MakeFace mf(outerWire, Standard_True);
        for (NSData *hole in holes) {
            if (hole.length < 3 * 2 * (NSInteger)sizeof(double)) continue;
            TopoDS_Wire hw = PolyWire(hole, zMin);
            hw.Reverse();  // inner boundary opposes the outer sense
            mf.Add(hw);
        }
        if (!mf.IsDone()) return nil;

        TopoDS_Shape solid = BRepPrimAPI_MakePrism(mf.Face(),
                                                   gp_Vec(0.0, 0.0, height)).Shape();

        // Map plane-local → world: columns of the rotation are the basis axes.
        gp_Trsf t;
        t.SetValues(basis->_x[0], basis->_y[0], basis->_n[0], basis->_o[0],
                    basis->_x[1], basis->_y[1], basis->_n[1], basis->_o[1],
                    basis->_x[2], basis->_y[2], basis->_n[2], basis->_o[2]);
        TopoDS_Shape world = BRepBuilderAPI_Transform(solid, t, Standard_True).Shape();

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

+ (nullable OCCTShape *)booleanOfShape:(OCCTShape *)a
                             withShape:(OCCTShape *)b
                                    op:(NSInteger)op {
    if (a == nil || b == nil) return nil;
    try {
        TopoDS_Shape result;
        switch (op) {
            case 0: result = BRepAlgoAPI_Fuse(a->_shape, b->_shape).Shape(); break;
            case 1: result = BRepAlgoAPI_Cut(a->_shape, b->_shape).Shape(); break;
            default: result = BRepAlgoAPI_Common(a->_shape, b->_shape).Shape(); break;
        }
        if (result.IsNull()) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = result;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (nullable OCCTShape *)defeaturedShape:(OCCTShape *)shape
                                 atWorldPoints:(NSData *)worldPoints
                                     tolerance:(double)tolerance {
    if (shape == nil) return nil;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    if (count == 0) return nil;
    const double *pts = (const double *)worldPoints.bytes;

    try {
        TopTools_ListOfShape toRemove;
        for (TopExp_Explorer ex(shape->_shape, TopAbs_FACE); ex.More(); ex.Next()) {
            const TopoDS_Face face = TopoDS::Face(ex.Current());
            BRepAdaptor_Surface surf(face);
            const double u0 = surf.FirstUParameter(), u1 = surf.LastUParameter();
            const double v0 = surf.FirstVParameter(), v1 = surf.LastVParameter();
            bool hit = false;
            const int S = 4;
            for (int i = 0; i <= S && !hit; ++i) {
                for (int j = 0; j <= S && !hit; ++j) {
                    const gp_Pnt q = surf.Value(u0 + (u1 - u0) * i / (double)S,
                                                v0 + (v1 - v0) * j / (double)S);
                    for (NSUInteger k = 0; k < count; ++k) {
                        const gp_Pnt t(pts[3*k], pts[3*k+1], pts[3*k+2]);
                        if (q.Distance(t) <= tolerance) { hit = true; break; }
                    }
                }
            }
            if (hit) toRemove.Append(face);
        }
        if (toRemove.IsEmpty()) return nil;

        BRepAlgoAPI_Defeaturing defeat;
        defeat.SetShape(shape->_shape);
        defeat.AddFacesToRemove(toRemove);
        defeat.Build();
        if (!defeat.IsDone()) return nil;
        const TopoDS_Shape result = defeat.Shape();
        if (result.IsNull()) return nil;

        OCCTShape *out = [OCCTShape new];
        out->_shape = result;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (OCCTFaceTypeCounts *)faceTypeCountsOfShape:(OCCTShape *)shape {
    NSInteger planar = 0, cyl = 0, other = 0;
    if (shape != nil) {
        for (TopExp_Explorer ex(shape->_shape, TopAbs_FACE); ex.More(); ex.Next()) {
            BRepAdaptor_Surface surf(TopoDS::Face(ex.Current()));
            switch (surf.GetType()) {
                case GeomAbs_Plane: planar++; break;
                case GeomAbs_Cylinder: cyl++; break;
                default: other++; break;
            }
        }
    }
    OCCTFaceTypeCounts *counts = [OCCTFaceTypeCounts new];
    counts->_planar = planar;
    counts->_cylindrical = cyl;
    counts->_other = other;
    return counts;
}

+ (nullable OCCTShape *)filletedShape:(OCCTShape *)shape
                        atWorldPoints:(NSData *)worldPoints
                               radius:(double)radius
                            tolerance:(double)tolerance {
    if (shape == nil || radius <= 0.0) return nil;
    const NSUInteger count = worldPoints.length / (3 * sizeof(double));
    if (count == 0) return nil;
    const double *pts = (const double *)worldPoints.bytes;

    try {
        TopTools_IndexedMapOfShape edgeMap;
        TopExp::MapShapes(shape->_shape, TopAbs_EDGE, edgeMap);
        if (edgeMap.Extent() == 0) return nil;

        BRepFilletAPI_MakeFillet mk(shape->_shape);
        int added = 0;

        for (Standard_Integer i = 1; i <= edgeMap.Extent(); ++i) {
            const TopoDS_Edge edge = TopoDS::Edge(edgeMap(i));
            if (BRep_Tool::Degenerated(edge)) continue;

            BRepAdaptor_Curve curve(edge);
            const double first = curve.FirstParameter();
            const double last = curve.LastParameter();
            const int samples = 16;
            bool hit = false;

            for (int s = 0; s <= samples && !hit; ++s) {
                const gp_Pnt q = curve.Value(first + (last - first) * (double)s / (double)samples);
                for (NSUInteger k = 0; k < count; ++k) {
                    const gp_Pnt target(pts[3*k], pts[3*k+1], pts[3*k+2]);
                    if (q.Distance(target) <= tolerance) { hit = true; break; }
                }
            }
            if (hit) { mk.Add(radius, edge); ++added; }
        }
        if (added == 0) return nil;

        mk.Build();
        if (!mk.IsDone()) return nil;
        const TopoDS_Shape result = mk.Shape();
        if (result.IsNull()) return nil;

        OCCTShape *out = [OCCTShape new];
        out->_shape = result;
        return out;
    } catch (...) {
        return nil;
    }
}

+ (nullable NSData *)serializedShape:(OCCTShape *)shape {
    if (shape == nil) return nil;
    try {
        std::ostringstream os;
        BRepTools::Write(shape->_shape, os);
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
        BRepTools::Read(shape, is, builder);
        if (shape.IsNull()) return nil;
        OCCTShape *out = [OCCTShape new];
        out->_shape = shape;
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
