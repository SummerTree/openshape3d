# openshape3d

Open-source iOS Shapr3D-parity CAD app: SwiftUI + custom Metal renderer +
Euclid mesh-CSG kernel + parametric feature graph (topological naming).

**Start here: `docs/STATUS_AND_NEXT_STEPS.md`** — current phase status, the
prioritized next missions, dev workflow (simulator UDID, test commands,
UI-test helpers), and the gotchas list (SwiftData-in-XCTest crash, a11y
container collapse, bottom-overlay stacking, nonisolated defaults, …).
Update it at the end of each mission.

Spec/design companions: `docs/SHAPR3D_PARITY_SPEC.md`,
`docs/IMPLEMENTATION_PLAN.md`, `docs/PHASE_D_DESIGN.md`.

Architecture seams (never bypass): geometry ops via `KernelOps`, mutations via
`DocumentCommand` (undoable), all state through `EditorViewModel`. Run tests
with `-parallel-testing-enabled NO`; unit-test geometry as pure values —
never instantiate `DocumentSession`/`ModelContainer` in tests.
