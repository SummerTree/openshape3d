// Original deterministic QA geometry. Uses public OCCT APIs; no app code.
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepGProp.hxx>
#include <BRepBndLib.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <STEPControl_Writer.hxx>
#include <STEPControl_Reader.hxx>
#include <StlAPI_Writer.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <Interface_Static.hxx>
#include <TopExp_Explorer.hxx>
#include <TopExp.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Vertex.hxx>
#include <Standard_Version.hxx>
#include <gp_Trsf.hxx>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <cmath>
#include <stdexcept>
#include <string>
#include <vector>
#include <cstdlib>

using S = TopoDS_Shape;
S box(double x,double y,double z,double w,double d,double h) { return BRepPrimAPI_MakeBox(gp_Pnt(x,y,z),w,d,h).Shape(); }
S cyl(double x,double y,double z,double r,double h) { return BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(x,y,z),gp_Dir(0,0,1)),r,h).Shape(); }
S cut(const S&a,const S&b) { BRepAlgoAPI_Cut op(a,b); op.Build(); if(!op.IsDone()) throw std::runtime_error("cut failed"); return op.Shape(); }
S fuse(const S&a,const S&b) { BRepAlgoAPI_Fuse op(a,b); op.Build(); if(!op.IsDone()) throw std::runtime_error("union failed"); return op.Shape(); }
TopoDS_Edge vertical(const S&s) {
  for(TopExp_Explorer ex(s,TopAbs_EDGE);ex.More();ex.Next()) {
    auto e=TopoDS::Edge(ex.Current()); TopoDS_Vertex a,b; TopExp::Vertices(e,a,b);
    auto p=BRep_Tool::Pnt(a),q=BRep_Tool::Pnt(b);
    if(std::abs(p.X())<1e-8&&std::abs(p.Y())<1e-8&&std::abs(q.X())<1e-8&&std::abs(q.Y())<1e-8&&std::abs(p.Z()-q.Z())>9) return e;
  } throw std::runtime_error("edge missing");
}
double volume(const S&s) { GProp_GProps g; BRepGProp::VolumeProperties(s,g); return g.Mass(); }
int solids(const S&s) { int n=0; for(TopExp_Explorer e(s,TopAbs_SOLID);e.More();e.Next())++n; return n; }
void check(const S&s,double expected,int count) {
  if(!BRepCheck_Analyzer(s).IsValid()||solids(s)!=count||std::abs(volume(s)-expected)>std::max(1e-6,std::abs(expected)*1e-9)) throw std::runtime_error("validity / analytic volume / count mismatch");
}
int main(int argc,char**argv) {
  if(argc!=2) return 2;
  std::string dir=argv[1];
  std::ofstream report(dir+"/occt_validation.csv");
  report<<"file,occt_version,expected_volume_mm3,measured_volume_mm3,solid_count,min_x,min_y,min_z,max_x,max_y,max_z,planar_faces,cylindrical_faces,other_faces,roundtrip_valid\n"<<std::setprecision(15);
  const double pi=std::acos(-1.0);
  auto save=[&](std::string name,std::vector<S> shapes,double expected) {
    STEPControl_Writer writer;
    Interface_Static::SetCVal("write.step.schema","AP214IS");
    Interface_Static::SetCVal("write.step.unit","MM");
    double sum=0; for(const auto&s:shapes){if(!BRepCheck_Analyzer(s).IsValid())throw std::runtime_error(name+" invalid");sum+=volume(s);if(writer.Transfer(s,STEPControl_AsIs)!=IFSelect_RetDone)throw std::runtime_error("transfer failed");}
    if(std::abs(sum-expected)>std::max(1e-6,std::abs(expected)*1e-9)) throw std::runtime_error(name+" formula mismatch");
    std::string path=dir+"/"+name+".step";
    if(writer.Write(path.c_str())!=IFSelect_RetDone)throw std::runtime_error("write failed");
    STEPControl_Reader reader;
    if(reader.ReadFile(path.c_str())!=IFSelect_RetDone)throw std::runtime_error("read failed");
    reader.TransferRoots(); auto s=reader.OneShape(); check(s,expected,(int)shapes.size());
    Bnd_Box bb; BRepBndLib::AddOptimal(s,bb,false,false); double a,b,c,d,e,f;bb.Get(a,b,c,d,e,f);
    int np=0,nc=0,no=0;for(TopExp_Explorer ex(s,TopAbs_FACE);ex.More();ex.Next()){BRepAdaptor_Surface surf(TopoDS::Face(ex.Current()));if(surf.GetType()==GeomAbs_Plane)++np;else if(surf.GetType()==GeomAbs_Cylinder)++nc;else ++no;}
    report<<name<<".step,"<<OCC_VERSION_COMPLETE<<","<<expected<<","<<volume(s)<<","<<solids(s)<<","<<a<<","<<b<<","<<c<<","<<d<<","<<e<<","<<f<<","<<np<<","<<nc<<","<<no<<",true\n";
    if(name=="M01_block"||name=="M02_four_hole_plate"||name=="M03_open_tray"||name=="M04_revolved_washer"||name=="M05_L_bracket"||name=="M07_single_edge_fillet") {
      BRepMesh_IncrementalMesh mesh(s,0.02,false,0.15,false);
      StlAPI_Writer stl; stl.ASCIIMode()=false;
      if(!stl.Write(s,(dir+"/"+name+".stl").c_str()))throw std::runtime_error("STL write failed");
    }
  };
  auto base=box(0,0,0,40,30,10);
  save("M01_block",{base},12000);
  auto plate=box(0,0,0,80,50,8);
  for(double x:{10.,70.})for(double y:{10.,40.})plate=cut(plate,cyl(x,y,-1,3,10));
  save("M02_four_hole_plate",{plate},32000-288*pi);
  auto tray=cut(box(0,0,0,60,40,25),box(2,2,2,56,36,24));
  save("M03_open_tray",{tray},13632);
  save("M04_revolved_washer",{cut(cyl(0,0,0,15,8),cyl(0,0,-1,8,10))},1288*pi);
  auto bracket=fuse(box(0,0,0,60,40,6),box(0,0,6,6,40,34));
  save("M05_L_bracket",{bracket},22560);
  auto a=box(0,0,0,20,20,20),b=box(10,0,0,20,20,20);
  save("M06_boolean_inputs",{a,b},16000);
  save("M06_union",{fuse(a,b)},12000);
  save("M06_subtract",{cut(a,b)},4000);
  BRepAlgoAPI_Common common(a,b);save("M06_intersect",{common.Shape()},4000);
  auto cube=box(0,0,0,10,10,10);auto edge=vertical(cube);
  BRepFilletAPI_MakeFillet fillet(cube);fillet.Add(2,edge);fillet.Build();
  save("M07_single_edge_fillet",{fillet.Shape()},960+10*pi);
  BRepFilletAPI_MakeChamfer chamfer(cube);chamfer.Add(2,edge);chamfer.Build();
  save("M07_single_edge_chamfer",{chamfer.Shape()},980);
  save("M08_straight_sweep",{cyl(0,0,0,3,50)},450*pi);
  save("M09_conical_loft",{BRepPrimAPI_MakeCone(15,8,40).Shape()},(40.0/3)*(225+120+64)*pi);
  save("M10_split_halves",{box(0,0,0,20,30,10),box(20,0,0,20,30,10)},12000);
  std::vector<S> pins;for(int i=0;i<6;++i){double t=2*pi*i/6;pins.push_back(cyl(20*std::cos(t),20*std::sin(t),0,2,10));}
  save("M11_six_pin_pattern",pins,240*pi);
  auto stepped=fuse(box(0,0,0,20,20,5),box(20,0,0,20,20,10));
  save("M12_replace_face_start",{stepped},6000);
  save("M12_replace_face_result",{box(0,0,0,40,20,10)},8000);
  save("M13_thin_frame",{cut(box(0,0,0,20,20,2),box(1,1,-1,18,18,4))},152);
  auto tag=cut(box(0,0,0,40,20,4),cyl(7,6,-1,2,6));
  save("M14_asymmetric_tag",{tag},3200-16*pi);
  gp_Trsf rot;rot.SetRotation(gp_Ax1(gp_Pnt(0,0,0),gp_Dir(0,0,1)),pi/2);
  gp_Trsf tr;tr.SetTranslation(gp_Vec(100,-50,25));
  save("M14_placed_tag",{BRepBuilderAPI_Transform(tag,tr*rot,true).Shape()},3200-16*pi);
  std::cout<<"Generated and re-imported 20 STEP fixtures; analytic checks passed.\n";
  report.close(); std::cout.flush();
  // The standalone macabi executable links the app's Catalyst static library.
  // All local checks and output close above; bypass Catalyst global teardown,
  // which crashes after main when this library is hosted outside a UIKit app.
  std::_Exit(0);
}
