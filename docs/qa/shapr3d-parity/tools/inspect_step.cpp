// occt_inspect — the independent ruler for the import QA pipeline.
//
// Reads a STEP, STL or BREP file with the repository's own OCCT (public APIs,
// no app code) and prints one JSON object: solid count, exact volume,
// centre of mass, tight bounds, face classes, BRepCheck validity and
// tolerance. With --ref it also measures the DEVIATION of the file from a
// reference: the volume of (ref − actual) and (actual − ref) by boolean cut,
// and a sampled bidirectional surface distance (labelled an estimate, with
// the deflection that produced it), as docs/qa/shapr3d-parity/TEST_PLAN.md §3
// asks for.
//
// Build (see tools/README.md for why the Catalyst slice and the plain exit):
//   xcrun -sdk macosx clang++ -target arm64-apple-ios17.0-macabi -std=c++17 -O1 \
//     -I ThirdParty/OCCT.xcframework/ios-arm64/Headers \
//     docs/qa/shapr3d-parity/tools/inspect_step.cpp \
//     ThirdParty/OCCT.xcframework/ios-arm64-maccatalyst/libOCCT-MAC_CATALYST_ARM64.a \
//     -o build/qa/occt_inspect
//
// Usage: occt_inspect <file> [--ref <reference>] [--deflection 0.02] [--samples 1500] [--no-boolean]
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeSolid.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepBuilderAPI_Sewing.hxx>
#include <BRepClass3d_SolidClassifier.hxx>
#include <Precision.hxx>
#include <ShapeFix_Shape.hxx>
#include <TopExp.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopoDS_Shell.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepGProp.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepTools.hxx>
#include <BRep_Builder.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <Poly_Triangulation.hxx>
#include <RWStl.hxx>
#include <STEPControl_Reader.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <Message_PrinterOStream.hxx>
#include <IGESControl_Controller.hxx>
#include <IGESControl_Reader.hxx>
#include <ShapeAnalysis_ShapeTolerance.hxx>
#include <Standard_Version.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <TopoDS_Solid.hxx>
#include <gp_Pnt.hxx>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <unistd.h>
#include <vector>

using S = TopoDS_Shape;

static std::string lower(std::string s) { for (auto& c : s) c = (char)std::tolower(c); return s; }
static bool endsWith(const std::string& s, const std::string& suf) {
  return s.size() >= suf.size() && s.compare(s.size() - suf.size(), suf.size(), suf) == 0;
}

// --- reading -----------------------------------------------------------------

static S readAny(const std::string& path, std::string& error, int& roots) {
  roots = 0;
  const std::string p = lower(path);
  if (endsWith(p, ".step") || endsWith(p, ".stp")) {
    STEPControl_Reader reader;
    if (reader.ReadFile(path.c_str()) != IFSelect_RetDone) { error = "STEP read failed"; return S(); }
    roots = reader.TransferRoots();
    if (reader.NbShapes() == 0) { error = "STEP carries no shapes"; return S(); }
    return reader.OneShape();
  }
  if (endsWith(p, ".igs") || endsWith(p, ".iges")) {
    IGESControl_Controller::Init();
    IGESControl_Reader reader;
    if (reader.ReadFile(path.c_str()) != IFSelect_RetDone) { error = "IGES read failed"; return S(); }
    roots = reader.TransferRoots();
    if (reader.NbShapes() == 0) { error = "IGES carries no shapes"; return S(); }
    return reader.OneShape();
  }
  if (endsWith(p, ".stl")) {
    Handle(Poly_Triangulation) tri = RWStl::ReadFile(path.c_str());
    if (tri.IsNull()) { error = "STL read failed"; return S(); }
    TopoDS_Face face; BRep_Builder b; b.MakeFace(face); b.UpdateFace(face, tri);
    roots = 1;
    return face;
  }
  if (endsWith(p, ".brep")) {
    S shape; BRep_Builder b;
    if (!BRepTools::Read(shape, path.c_str(), b)) { error = "BREP read failed"; return S(); }
    roots = 1;
    return shape;
  }
  error = "unsupported extension";
  return S();
}

