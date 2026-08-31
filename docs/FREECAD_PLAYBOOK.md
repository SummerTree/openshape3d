# FreeCAD → openshape3d hardening playbook

FreeCAD (github.com/FreeCAD/FreeCAD) is the largest open-source consumer of the
same OCCT kernel openshape3d runs as its source of truth. This playbook records
every defensive pattern mined from its source and where it landed here.

Local reference checkout: `~/projects/reference/FreeCAD` — shallow clone of tag
**1.0.2** (stability baseline) with `origin/main` also fetched shallow (the
`FCBRepAlgoAPI_*` boolean wrappers and `TopoShapeExpansion.cpp` element-map code
evolved after 1.0; mine 1.0.2 first, diff against main when a pattern looks new).

## Licensing rules (non-negotiable)

FreeCAD is **LGPL-2.1+**; this app is **MIT**. FreeCAD is a *reference, not a
source of code*:

- **OCCT-API-level** patterns — call sequences over public OCCT APIs
  (`IsDone → NbFaultyContours → BRepCheck_Analyzer → ShapeFix_Shape`), parameter
  choices (fuzzy values, progress deadlines), class selection
  (`BRepExtrema_DistShapeShape` over UV sampling) — are reimplemented from OCCT
  documentation with FreeCAD as the worked example. Safe.
- **FreeCAD-specific algorithms** — `modelRefine.cpp`'s FaceUniter, the
  element-map string machinery, planegcs internals — are **not ported**. Use the
  OCCT-native equivalent (`ShapeUpgrade_UnifySameDomain`, already wrapped as
  `unifiedShape:`) or a clean-room design written from a spec.
- Never copy code, comments, or error strings. All user-facing text is written
  fresh. Porting planegcs wholesale was considered and **rejected** (LGPL
  static-linking is impractical on iOS).

## Pattern ledger

Status: ☐ planned · ☑ landed. Update the row when a pattern ships.

