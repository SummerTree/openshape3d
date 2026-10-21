// Original synthetic STEP fixtures for the surface-model import cases the
// first pass of the test pack did not cover (found by the FreeCAD IDF
// corpus on 2026-10-21): a part written as a SHELL rather than a solid, a
// solid beside a loose closed shell, and a sheet that does not close. Public
// OCCT APIs only, no app code; same build recipe as generate_fixtures.cpp.
//
//   M17_shell_only_box.step        40×30×10 box as a closed shell, no SOLID entity
//   M18_solid_and_free_shell.step  a 10 mm cube solid + a second cube as a loose shell
//   M19_open_sheet.step            five faces of a 10 mm cube — an open sheet
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRep_Builder.hxx>
#include <STEPControl_Writer.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Shell.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <cstdlib>
#include <iostream>
#include <string>

static TopoDS_Shell shellOf(const TopoDS_Shape& solid) {
  TopExp_Explorer ex(solid, TopAbs_SHELL);
  return TopoDS::Shell(ex.Current());
}

static bool write(const TopoDS_Shape& shape, const std::string& path) {
  STEPControl_Writer writer;
  if (writer.Transfer(shape, STEPControl_AsIs) != IFSelect_RetDone) return false;
  return writer.Write(path.c_str()) == IFSelect_RetDone;
}

int main(int argc, char** argv) {
  if (argc != 2) { std::fprintf(stderr, "usage: generate_sewing_fixtures <out-dir>\n"); std::_Exit(2); }
  const std::string dir = argv[1];
  BRep_Builder b;

  // M17: the shell of a 40×30×10 box at the origin — SHELL_BASED_SURFACE_MODEL, no solid.
  const TopoDS_Shape box = BRepPrimAPI_MakeBox(gp_Pnt(0, 0, 0), 40, 30, 10).Shape();
  if (!write(shellOf(box), dir + "/M17_shell_only_box.step")) { std::fprintf(stderr, "M17 failed\n"); std::_Exit(1); }

  // M18: a 10 mm cube solid at the origin plus a loose closed shell cube at x = 20…30.
  TopoDS_Compound mixed; b.MakeCompound(mixed);
  b.Add(mixed, BRepPrimAPI_MakeBox(gp_Pnt(0, 0, 0), 10, 10, 10).Shape());
  b.Add(mixed, shellOf(BRepPrimAPI_MakeBox(gp_Pnt(20, 0, 0), 10, 10, 10).Shape()));
  if (!write(mixed, dir + "/M18_solid_and_free_shell.step")) { std::fprintf(stderr, "M18 failed\n"); std::_Exit(1); }

  // M19: five faces of a 10 mm cube — every face but the top (z = 10).
  TopoDS_Compound sheet; b.MakeCompound(sheet);
  const TopoDS_Shape cube = BRepPrimAPI_MakeBox(gp_Pnt(0, 0, 0), 10, 10, 10).Shape();
  for (TopExp_Explorer ex(cube, TopAbs_FACE); ex.More(); ex.Next()) {
    BRepAdaptor_Surface surf(TopoDS::Face(ex.Current()));
    const gp_Pnt p = surf.Value(0.5, 0.5);
    if (p.Z() > 9.5) continue;   // the top face stays out
    b.Add(sheet, ex.Current());
  }
  if (!write(sheet, dir + "/M19_open_sheet.step")) { std::fprintf(stderr, "M19 failed\n"); std::_Exit(1); }

  std::cout << "wrote M17, M18, M19 to " << dir << std::endl;
  std::cout.flush();
  std::_Exit(0);   // skip the Catalyst static-library teardown (tools/README.md)
}