// --- what an importer can make of the file ------------------------------------

// Declared solids pass through; faces outside any solid are sewn (1e-3 mm,
// as the app does) and each closed shell becomes an oriented solid, each
// open one a sheet. Every piece is healed and validated the way the app's
// reader does it — one ShapeFix pass, then BRepCheck, and what still fails
// is dropped — and a sheet that fails as a whole is retried face by face so
// one bad face does not take the rest with it. The result is the
// "importable" shape every metric is measured on: a surface-modelled part
// is held to the solid it should become, not to "zero solids".
struct SewStats { int rawSolids = 0, freeFaces = 0, sewnSolids = 0, openShells = 0, dropped = 0; };

static S healed(const S& s) {
  if (BRepCheck_Analyzer(s).IsValid()) return s;
  Handle(ShapeFix_Shape) fixer = new ShapeFix_Shape(s);
  fixer->Perform();
  const S fixed = fixer->Shape();
  if (!fixed.IsNull() && BRepCheck_Analyzer(fixed).IsValid()) return fixed;
  return S();
}

static S importable(const S& shape, SewStats& st) {
  TopoDS_Compound out; BRep_Builder b; b.MakeCompound(out);
  const auto admit = [&](const S& piece) -> bool {
    const S ok = healed(piece);
    if (ok.IsNull()) { ++st.dropped; return false; }
    b.Add(out, ok);
    return true;
  };
  const auto admitSheet = [&](const S& sheet) {
    if (admit(sheet)) { ++st.openShells; return; }
    --st.dropped;   // retried face by face
    BRepBuilderAPI_Sewing resew(1e-3);
    int kept = 0;
    for (TopExp_Explorer f(sheet, TopAbs_FACE); f.More(); f.Next()) {
      if (BRepCheck_Analyzer(f.Current()).IsValid()) { resew.Add(f.Current()); ++kept; }
      else ++st.dropped;
    }
    if (kept == 0) return;
    resew.Perform();
    const S pieces = resew.SewedShape();
    TopTools_IndexedMapOfShape inPieces;
    for (TopExp_Explorer sh(pieces, TopAbs_SHELL); sh.More(); sh.Next()) {
      TopExp::MapShapes(sh.Current(), TopAbs_FACE, inPieces);
      if (admit(sh.Current())) ++st.openShells;
    }
    for (TopExp_Explorer f(pieces, TopAbs_FACE); f.More(); f.Next()) {
      if (inPieces.Contains(f.Current())) continue;
      if (admit(f.Current())) ++st.openShells;
    }
  };

  TopTools_IndexedMapOfShape inSolids;
  for (TopExp_Explorer e(shape, TopAbs_SOLID); e.More(); e.Next()) {
    if (admit(e.Current())) ++st.rawSolids;
    TopExp::MapShapes(e.Current(), TopAbs_FACE, inSolids);
  }
  BRepBuilderAPI_Sewing sewing(1e-3);
  for (TopExp_Explorer e(shape, TopAbs_FACE); e.More(); e.Next()) {
    if (inSolids.Contains(e.Current())) continue;
    sewing.Add(e.Current()); ++st.freeFaces;
  }
  if (st.freeFaces == 0) return out;
  sewing.Perform();
  const S sewed = sewing.SewedShape();
  TopTools_IndexedMapOfShape inShells;
  for (TopExp_Explorer e(sewed, TopAbs_SHELL); e.More(); e.Next()) {
    const TopoDS_Shell shell = TopoDS::Shell(e.Current());
    TopExp::MapShapes(shell, TopAbs_FACE, inShells);
    if (BRep_Tool::IsClosed(shell)) {
      BRepBuilderAPI_MakeSolid maker(shell);
      if (maker.IsDone()) {
        TopoDS_Solid solid = maker.Solid();
        BRepClass3d_SolidClassifier classifier(solid);
        classifier.PerformInfinitePoint(Precision::Confusion());
        if (classifier.State() == TopAbs_IN) solid.Reverse();
        if (admit(solid)) { ++st.sewnSolids; continue; }
        --st.dropped;   // its faces may still stand as a sheet
      }
    }
    admitSheet(shell);
  }
  for (TopExp_Explorer e(sewed, TopAbs_FACE); e.More(); e.Next()) {
    if (inShells.Contains(e.Current())) continue;
    if (admit(e.Current())) ++st.openShells;
  }
  return out;
}

