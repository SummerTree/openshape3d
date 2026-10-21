# OpenShape3D CAD developer test pack

Start with **OpenShape3D_CAD_Test_Plan.docx**. **TEST_PLAN.md** is the portable, editable text version. Use Word's heading navigation to jump to models or test categories.

The plan contains 16 original modeling recipes, three external Shapr3D/NIST exercises, 82 adversarial cases, six device/input configurations, numeric geometry gates, lifecycle checks, performance workloads, automation guidance, release criteria, and 38 official source URLs.

In the 44-page Word edition, the common execution pattern starts on page 4, numerical checks on page 5, individual model recipes on pages 9–24, external exercises on page 25, adversarial cases on page 26, and release gates on page 40. Source URLs start on page 42. Page numbers may change if the document is edited or opened with different font substitutions.

## First run

1. Read sections 1–3 and freeze the build/device/reference versions.
2. Start with M01, M02, M03, M07, M12, and M14 on iPad. Build from a blank project to test modeling; import the bundled final files only in separate comparison/import runs.
3. Capture the same recipe in Shapr3D on iPad/Mac and freeze the native/STEP reference. Shapr3D is not an iPhone modeling reference platform; use the same exact geometry and equivalent user intent for the OpenShape3D iPhone runs.
4. Follow the full build → revise → undo/cancel → save/reopen → export/reimport pattern. A correct screenshot alone cannot pass.
5. Fill a copy of RESULTS_TEMPLATE.md or results_template.json. Every app result starts NOT RUN.

## Files

- `fixtures/`: 23 STEP geometry references (M17–M19, the surface-model cases, added 2026-10-21, M17 also as IGES trimmed surfaces), six binary STL companions, two DXF inputs, four deliberately invalid/open inputs, and a raw OCCT validation log.
- `fixture_manifest.json`: file sizes, SHA-256 hashes, units, expected geometry, and negative-input outcomes.
- `model_catalog.png`: six original fixture previews. These are geometry illustrations, not Shapr3D screenshots.
- `RESULTS_TEMPLATE.md` / `results_template.json`: manual and machine-readable run records.
- `VALIDATION.md`: what was verified when preparing the pack, and what still requires app execution.
- `tools/`: the fixture generators, the OCCT oracle (`occt_inspect`) and the MCP-driven live runner (`import_qa.py`); `tools/README.md` has the build recipe and the fixing loop. `openshape3dTests/ImportQATests.swift` runs the same manifest offline.
- `runs/`: one directory per live run (`REPORT.md`, `results.json`, the app's STEP exports, the oracle's JSON, every MCP call). `qa6`, `qa6-ext` and `qa6-iges` (2026-10-21, on main at dbbd750e) are the current baseline: the pack, the FreeCAD IDF/NIST STEP corpus, and the IDF IGES twins.

The official tutorial and NIST download landing pages are in the plan. Their third-party model binaries and Shapr3D native files are not redistributed in this pack. Obtain the chosen assets from the source, record access/usage terms, and freeze the exact filename and checksum.

This handoff adds documentation and original test assets. It does not change application behavior or assert that either app passed the proposed comparative suite.
