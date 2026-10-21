# Import QA tools

The CAD test pack's two halves and the oracle they share. `../TEST_PLAN.md`
holds the gates; this file is how to run them and how to work a failure.

## What is here

| File | What it is |
|---|---|
| `generate_fixtures.cpp` | Builds the M01–M15 STEP/STL fixtures from public OCCT APIs: original geometry, no app code. |
| `generate_sewing_fixtures.cpp` | Builds M17–M19: a box written as a shell with no solid (also as IGES trimmed surfaces, `M17_shell_only_box.igs`), a solid beside a loose closed shell, and an open five-face sheet. These are the surface-model cases the FreeCAD IDF footprint corpus exposed on 2026-10-21 (SOT23, SOT404, SOD_323), reduced to synthetic parts the pack owns. |
| `inspect_step.cpp` → `build/qa/occt_inspect` | The oracle. Reads a STEP, IGES, STL or BREP file with OCCT alone and prints volume, centroid, bounds, face classes and validity; with `--ref` it also prints the deviation against a reference file. |
| `import_qa.py` | The live half. Drives the running app over MCP (`scripts/mcp_openshape3d.py`), imports every fixture and every `--extra` file, measures through `/v1/state`, `/v1/check` and `/v1/faces`, round-trips through `/v1/export`, runs the oracle on the export, applies the gates, undoes, and writes a report. |

The offline half is `openshape3dTests/ImportQATests.swift`: the same
manifest through the importers themselves (STEP, IGES, STL, DXF), no
simulator agent needed.

    xcodebuild test -scheme openshape3d -destination "platform=iOS Simulator,id=<udid>" \
      -only-testing:openshape3dTests/ImportQATests -parallel-testing-enabled NO

## Building the C++ tools

One recipe for all three; the Catalyst OCCT slice links as a host binary.

    xcrun -sdk macosx clang++ -target arm64-apple-ios17.0-macabi -std=c++17 -O1 \
      -I ThirdParty/OCCT.xcframework/ios-arm64/Headers \
      docs/qa/shapr3d-parity/tools/inspect_step.cpp \
      ThirdParty/OCCT.xcframework/ios-arm64-maccatalyst/libOCCT-MAC_CATALYST_ARM64.a \
      -o build/qa/occt_inspect

Every tool ends with `std::_Exit` rather than returning, because the static
library's teardown crashes on the host. `_Exit` skips stdio flushing, so
flush before it; the oracle writes with `std::endl` for that reason.

## The oracle

    build/qa/occt_inspect <file.step|.igs|.stl|.brep> [--ref <reference>] [--deflection 0.02] [--samples 1500] [--no-boolean]

JSON on stdout. `sewing` says what an importer can make of the file:
`rawSolids` declared, `freeFaces` outside any solid, `sewnSolids` closed by
sewing at 1e-3 mm, `openShells` kept as sheets, `dropped` pieces that would
not heal. `metrics` are measured on that importable shape, with the same
heal-validate-or-drop policy and the same face-by-face fallback for a sheet
that fails as a whole as the app's reader, so a surface-modelled part is
held to the solid it should become rather than to "zero solids". Volume
counts solids only; a sheet reads 0. `deviation` appears with `--ref`, and
its surface distance is a sampled estimate at the given deflection, not a
bound.

## The live run

Launch the app with the agent (DEBUG builds only). Port 8787 is squatted on
this Mac, hence 8899.

    SIMCTL_CHILD_OS3D_AGENT=1 SIMCTL_CHILD_OS3D_AGENT_PORT=8899 SIMCTL_CHILD_OS3D_FRESH=1 \
      xcrun simctl launch <udid> com.laan.labs.openshape3d

    python3 docs/qa/shapr3d-parity/tools/import_qa.py --port 8899 --run-id qa5
    python3 docs/qa/shapr3d-parity/tools/import_qa.py --port 8899 --run-id qa5-ext --no-fixtures \
      --extra /path/to/a/folder/of/models --extra one_more.stp

Flags: `--only M01,M02,NEGATIVE` (case id prefixes), `--extra` (a file or a
folder of `.step`/`.stp`/`.igs`/`.iges`, repeatable; the oracle's own
reading of each file is the reference), `--no-fixtures`, `--skip-mesh`. Output lands in
`../runs/<run-id>/`: `REPORT.md`, `results.json`, `exports/` (the app's
STEP of each import), `inspect/` (the oracle's JSON per case) and
`mcp_calls.jsonl` (every MCP call and reply).

What a case checks, in order (STEP and IGES alike): the import reply (`bodyIDs`, `notice`, the
`step` ledger); solid and sheet counts from `/v1/check` (`counts.solids`);
volume over solid bodies only; exact bounds; BRepCheck validity; BOP
self-intersections (advisory); face classes against the manifest
(advisory); then the STEP round trip through the oracle against the
ORIGINAL file: volume, centroid, bounds, symmetric-difference ratio and
sampled surface distance. A negative fixture must be refused or imported
with a notice. Every case ends with `edit.undo` and an empty-design check.

## The fixing loop

1. Run the pack and a corpus; read `REPORT.md`, then the failing case's
   `inspect/*.json` and its calls in `mcp_calls.jsonl`.
2. Reproduce on the kernel alone with the oracle, or a probe built the same
   way. It answers "what does this file actually hold" without the app.
3. Fix in `OCCTBridge.mm`, `STEPKit`, `DXFKit` or `MeshImportKit`; pin the
   case in `ImportQATests.swift`. If a corpus found a new shape of input,
   add a synthetic fixture and a manifest entry so the pack owns it.
4. Rebuild, rerun both halves, keep the run directory as the record.
