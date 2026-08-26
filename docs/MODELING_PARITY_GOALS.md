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

### Reality check — driven against Shapr3D's own tutorials and manual (2026-08-26)

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

A second pass (same day) covered the two earlier hands-on entries —
[Grid and sketch settings](https://support.shapr3d.com/hc/en-us/articles/13079113458332)
and [Introduction to 2D sketch tools and settings](https://support.shapr3d.com/hc/en-us/articles/13079114694684).
More held up there: a fresh sketch **auto-arms Line** exactly as the video
shows; marquee **window vs crossing by drag direction** is implemented; the
Shift+letter constraint hotkeys were already wired; auto-constrain has
per-inference toggles and an angle tolerance. (The two remaining series
entries — "Introducing Shapr3D Basics" and "Get started: A Shapr3D Overview" —
are narration only, with no steps to reproduce.)

**Walls hit** — these became G7:

| Tutorial step | Gap |
|---|---|
| "click the offset edge tool, select a model edge, drag it in, key in a half inch" (used twice) | Offset Edge has no UI at all — see G5.2 |
| "add draft to this using the curved arrow and key in 10" (used twice) | no draft angle on extrude *(§4.1 already records this)* |
| "select the sketch plane and shift-select the extrude … drag these up the tree" | History rows are individually draggable only — no multi-select *(§10.1)* |
| "click on circle or use C on the keyboard", "I'm using the A key", "the T hotkey" | ~~no per-tool hotkeys; `CommandRegistry` was dead code~~ **fixed 2026-08-26**, see G7.0 |
| several minutes in snap / grid / units / circular-annotation settings | our Settings sheet has four rows *(§17)* — see G7.4 |

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

### G7 — Close the starter-tutorial walls *(spec §1.9, §4.1, §8.4, §10.1, §17)*

The gaps that stop a new user completing the Shapr3D getting-started series
(see the walkthrough in §2). All of them are **UI/feature work, not kernel
work**, so this goal is independent of G1–G4 and can run in parallel.

**Done**

0. ~~**Hotkeys** *(§8.4)*~~ — **landed 2026-08-26.** `CommandRegistry` was a
   fully-tested catalog with *zero references outside its own test target*:
   every hotkey in it was dead, while the tutorials lean on "press C for
   circle, A for arc, T for trim" throughout. Now routed —
   `CommandDispatch.swift` maps 34 catalog ids onto existing view-model entry
   points, and `CommandShortcutsView` registers the chords.
   Two things worth remembering:
   - The chords ride on **zero-sized buttons carrying `.keyboardShortcut`**,
     not `onKeyPress`. `.keyboardShortcut` lowers to a `UIKeyCommand` that
     UIKit consults app-wide on the responder chain, so it does not need the
     Metal viewport to hold focus — which it cannot reliably take. It is also
     already the pattern the constraint hotkeys use in `ToolPaletteView`.
   - Because the **first responder wins first**, a focused text field still
     receives plain letters: verified on device by typing "cat" into a History
     rename field and getting "cat", not Circle → Arc → Text.
   - Every hotkey guard mirrors the palette's own `enabled` condition, so a
     key can never reach a state the equivalent button would have refused.
   - `CommandRegistry.unroutedChordedCommands` names what still has a chord but
     no entry point (Insert Image, Offset, Command Search, the project/import
     commands, Select All, Zoom to Selection); a test pins that list, so adding
     a chorded command without routing it fails loudly instead of shipping a
     key that quietly does nothing.

**Remaining**

1. **Offset Edge in the sketch palette** *(§1.9)* — `SketchOffset` and
   `EdgeOffsetKit` are tested backends with no entry point. Needs a palette
   item, edge picking, a blue drag arrow, and a typed distance, matching the
   push/pull arrow interaction already in `ViewportView`. Routing its `O`
   hotkey is then a one-line addition to `routableIDs`.
2. **Draft angle on extrude** *(§4.1)* — a second, curved handle on the pull
   gizmo plus an angle field in the extrude bar; the tapered prism is a kernel
   op on both the Euclid and OCCT paths (`BRepPrimAPI_MakePrism` has no draft;
   expect `BRepOffsetAPI_DraftAngle` or a lofted-profile construction).
3. **Multi-select + group reorder in History** *(§10.1)* — rows are
   individually `.draggable` with a single-UUID payload; the tutorial's key
   move is selecting a sketch *and* its extrude and dragging both above the
   shell in one gesture.
4. **The Settings sheet is far thinner than Shapr3D's** *(§17)* — ours is
   Units / Theme / Toolbar Side / Anti-Aliasing. "Grid and sketch settings" and
   "Introduction to 2D sketch tools" spend roughly three minutes in settings we
   do not have:
   - **snap toggles** — snap-to-grid, sketch guidelines, sketch guide points,
     snapping hints. `SnapEngine` implements all four behaviours; none is
     switchable.
   - **grid position** (XY / XZ / ZX) and **grid-locked-size while zooming**.
   - **circular annotations**: radius-always vs radius-and-diameter. This is
     the *named source* of the Ø-vs-R divergence below — Shapr3D's default
     reserves diameter for full circles and radius for arcs.
   - **fractional inches** and **degree format** (fractional / decimal).
   - orthographic↔perspective as a **slider**, where we have a binary toggle.
5. **Grid does not re-orient to the active sketch plane** — it stays on the
   world ground plane. Shapr3D moves the grid onto the sketch plane on entry
   and back on exit. Already noted in `STATUS_AND_NEXT_STEPS.md`; recorded here
   because the tutorial makes it a first-five-minutes observation.

**Lower-priority divergences found in the same pass** (record, don't schedule):
a selected full circle reports **Radius** where Shapr3D reports **Ø** — and we
already draw Ø in the live sketch overlay, so we are inconsistent with
ourselves (see item 4 for the setting that governs it); sketch Text is a modal
sheet rather than live-on-canvas with the move/rotate/reference-point pad;
Shell thickness has a field but no drag handle, unlike the blend arrow; Items
and History are mirrored relative to Shapr3D (it puts Items left / History
right, and our Toolbar Side setting only moves the palette); renaming a design
is gallery-only, where Shapr3D renames from the editor's upper-left title.

**Audited against the official manual (2026-08-26).** The 343-page Shapr3D
manual PDF (pages 77–259 are sketching + modeling) was read tool-by-tool
against this repo. Two things worth recording:

1. **`SHAPR3D_PARITY_SPEC.md` is accurate and complete in its coverage.** Every
   tool in the manual's Sketch / Constraints / Insert / Construct / Transform /
   Tools menus maps onto an existing spec section — there are no unaudited
   features — and the statuses spot-checked (§1.4 spline, §1.9 offset edge,
   §4.4 shell, §6.1/§6.2 construction geometry, §8.4 hotkeys) were all correct,
   including the careful distinction in §1.4 between the spline *entity* (which
   ships through the whole pipeline) and the spline *drawing tool* (which does
   not). Trust that doc.
2. **The gap is depth, not breadth.** Nearly every tool exists in some form;
   what is missing is each tool's *variants and options*. That is a different
   shape of work from G1–G7 and produced two new goals, G8 and G9.

**One claim to re-check rather than act on.** The "Grid and sketch settings"
video says Shapr3D squares the view to the sketch plane on entry, whereas
`STATUS_AND_NEXT_STEPS.md` records our "draw from the current camera" behaviour
as a *parity improvement*. The videos are two years old; confirm against
current Shapr3D before treating either reading as settled.

**Acceptance**
- The "Create basic 3D geometry" tutorial can be followed end-to-end in the app
  without substituting a different tool for any step.
- Offsetting a model edge into a sketch, extruding the loop with 10° of draft,
  and reordering that extrude above the shell all survive a save/reload and a
  parametric rebuild.
- Every sketch and modeling hotkey the tutorials press does what the video
  shows, and no hotkey fires while a text field has focus.

### G8 — Every feature's operands and options editable in History *(spec §10.1)*

**The structural modeling gap, and the one the manual makes impossible to
miss.** Every Shapr3D tool's History card exposes its full parameter set,
including its *references*: Extrude shows Profile / Sides / Extent / Draft
Angle / Start / Result + Target; Union shows Target / Tool / Type / Keep
Target Bodies / Keep Tool Bodies; Sweep shows Profile / Path / Profile
Position / Orientation / Twist / Scale / Corner type. Each reference row is a
live `Edit…` / `Select…` picker, so "re-pick the profile this extrude uses" is
a first-class edit — and the manual's own repair flows depend on it
("remove the missing face from a Face Offset selection", "re-select the
original face to fix a broken Shell").

We already have the hard half. `FeatureKind` stores real operand references —
`ProfileRef`, `AxisRef`, `PlaneRef`, `BodyRef`, `FaceRef`, `EdgeRef` — and
topological naming re-resolves them across a rebuild. What is missing is the
UI: `HistoryPanelView` exposes exactly **four** editable scalars (distance,
pattern count / spacing / angle) and no reference pickers or option controls
at all. So a feature's geometry is parametric while its inputs are frozen at
creation time.

**Acceptance**
- Every `FeatureKind` case renders its full parameter set in its History row.
- Reference rows re-enter the matching pick mode, and committing re-resolves
  and rebuilds downstream.
- A feature whose reference went stale offers the re-pick as the repair, which
  is what closes the loop with the error badge §18 already specifies.

### G9 — Tool variants and options *(spec §1.x, §4.x, §5.x)*

Breadth exists; depth does not. Each row below is the *default path only* in
our app. Ordered roughly by how often the manual reaches for them.

| Tool | Missing variants / options |
|---|---|
| Extrude *(§4.1)* | **Extent**: To Object, Through All (+Flip); **Start**: Offset (start/end), From Plane; Draft Angle (G7.2); explicit boolean Target picker |
| Chamfer/Fillet *(§4.3)* | Chamfer 2-distance; Fillet **Chordal**; **Corner** Rolling Ball vs Setback; **Continuity** G1/G2; profile slider + magnitude (−1…1); Overflow (Auto/Cliff/Smooth/Notch); Include Tangent Edges toggle; Y-shaped blend |
| Booleans *(§4.6–4.8)* | **Keep Target Bodies / Keep Tool Bodies** (Shapr3D's All / Modified / Removed / None); switching Type after the fact |
| Offset Face *(§4.2)* | **Distance Type**: Radius/Diameter, **Total** (with opposite-face pick), Offset; automatic tangent-face inclusion |
| Sweep *(§4.11)* | Profile Position (Auto / path intersection / closest point / closest endpoint); Orientation (normal-to-path vs parallel); Twist; Scale; Corner type (mitre/round) |
| Loft *(§4.5)* | **Guide curves**; **connection points** (vertex mapping / de-twisting); Periodic Loft; start/end tangent continuity + magnitude |
| Split Body *(§4.9)* | Multiple cutters at once; sketch profiles, body faces/edges, images, and a body's own face as cutters; Keep Originals |
| Revolve *(§4.10)* | **Height** → helical bodies (coils, springs, threads) directly from Revolve; ours needs the separate Helix tool |
| Rectangle *(§1.5)* | Center and Three-point variants (Diagonal only today) |
| Polygon *(§1.8)* | Pre-defined Triangle/Pentagon/Hexagon/Octagon menu |
| Circle / Ellipse / Polygon / Rectangle *(§2.2)* | **Type-ahead numeric entry**: typing a value mid-draw, before placing the second point |
| Text *(§1.12)* | **Alignment** setting; gizmo positioning pass after Continue |
| Constraints *(§3.2)* | **Disconnect** (break connected points, dropping their coincident/midpoint constraints); **Anchored Sketch Entity** (First/Last Selected) setting; Always Show Constraints / Always Show Dimensions toggles |

**Not in this table because they already have goals:** spline drawing (G5.1),
sketch Offset Edge (G7.1), sketch Pattern (G5.3), construction planes and axes
(§6.1/§6.2 — note `ConstructionAxisKit` has all five axis constructions tested
with no document entity or UI), Replace Face / Offset Edge 3D / Wrap & Emboss
(G4, all kernel-only).

**Acceptance:** for each row, the variant is reachable from the tool's own bar
(not only from History), and round-trips through save/reload and a rebuild.

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

G8 Editable history params ──► G9 Tool variants and options
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

**G8 comes before G9, and the order is not arbitrary.** Most of G9's options
are per-feature parameters, so G8's parameter-rendering layer is the surface
they get added to — building it first means each G9 row is "add a case", not
"add a case and invent a place to put it". G8 also stands on its own: without
it a feature's inputs are frozen at creation time, which is the difference
between a history that records what you did and one you can actually edit.

Both are independent of the kernel track. Sequenced after G7, since a tool the
user cannot reach at all outranks an option on a tool they can.

**Milestone definition of done for "modeling core parity":** the end-to-end
scenario in §1 completes with analytic results and a clean parametric rebuild —
i.e. G1–G4 plus the top three items of G5. **G7 is the separate "a beginner can
finish the official tutorial" bar**, and is worth tracking on its own.

**Three bars, not one.** Keeping them apart stops "are we at parity?" from
collapsing into a single unanswerable question:

| Bar | Means | Gated by |
|---|---|---|
| **Reachable** | every tool in the manual has a UI entry point | G7 + the kernel-only tools in G4/G5 |
| **Exact** | results are analytic and survive a rebuild | G1–G4 |
| **Complete** | each tool's variants and options are all there | G8 + G9 |

Today we are strongest on *reachable*, mid on *exact*, and weakest on
*complete* — see the manual audit in §2.

---

## 6. Non-goals (deliberate gaps)

Called out so they don't get mistaken for oversights:

- **Variable-radius and G2 blends** — partial in OCCT; accept the gap.
- **Parasolid-grade boolean robustness on dirty imported geometry** — OCCT is
  weaker here; mitigate with shape healing and the Euclid fallback.
- **Wrap & Emboss** *(§4.15)*, **Replace Face on complex surfaces** — deferred
  until the core above is solid.
- Anything outside the modeling core (drawings, sync, AR, collaboration).