// --- metrics -----------------------------------------------------------------

struct FaceClasses { int planar = 0, cylindrical = 0, conical = 0, spherical = 0, toroidal = 0, bspline = 0, other = 0, total = 0; };

static FaceClasses classify(const S& s) {
  FaceClasses c;
  for (TopExp_Explorer ex(s, TopAbs_FACE); ex.More(); ex.Next()) {
    ++c.total;
    BRepAdaptor_Surface surf(TopoDS::Face(ex.Current()), Standard_False);
    switch (surf.GetType()) {
      case GeomAbs_Plane: ++c.planar; break;
      case GeomAbs_Cylinder: ++c.cylindrical; break;
      case GeomAbs_Cone: ++c.conical; break;
      case GeomAbs_Sphere: ++c.spherical; break;
      case GeomAbs_Torus: ++c.toroidal; break;
      case GeomAbs_BezierSurface: case GeomAbs_BSplineSurface: ++c.bspline; break;
      default: ++c.other; break;
    }
  }
  return c;
}

static int countSolids(const S& s) { int n = 0; for (TopExp_Explorer e(s, TopAbs_SOLID); e.More(); e.Next()) ++n; return n; }

// Volume and centre of mass. A mesh-only shape (an STL face) has no solid:
// integrate the triangulation instead (divergence theorem), which is exact
// for a closed, consistently oriented mesh.
static bool meshVolume(const S& s, double& volume, gp_Pnt& centroid) {
  double v = 0, cx = 0, cy = 0, cz = 0; bool any = false;
  for (TopExp_Explorer ex(s, TopAbs_FACE); ex.More(); ex.Next()) {
    TopLoc_Location loc;
    Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), loc);
    if (tri.IsNull()) continue;
    any = true;
    const gp_Trsf t = loc.Transformation();
    for (Standard_Integer i = 1; i <= tri->NbTriangles(); ++i) {
      Standard_Integer a, b, c; tri->Triangle(i).Get(a, b, c);
      gp_Pnt pa = tri->Node(a).Transformed(t), pb = tri->Node(b).Transformed(t), pc = tri->Node(c).Transformed(t);
      // Signed volume of the tetrahedron (origin, a, b, c).
      const double det = pa.X() * (pb.Y() * pc.Z() - pb.Z() * pc.Y())
                       - pa.Y() * (pb.X() * pc.Z() - pb.Z() * pc.X())
                       + pa.Z() * (pb.X() * pc.Y() - pb.Y() * pc.X());
      const double tv = det / 6.0;
      v += tv;
      cx += tv * (pa.X() + pb.X() + pc.X()) / 4.0;
      cy += tv * (pa.Y() + pb.Y() + pc.Y()) / 4.0;
      cz += tv * (pa.Z() + pb.Z() + pc.Z()) / 4.0;
    }
  }
  if (!any) return false;
  volume = v;
  centroid = std::abs(v) > 1e-12 ? gp_Pnt(cx / v, cy / v, cz / v) : gp_Pnt(0, 0, 0);
  return true;
}

static double solidVolume(const S& s, gp_Pnt& centroid) {
  GProp_GProps g; BRepGProp::VolumeProperties(s, g, 1e-9);
  centroid = g.CentreOfMass();
  return g.Mass();
}

