# Modeling Parity Goals — Sketch + Solid

**Purpose.** A single ordered plan for reaching Shapr3D parity on the *modeling
core*: sketching, constraints, and solid feature operations. This is the "what
we're building next and when we can call it done" doc.

**Relationship to the other docs — read this first.**

| Doc | Role |
|---|---|
| `SHAPR3D_PARITY_SPEC.md` | The **feature-by-feature audit**: every Shapr3D behaviour, its status, and its feasibility marker. The source of truth for *what a feature must do*. |
| `IMPLEMENTATION_PLAN.md` | Phase sequencing for the whole app (incl. platform/services). |
| `OCCT_BREP_PORT_DESIGN.md` | How the B-rep kernel is being introduced. |
| **This doc** | Ordered **goals with acceptance criteria** for the modeling core only. |

Do not restate behaviour here — cite the spec section (e.g. §4.3) and state the
*goal* and *how we'll know it's done*.

---

## 1. Scope

**In scope:** sketch tools, sketch constraints/dimensions, solid creation
(extrude/revolve/sweep/loft), solid modification (fillet, chamfer, shell, offset
face, draft-adjacent face ops), booleans, patterns/mirror, and the interchange
formats that make the modeling core usable in a real workflow (STEP).

**Explicitly out of scope here:** rendering/visualization polish, drawings,
collaboration/sync, AR, gallery/document management. Those live in
`IMPLEMENTATION_PLAN.md`.

**Definition of "main functionality parity".** A user can complete a realistic
mechanical part end-to-end without hitting a wall:

> sketch a constrained profile → extrude/revolve it → boolean it against other
> bodies → fillet and chamfer the edges that matter → shell it → export STEP,

with results that are **exact** (analytic surfaces, not visibly faceted) and
**parametric** (editing any history step rebuilds downstream correctly).

---

## 2. Where we stand

**Sketch.** Line, rect, circle, arc, ellipse, polygon, trim, text, project are
implemented. A Levenberg–Marquardt constraint solver ships with 13 geometric
constraints (coincident, horizontal, vertical, parallel, perpendicular, equal
length/radius, concentric, midpoint, symmetric, tangent, colinear, fixed) plus
dimensional constraints, DOF colouring, and auto-constrain.

**Solid.** Primitives, extrude, revolve, sweep, loft, booleans, push/pull,
pattern, mirror, split all evaluate through the parametric feature graph with
topological naming (a `FaceRef` survives a rebuild). Chamfer/fillet and shell
exist in the **mesh domain** with documented v1 gaps.

**Kernel.** OCCT is now the source of truth for extrude, primitives, and
booleans between B-rep bodies; Euclid owns everything else. See
`OCCT_BREP_PORT_DESIGN.md` for the current split and limitations.

**The gating problem.** Ops not yet ported to OCCT **drop the brep**, so a
filleted or shelled cylinder reverts to a faceted mesh body. Until the
modification ops are ported, exactness doesn't survive a real modeling session.
This is why G1–G3 come first.

### Reality check — Shapr3D starter tutorial walkthrough (2026-08-26)