| # | Status | Pattern | FreeCAD ref (@1.0.2 unless noted) | Class | openshape3d change | Defect closed | Test |
|---|--------|---------|------------------------------------|-------|--------------------|---------------|------|
| I1 | ☑ | Typed diagnostics instead of nullable returns on every mutating kernel op | (our own design; motivated by FreeCAD's per-feature error strings) | own | `OCCTOpStatus` out-param in `OCCTBridge`, `OCCTOpError` + `Result` wrappers in `OCCTKernel.swift` | "every failure is nil" | all new suites |
| I2 | ☑ | Post-op heal-and-validate: `BRepCheck_Analyzer` → one `ShapeFix_Shape` heal → re-check → typed failure; single-solid extraction from compounds; shared finite-bounds gate | `src/Mod/PartDesign/App/FeatureFillet.cpp` (post-check + single-solid rule) | OCCT-API | `OS3DHealAndValidate`, `OS3DExtractSingleSolid`, `OS3DFiniteBounds` in `OCCTBridge.mm` | corrupt results stored as truth | `OCCTFilletDiagnosticsTests` |
| F1 | ☑ | Fillet/chamfer: require `NbFaultyContours()==0`, validate result, never return a partial build | `src/Mod/PartDesign/App/FeatureFillet.cpp`, `src/Mod/Part/App/FeatureFillet.cpp` | OCCT-API | `filletedShape:`/`chamferedShape:` + real messages in `FeatureGraph.evalEdgeBlend` | R4-O4 (partial results as success); Ø10-rim crash class | `OCCTFilletDiagnosticsTests`, `BlendStressTests` |
| F2 | ☑ | Pre-qualify blend edges: 2 adjacent faces, not degenerate, not a seam, `Continuity == GeomAbs_C0` only (tangent chains propagate inside ChFi3d) | `src/Mod/PartDesign/App/FeatureDressUp.cpp::getContinuousEdges` (policy re-derived) | OCCT-API | edge filter before `mk.Add` in both blend ops | ChFi3d crashes/no-ops on seam & tangent edges | seam-pick / sphere-pick tests |
| F3 | ☑ | Kernel-derived max fillet radius (bisection over checked builds), computed once per drag | (no FreeCAD equivalent — pure OCCT) | OCCT-API | `maxFilletRadiusForShape:` + clamp in blend drag | mesh-heuristic radius feedback | `BlendStressTests` |
| B1 | ☑ | Boolean hygiene: analyzer pre-check on args (+1 heal), `SetNonDestructive`, auto-fuzzy = diag × `Precision::Confusion()`, one 10× fuzzy retry, single-solid extraction, `UnifySameDomain` before storing | `src/Mod/Part/App/FCBRepAlgoAPI_BooleanOperation.cpp` (main), `FeaturePartBoolean.cpp`, `FuzzyHelper.cpp` | OCCT-API | rewrite `booleanOfShape:`; error split in `FeatureGraph.evalBoolean`; unify in `evalExtrude` cut branch | R4-O3 (raw compounds), silent garbage-in | `BooleanTests`, killer-chain test |
| B2 | ☑ | Shell contract: unwrap compound input, validate result, volume-shrink sanity | `FeatureFillet.cpp` single-solid rule + `BRepGProp` | OCCT-API | `shelledShape:` + `volumeOfShape:` helper | shell fed out-of-contract input | `KernelShellTests` |
| T1 | ☑ | Tolerance from tessellation deflection + per-shape `ShapeAnalysis_ShapeTolerance`, never a fraction of model size | FreeCAD uses `Precision::Confusion()` + per-shape tolerances throughout; picking is screen-space | OCCT-API | `OCCTKernel.matchTolerance(for:)` replaces 4 AABB-scaled sites | S5 (thin-plate mistargeting) | plate shell/fillet tests |
| FT1 | ☑ | Point→face targeting via `BRepExtrema_DistShapeShape` (exact, respects trimming) instead of UV-bbox sampling | `TopoShape::distToShape` usage pattern | OCCT-API | rewrite `OS3DNearestFaces` | R4-O2 (trimmed faces missed) | `OCCTFaceTargetingTests` |
| H1 | ☑ | Heal at trust boundaries (import/deserialize), finite-bounds at op entries, mesher deadline via `Message_ProgressIndicator::UserBreak` | FreeCAD heals at import; `Base::SequencerLauncher` progress wrapper | OCCT-API | STEP/deserialize gates; deadline in `TessellateShape` | NaN-mesh infinite hang residuals | NaN-refusal tests |
| P1 | ☑ | Persist breps without triangulation, pinned format version | `PropertyPartShape` save path | OCCT-API | `serializedShape:` → no-triangles + `TopTools_FormatVersion_VERSION_2` | R4-O5 | round-trip test |
| S1 | ☑ | Gate sketch-solver writeback on convergence; surface conflict state | `src/Mod/Sketcher/App/Sketch.cpp` solve-status gating; planegcs `SolveStatus` | OCCT-API-analog | `SketchSolverBridge.solveOutcome` + spring-back/red chip in drag path + gate in `DocumentSession` variable solve | R2-3 (compromise written every frame) | `ConstraintLifecycleTests` |
| S2 | ☑ | Constraint lifecycle: delete cascades, trim re-anchors, integrity validator | `src/Mod/Sketcher/App/SketchObject.cpp` (`delGeometry`, `trim`) | concept | `RemoveSketchEntitiesCommand` / `TrimCommand` in `Commands.swift` | R2-2 (orphaned constraints) | `ConstraintLifecycleTests` |
| S3 | ☑ | Per-feature error state populated on load and after undo, not only after live edits | `src/App/Document.cpp::recompute` error marking (concept) | concept | errors-only evaluate after `DocumentSession.load()`/undo | R4-N6/S6 (silent broken refs on reopen) | (behavioral; exercised via load/undo) |
| S4 | ☑ | Deterministic face basis (outer loop by area, canonical start) + `resolve` honors surface kind | (prerequisite for FreeCAD-style element maps) | own | `FaceTopology.swift` loop ordering; `SignatureNaming.resolve` | R4-N1/R2-4, R4-N4 | `SignatureNamingTests` kind-veto test |
| S5 | ☑ | Geometry oracle tests: exact volumes/face-type counts for known-hard scenarios | scenarios from `src/Mod/Part/TestPartApp.py`, `tests/src/Mod/Part/` — values re-derived independently, provenance per case | concept | `GeometryOracleTests.swift` | review R3-D (no geometry assertions) | itself |
| N* | ☐ | Kernel-history element naming (design doc only this tranche) | `src/Mod/Part/App/TopoShapeExpansion.cpp` (Mapper classes), `src/App/ElementMap.h/.cpp` (concept), realthunder topo-naming docs | concept | `docs/TOPO_NAMING_HISTORY_DESIGN.md` | R4-N2/N3/N5 (design) | — |