static void tightBounds(const S& s, double out[6], bool mesh) {
  Bnd_Box box;
  if (mesh) BRepBndLib::Add(s, box, Standard_True);
  else BRepBndLib::AddOptimal(s, box, Standard_False, Standard_False);
  if (box.IsVoid()) { for (int i = 0; i < 6; ++i) out[i] = 0; return; }
  box.Get(out[0], out[1], out[2], out[3], out[4], out[5]);
}

static std::string num(double v) {
  if (!std::isfinite(v)) return "null";
  std::ostringstream o; o << std::setprecision(15) << v; return o.str();
}
static std::string arr3(double a, double b, double c) { return "[" + num(a) + "," + num(b) + "," + num(c) + "]"; }
static std::string jsonStr(const std::string& s) {
  std::string o = "\"";
  for (char c : s) { if (c == '"' || c == '\\') { o += '\\'; o += c; } else if (c == '\n') o += "\\n"; else o += c; }
  return o + "\"";
}

struct Metrics {
  bool mesh = false; int solids = 0; double volume = 0; gp_Pnt centroid; double bounds[6];
  FaceClasses faces; bool valid = false; double tolMin = 0, tolAvg = 0, tolMax = 0;
  std::vector<std::string> perSolid;
};

static S solidsOf(const S& s);

static Metrics measure(const S& shape, bool meshFile) {
  Metrics m;
  m.solids = countSolids(shape);
  m.mesh = meshFile;
  if (m.mesh) {
    double v = 0; gp_Pnt c;
    if (meshVolume(shape, v, c)) { m.volume = v; m.centroid = c; }
  } else if (m.solids == 0) {
    m.volume = 0;                       // a sheet encloses nothing
  } else {
    m.volume = solidVolume(solidsOf(shape), m.centroid);
    for (TopExp_Explorer e(shape, TopAbs_SOLID); e.More(); e.Next()) {
      gp_Pnt c; const double v = solidVolume(e.Current(), c); double b[6]; tightBounds(e.Current(), b, false);
      FaceClasses fc = classify(e.Current());
      m.perSolid.push_back("{\"volume\":" + num(v) + ",\"centroid\":" + arr3(c.X(), c.Y(), c.Z())
        + ",\"bounds\":{\"min\":" + arr3(b[0], b[1], b[2]) + ",\"max\":" + arr3(b[3], b[4], b[5]) + "}"
        + ",\"faces\":" + std::to_string(fc.total) + ",\"planar\":" + std::to_string(fc.planar)
        + ",\"cylindrical\":" + std::to_string(fc.cylindrical) + "}");
    }
  }
  tightBounds(shape, m.bounds, m.mesh);
  m.faces = classify(shape);
  m.valid = BRepCheck_Analyzer(shape).IsValid();
  ShapeAnalysis_ShapeTolerance tol;
  m.tolMin = tol.Tolerance(shape, -1); m.tolAvg = tol.Tolerance(shape, 0); m.tolMax = tol.Tolerance(shape, 1);
  return m;
}

static std::string facesJSON(const FaceClasses& f) {
  return "{\"total\":" + std::to_string(f.total) + ",\"planar\":" + std::to_string(f.planar)
    + ",\"cylindrical\":" + std::to_string(f.cylindrical) + ",\"conical\":" + std::to_string(f.conical)
    + ",\"spherical\":" + std::to_string(f.spherical) + ",\"toroidal\":" + std::to_string(f.toroidal)
    + ",\"bspline\":" + std::to_string(f.bspline) + ",\"other\":" + std::to_string(f.other) + "}";
}