The "Introducing Shapr3D basics" motorcycle-cover series (parts 2–4:
[Creating complex shapes](https://support.shapr3d.com/hc/en-us/articles/13079104356380),
[Create basic 3D geometry](https://support.shapr3d.com/hc/en-us/articles/13079130132508),
[Modify features with Design History](https://support.shapr3d.com/hc/en-us/articles/13079145254172))
was driven step-by-step against the app on the iPad simulator. It is a good
parity yardstick because it is the *first* thing a new Shapr3D user does, so
anything missing there is a wall, not a nicety.

**Held up:** dimension-on-select with typed values driving the solver;
the constraint menu with hotkey letters and context-sensitive enablement;
auto-constraints while drawing (`H` badge); tap-a-profile → pull arrow with
live drag and a typed distance; the boolean-result selector
(`Auto / New Body / Union / Subtract / Intersect`); sketch-on-a-model-face;
Shell with face picking and a live hollow preview; Fillet with live preview and
a drag handle; sketch Text with font + height; named/isometric views; and the
History panel's rename / suppress / delete / roll-back / inline parameter edit.

**Walls hit** — these became G7:

| Tutorial step | Gap |
|---|---|
| "click the offset edge tool, select a model edge, drag it in, key in a half inch" (used twice) | Offset Edge has no UI at all — see G5.2 |
| "add draft to this using the curved arrow and key in 10" (used twice) | no draft angle on extrude *(§4.1 already records this)* |
| "select the sketch plane and shift-select the extrude … drag these up the tree" | History rows are individually draggable only — no multi-select *(§10.1)* |

**Cosmetic bug found and fixed the same day:** `HistoryPanelView`,
`ItemsPanelView`, and `VariablesPanelView` are each
`ScrollView { … }.background(.regularMaterial)` and still used hierarchical
`.secondary`/`.tertiary`, so their section headers, row icons, trash buttons,
and unit captions rendered **fully transparent** — the History panel read as a
bare "Extrude / 1 / Shell / 0.3". This is the gotcha the `.barLabel` colour in
`AdaptiveBar.swift` was introduced for; it had only ever been applied to the
bottom bars. All three panels now use `.barLabel` / `.barLabelDim`. Note this
class of bug is **invisible to XCUITest** — a transparent label still `exists`
and is `isHittable` — so it needs a visual check.

---

## 3. Goals

Each goal states the target, the kernel work, and **acceptance criteria** that
should become tests.

### G1 — Fillet & Chamfer on B-rep *(spec §4.3)* — **fillet landed 2026-07-22; chamfer pending**

**Done:** `OCCTBridge.filletedShape:atWorldPoints:radius:tolerance:` wraps
`BRepFilletAPI_MakeFillet`; `evalEdgeBlend` uses it whenever the body carries a
`brep`, and falls back to the mesh blend when OCCT can't build the round (e.g.
radius too large). Edge mapping works by sampling each analytic edge and
matching against the picked mesh-edge midpoints — which means **tangent-chain
propagation came for free**: a tessellated rim is many mesh segments but ONE
analytic edge, so picking a single segment rounds the whole circle. Verified by
`testFilletingACylinderRimStaysAnalytic` (wall survives as one cylindrical
face, blend adds a curved face, result still tessellates finely).

**Still to do:** chamfer on `BRepFilletAPI_MakeChamfer` (needs the edge's
adjacent face), concave edges, and surfacing the max-valid-radius in the drag
feedback from OCCT rather than the mesh heuristic.


The original motivation for the whole port, and the biggest visible gap: today a
fillet on a cylinder throws away the analytic geometry.

- `BRepFilletAPI_MakeFillet` / `MakeChamfer` replace the mesh-domain blend.
- **Hard part:** mapping a user-selected *mesh* edge to an OCCT `TopoDS_Edge`.
  Plan: match on edge geometry (endpoints + adjacent-face normals) against the
  brep's edges, reusing the signature idea already in `EdgeTopology`.
- Tangent-chain propagation (§4.3: selecting one edge of a tangent chain rounds
  the whole chain) becomes natural — OCCT knows the topology.
- Concave edges, and corners where 3+ blended edges meet, stop being
  best-effort.

**Acceptance**
- Filleting the top rim of a cylinder yields a body whose side is still ONE
  cylindrical face and whose blend is a torus face — asserted via face-type
  counts, not pixels.
- The result **retains its brep** (a subsequent boolean stays analytic).
- Variable-radius and G2 are explicitly *not* required (partial in OCCT).
- Existing blend UI (multi-edge pick, live preview, drag-to-size arrow, red/blue
  validity) keeps working unchanged.

### G2 — Shell on B-rep *(spec §4.4)* — **kernel landed 2026-07-22; wiring pending**

**Done (kernel):** `OCCTBridge.shelledShape:atWorldPoints:thickness:tolerance:`
wraps `BRepOffsetAPI_MakeThickSolid`, supporting both face-removal (points pick
the faces to open) and whole-body hollow (empty selection). Verified by
`testShellingACylinderProducesATube` — shelling a cylinder yields **two
concentric cylindrical faces**, precisely the case the mesh inset gets wrong.

**Still to do:** route `evalShell` through it (see the note in §Sequencing about
the blend/shell eval wiring), and drive the red/blue drag feedback from OCCT's
valid-thickness range rather than the mesh heuristic.

### G3 — Remaining solid creators on B-rep *(spec §4.10, §4.11, §4.5)*

Revolve (`BRepPrimAPI_MakeRevol`), sweep (`BRepOffsetAPI_MakePipe`), loft
(`BRepOffsetAPI_ThruSections`). Also the two extrude paths still on Euclid:
extrude-into-target booleans, and multi-profile extrudes.

**Why it matters:** every creator must produce a brep, or downstream ops silently
fall back to mesh. This is what makes "OCCT is the source of truth" true rather
than aspirational.

**Acceptance:** a revolved profile has analytic faces; every creation op sets
`Body.brep`; a chain (revolve → boolean → fillet) stays analytic throughout.

### G4 — Direct-modeling face ops *(spec §4.2, §4.12, §4.16, §4.13)*

Offset Face (incl. curved faces with adjacent-face extension/trimming), Replace
Face, Delete Face with healing (OCCT defeaturing / `RemoveFeatures`), Offset
Edge in 3D. These are what make it feel like *direct* modeling rather than
history-only modeling.

**Acceptance:** deleting a fillet face heals the surrounding faces back to a
valid solid; offsetting a cylindrical face changes its radius rather than
faceting it.

### G5 — Sketch completeness *(spec §1.x, §2.x, §3.x)*

The remaining gaps in the sketch half, ordered by how often they block real work:

1. **Spline (fit / control points)** *(§1.4)* — the biggest missing sketch
   primitive; needs solver integration for tangency.
2. **Offset Edge in sketch mode** *(§1.9)* — kernel exists, UI does not.
   **Promoted:** the starter tutorial opens with this tool and uses it twice, so
   it blocks the very first workflow a new user attempts. Do it as part of G7.
3. **Sketch pattern (linear/circular) + the pattern constraint** *(§1.11, §2.5)*.
4. **Line/Arc pen mode** *(§1.2)* — drag-to-arc continuation, a core Shapr3D
   input idiom.
5. **Helix** *(§1.17)* — pairs with sweep for threads.
6. Snapping/guides and notable-point polish *(§2.6, §2.7)*.

**Acceptance:** a spline can be drawn, dimensioned, constrained tangent to an
adjacent line, and extruded; sketches reach a fully-defined (green) state.

### G6 — STEP interchange *(spec §12.1, §12.2)*

STEP import/export via OCCT DataExchange — the format that makes the app usable
alongside other CAD.

**Cost to be explicit about:** enabling `DataExchange` + XDE roughly doubles the
static library (18 → 47 toolkits, ~74 → ~140 MB/arch, measured). Decide
deliberately; it is a one-line flip in `scripts/build_occt_ios.sh`.

**Acceptance:** round-trip a filleted, shelled part through STEP with faces and
solid topology preserved.

### G7 — Close the starter-tutorial walls *(spec §1.9, §4.1, §10.1)*

The three gaps that stop a new user completing the Shapr3D getting-started
series (see the walkthrough in §2). All three are **UI/feature work, not kernel
work**, so this goal is independent of G1–G4 and can run in parallel.

1. **Offset Edge in the sketch palette** *(§1.9)* — `SketchOffset` and
   `EdgeOffsetKit` are tested backends with no entry point. Needs a palette
   item, edge picking, a blue drag arrow, and a typed distance, matching the
   push/pull arrow interaction already in `ViewportView`.
2. **Draft angle on extrude** *(§4.1)* — a second, curved handle on the pull
   gizmo plus an angle field in the extrude bar; the tapered prism is a kernel
   op on both the Euclid and OCCT paths (`BRepPrimAPI_MakePrism` has no draft;
   expect `BRepOffsetAPI_DraftAngle` or a lofted-profile construction).
3. **Multi-select + group reorder in History** *(§10.1)* — rows are
   individually `.draggable` with a single-UUID payload; the tutorial's key
   move is selecting a sketch *and* its extrude and dragging both above the
   shell in one gesture.

**Lower-priority divergences found in the same pass** (record, don't schedule):
a selected full circle reports **Radius** where Shapr3D reports **Ø** — and we
already draw Ø in the live sketch overlay, so we are inconsistent with
ourselves; sketch Text is a modal sheet rather than live-on-canvas with the
move/rotate/reference-point pad; Shell thickness has a field but no drag
handle, unlike the blend arrow.

**Acceptance**
- The "Create basic 3D geometry" tutorial can be followed end-to-end in the app
  without substituting a different tool for any step.
- Offsetting a model edge into a sketch, extruding the loop with 10° of draft,
  and reordering that extrude above the shell all survive a save/reload and a
  parametric rebuild.

---

## 4. Cross-cutting requirements

These apply to every goal above and are easy to forget:

- **Brep preservation.** Any ported op MUST set `Body.brep` on its result, or it
  silently regresses exactness for everything downstream. Treat "result has a
  brep" as part of each op's acceptance.
- **Parametric integrity.** Every op is a `FeatureKind` node; editing a
  parameter must rebuild downstream and re-resolve `FaceRef`/`EdgeRef` against
  the new geometry.
- **Validity feedback** *(spec §18)*. Operations that can fail (fillet radius too
  large, shell thickness out of range) show the red/blue live feedback and a
  recoverable failure message — not a silent no-op.
- **Persistence.** New analytic geometry must survive save/reload, and the
  `.os3d` archive needs the brep blob (currently missing).
- **Performance.** OCCT booleans/blends are slower than mesh. Keep Euclid for
  live drag previews; run exact kernel work off the main actor with progress and
  cancellation on anything that can take >100 ms.
- **Fallback.** If an OCCT op fails, fall back to the Euclid path rather than
  failing the user's action, and surface that the result is approximate.

---

## 5. Sequencing

```
G1 Fillet/Chamfer ──► G2 Shell ──► G3 Remaining creators ──► G4 Face ops
                                          │
G5 Sketch completeness (parallel track) ──┘──► G6 STEP

G7 Starter-tutorial walls ── independent, do first (UI-only, unblocks new users)
```

G1–G3 are the critical path: they make exactness survive a modeling session.
G5 is independent of the kernel work and can proceed in parallel. G4 depends on
robust B-rep topology, so it follows G3. G6 last, so the size cost is paid only
once the modeling core justifies it.

**G7 jumps the queue** despite not being on the exactness path: it is cheap
(UI wiring over backends that already exist and are tested) and it is the
difference between a new user completing the getting-started tutorial and
hitting a wall on step one. Exactness matters to the user who stays; G7 decides
whether they get that far.

**Milestone definition of done for "modeling core parity":** the end-to-end
scenario in §1 completes with analytic results and a clean parametric rebuild —
i.e. G1–G4 plus the top three items of G5. **G7 is the separate "a beginner can
finish the official tutorial" bar**, and is worth tracking on its own.

---

## 6. Non-goals (deliberate gaps)

Called out so they don't get mistaken for oversights:

- **Variable-radius and G2 blends** — partial in OCCT; accept the gap.
- **Parasolid-grade boolean robustness on dirty imported geometry** — OCCT is
  weaker here; mitigate with shape healing and the Euclid fallback.
- **Wrap & Emboss** *(§4.15)*, **Replace Face on complex surfaces** — deferred
  until the core above is solid.
- Anything outside the modeling core (drawings, sync, AR, collaboration).