static std::string metricsJSON(const Metrics& m) {
  std::string o = "{\"mesh\":" + std::string(m.mesh ? "true" : "false")
    + ",\"solids\":" + std::to_string(m.solids)
    + ",\"volume\":" + num(m.volume)
    + ",\"centroid\":" + arr3(m.centroid.X(), m.centroid.Y(), m.centroid.Z())
    + ",\"bounds\":{\"min\":" + arr3(m.bounds[0], m.bounds[1], m.bounds[2]) + ",\"max\":" + arr3(m.bounds[3], m.bounds[4], m.bounds[5]) + "}"
    + ",\"faces\":" + facesJSON(m.faces)
    + ",\"valid\":" + (m.valid ? "true" : "false")
    + ",\"tolerance\":{\"min\":" + num(m.tolMin) + ",\"avg\":" + num(m.tolAvg) + ",\"max\":" + num(m.tolMax) + "}"
    + ",\"perSolid\":[";
  for (size_t i = 0; i < m.perSolid.size(); ++i) o += (i ? "," : "") + m.perSolid[i];
  return o + "]}";
}

// --- deviation ---------------------------------------------------------------

static S solidsOf(const S& s) {
  TopoDS_Compound c; BRep_Builder b; b.MakeCompound(c);
  for (TopExp_Explorer e(s, TopAbs_SOLID); e.More(); e.Next()) b.Add(c, e.Current());
  return c;
}

static bool cutVolume(const S& a, const S& b, double& volume) {
  TopTools_ListOfShape args, tools; args.Append(a); tools.Append(b);
  BRepAlgoAPI_Cut op; op.SetArguments(args); op.SetTools(tools); op.SetRunParallel(Standard_False);
  op.Build();
  if (!op.IsDone() || op.HasErrors()) return false;
  gp_Pnt c; volume = std::abs(solidVolume(op.Shape(), c));
  return true;
}

// Sample the triangulation nodes of `from` (meshed at `deflection`) and
// measure each one's distance to `to`. The maximum is a LOWER bound on the
// true one-sided surface distance, which is why the report calls it an
// estimate and prints the deflection.
static double sampledDistance(const S& from, const S& to, double deflection, int maxSamples, int& used) {
  BRepMesh_IncrementalMesh mesher(from, deflection, Standard_False, 0.3, Standard_True);
  std::vector<gp_Pnt> points;
  for (TopExp_Explorer ex(from, TopAbs_FACE); ex.More(); ex.Next()) {
    TopLoc_Location loc;
    Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(TopoDS::Face(ex.Current()), loc);
    if (tri.IsNull()) continue;
    const gp_Trsf t = loc.Transformation();
    for (Standard_Integer i = 1; i <= tri->NbNodes(); ++i) points.push_back(tri->Node(i).Transformed(t));
  }
  // Even subsample so the budget covers the whole shape, not its first faces.
  const size_t stride = points.size() > (size_t)maxSamples ? (points.size() + maxSamples - 1) / maxSamples : 1;
  double worst = 0; used = 0;
  for (size_t i = 0; i < points.size(); i += stride) {
    BRepExtrema_DistShapeShape d(BRepBuilderAPI_MakeVertex(points[i]).Vertex(), to);
    if (!d.IsDone() || d.NbSolution() == 0) continue;
    worst = std::max(worst, d.Value()); ++used;
  }
  return worst;
}

int main(int argc, char** argv) {
  // OCCT's readers chat on stdout ("Total number of loaded entities 49.",
  // in colour); stdout is the JSON, so drop the default printer.
  Message::DefaultMessenger()->RemovePrinters(STANDARD_TYPE(Message_PrinterOStream));
  if (argc < 2) { std::fprintf(stderr, "usage: occt_inspect <file> [--ref <reference>] [--deflection 0.02] [--samples 1500] [--no-boolean]\n"); std::_Exit(2); }
  std::string path = argv[1], ref; double deflection = 0.02; int samples = 1500; bool doBoolean = true;
  for (int i = 2; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--ref" && i + 1 < argc) ref = argv[++i];
    else if (a == "--deflection" && i + 1 < argc) deflection = std::atof(argv[++i]);
    else if (a == "--samples" && i + 1 < argc) samples = std::atoi(argv[++i]);
    else if (a == "--no-boolean") doBoolean = false;
  }

  const auto isMesh = [](const std::string& p) { return endsWith(lower(p), ".stl"); };
  const auto sewJSON = [](const SewStats& st) {
    return "{\"rawSolids\":" + std::to_string(st.rawSolids) + ",\"freeFaces\":" + std::to_string(st.freeFaces)
      + ",\"sewnSolids\":" + std::to_string(st.sewnSolids) + ",\"openShells\":" + std::to_string(st.openShells)
      + ",\"dropped\":" + std::to_string(st.dropped) + "}";
  };

  std::string out = "{\"occt\":\"" OCC_VERSION_COMPLETE "\",\"file\":" + jsonStr(path);
  std::string error; int roots = 0;
  S shape = readAny(path, error, roots);
  if (shape.IsNull()) {
    out += ",\"readOK\":false,\"error\":" + jsonStr(error) + "}";
    std::cout << out << std::endl; std::_Exit(0);
  }
  SewStats st;
  if (!isMesh(path)) shape = importable(shape, st);
  Metrics m = measure(shape, isMesh(path));
  out += ",\"readOK\":true,\"roots\":" + std::to_string(roots) + ",\"sewing\":" + sewJSON(st) + ",\"metrics\":" + metricsJSON(m);

  if (!ref.empty()) {
    std::string rerr; int rroots = 0;
    S rshape = readAny(ref, rerr, rroots);
    if (rshape.IsNull()) {
      out += ",\"reference\":{\"readOK\":false,\"error\":" + jsonStr(rerr) + "}";
    } else {
      SewStats rst;
      if (!isMesh(ref)) rshape = importable(rshape, rst);
      Metrics r = measure(rshape, isMesh(ref));
      out += ",\"reference\":{\"readOK\":true,\"file\":" + jsonStr(ref) + ",\"sewing\":" + sewJSON(rst) + ",\"metrics\":" + metricsJSON(r) + "}";
      std::string dev = "{";
      dev += "\"volumeError\":" + num(m.volume - r.volume)
        + ",\"centroidError\":" + arr3(m.centroid.X() - r.centroid.X(), m.centroid.Y() - r.centroid.Y(), m.centroid.Z() - r.centroid.Z());
      double bmax = 0; for (int i = 0; i < 6; ++i) bmax = std::max(bmax, std::abs(m.bounds[i] - r.bounds[i]));
      dev += ",\"boundsMaxError\":" + num(bmax);
      if (!m.mesh && !r.mesh) {
        if (doBoolean) {
          double rma = 0, amr = 0;
          const bool ok1 = cutVolume(solidsOf(rshape), solidsOf(shape), rma);
          const bool ok2 = cutVolume(solidsOf(shape), solidsOf(rshape), amr);
          dev += ",\"booleanOK\":" + std::string(ok1 && ok2 ? "true" : "false");
          if (ok1 && ok2) {
            const double denom = std::max(std::abs(m.volume), std::abs(r.volume));
            dev += ",\"refMinusActual\":" + num(rma) + ",\"actualMinusRef\":" + num(amr)
              + ",\"symmetricRatio\":" + num(denom > 0 ? (rma + amr) / denom : 0);
          }
        }
        int u1 = 0, u2 = 0;
        const double d1 = sampledDistance(shape, rshape, deflection, samples, u1);
        const double d2 = sampledDistance(rshape, shape, deflection, samples, u2);
        dev += ",\"surfaceDistance\":{\"actualToRef\":" + num(d1) + ",\"refToActual\":" + num(d2)
          + ",\"max\":" + num(std::max(d1, d2)) + ",\"samples\":[" + std::to_string(u1) + "," + std::to_string(u2) + "]"
          + ",\"deflection\":" + num(deflection) + ",\"estimate\":true}";
      }
      dev += "}";
      out += ",\"deviation\":" + dev;
    }
  }
  out += "}";
  std::cout << out << std::endl;
  std::cout.flush();
  // The Catalyst static library crashes in global teardown outside a UIKit
  // host (tools/README.md); everything is written, so leave without it.
  std::_Exit(0);
}
