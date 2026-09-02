# Incremental evaluation — memoised replay (design)

Status: **SLICES 1 + 2 LANDED (2026-09-02).** Slice 1 = the pure
`FeatureGraph` memo (journal + fingerprint + cache, `EvalCache.swift`,
`IncrementalEvalTests`); slice 2 = `DocumentSession` wiring (cache threaded
through `performRebuild`, skip-unchanged `ReplaceBodyCommand`, adoption of
the document's bodies after apply, cached copies for the read-only replays).

**Measured after, same document and script as the table below:**

| document | trivial 10×10×5 box extrude | RSS per op | undo |
|---|---|---|---|
| light | **0.03–0.05 s** | +0.1 MB | — |
| heavy (60M mm³ wheel chain) | **0.04 s** (was 18–21 s, ~500×) | **+0.2 MB** (was +70 MB) | **0.04 s** (was a full replay) |

Suite 1139/1139. What remains from §4.5 is orthogonal: off-main evaluation
(S1) and GPU buffer pooling (S2) — this is the "don't recompute" layer
underneath both.

## The measured problem

`FeatureGraph.evaluate` replays EVERY non-suppressed node into a fresh
`EvalState` on every command. Nothing is remembered between replays. The
real-part validation pass put numbers on it (2026-09-01/02):

| document | trivial 10×10×5 box extrude | RSS |
|---|---|---|
| light (3 lock bodies) | **0.6 s** | 330 MB, +4 MB/op |
| heavy (+ 60M mm³ wheel: revolve + mirror + union) | **18–21 s** | 790 MB, **+70 MB/op** |

The same op is 30× slower and leaks ~70 MB per op because each command
re-runs the wheel's revolve, mirror and union and allocates their B-reps
and meshes afresh. `refreshEvalErrors` (load, undo, redo) does the same full
replay just to collect error badges, so undo in a heavy document costs the
same 18 s. Single parts are instant; an assembly-sized document is unusable.

## Why nothing today can be reused

- `evaluate(sketches:planes:naming:nextRevision:)` builds `EvalState` from
  scratch; the only skip that exists is `referencedSketchIDs`, used by
  `rebuildForSketchChange` to leave nodes a sketch edit does not touch —
  sketch-edit-scoped, and it still replays everything else.
- `ReplaceBodyCommand.apply` re-mints `meshRevision` unconditionally, so even
  an identical replay body invalidates the GPU cache when it is applied.

## Design: memoised replay

**Invariant:** a node's output delta is a pure function of (its kind, its
suppress flag, the content of every sketch/plane it references, and the
content of every body it consumes) — evaluated in graph order. So: fingerprint
those inputs; if the fingerprint matches the previous replay's, re-apply the
previous delta instead of running the kernel.

### 1. Fingerprint (per node, per replay)

```
fp(node) = hash( json(node.kind, sortedKeys), node.suppressed,
                 json(sketch) for each referencedSketchID (sorted),
                 json(plane)  for each referenced construction plane,
                 stamp[b]     for each consumedBodyID (sorted) )
```

- `FeatureKind` is Codable, not Hashable; hashing its sorted-keys JSON is
  exact (the kind IS its persisted form) and avoids adding Hashable to a
  dozen payload types. Sketch/plane JSON is hashed once per replay into a
  `[SketchID: UInt64]` map, not per node.
- **`stamp[bodyID]`** is the fingerprint of the node that last `put` that
  body. Booleans replace their target, so the boolean's fingerprint becomes
  the target's stamp and everything downstream re-fingerprints. This is a
  Merkle chain: nothing depends on `meshRevision`, so there is no one-time
  spurious re-run after a body's revision is re-minted on apply.
- `consumedBodyIDs` mirrors `referencedSketchIDs`: boolean → target + tools;
  transform/mirror/pattern/chamfer/fillet/shell/deleteFace → `body`;
  pushPull/moveFace/scaleFace/rotateFace/replaceFace → `face.body`;
  extrude/draftExtrude/revolve/sweep/loft → `boolean.resolvedTargets`;
  primitive → none. A consumed body missing from the state hashes as 0 —
  deterministic, and the node errors anyway.

### 2. Journal (per node, recorded while it runs)

`put` and `remove` are the only two mutation choke points in `EvalState`.
While node N evaluates, `state.currentNode = N` and every `put`/`remove`
appends to `journal[N]` as an ORDERED op list; at node end each put is
back-filled with the kernel-face names the op wrote after its put, and the
node's error (if any) is captured. Replaying a cached node = re-applying
that op list, then setting its stamps. `proposedUpgrades` are deliberately
NOT cached: the live path applies them as `EditFeatureCommand`s, which
changes the node's kind and hence its fingerprint, so it re-runs once and
stops proposing — a skipped node never re-proposes an upgrade it already got.

### 3. Cache (value type, held by the session)

`EvalCache = [FeatureID: (fingerprint, delta)]`, passed `inout` to a new
`evaluate(..., cache:)` overload; the existing 4-argument `evaluate` keeps
its exact behaviour (no cache) so every pure-value test is untouched. After
a replay the cache is pruned to the nodes still in the graph.

### 4. Session wiring (slice 2)

- `performRebuild` threads `evalCache`. After `perform(CompositeCommand)`,
  the cache **adopts the document's bodies** for every id just applied:
  the same content with the re-minted revision AND shared copy-on-write
  storage, so the cache does not double the document's geometry.
- **Skip unchanged bodies at the command level.** With adoption, a spliced
  body carries the document's own revision, so `performRebuild` emits no
  `ReplaceBodyCommand` when `body.meshRevision == existing.meshRevision`:
  no apply, no re-mint, no GPU rebuild, no undo noise. A node that actually
  re-ran minted a fresh revision, so it still replaces. This is the half of
  the win the GPU sees.
- `refreshEvalErrors` and `inputBody(for:)` evaluate against a COPY of the
  cache and discard it — fast, and they still never mutate the document or
  the live cache. Undo/redo in the heavy document stops costing a replay.

### Undeclared-input review (2026-09-02, after landing)

Every read of a body from replay state in `FeatureGraph.swift` was mapped to
its enclosing eval and checked against `consumedBodyIDs`:

- `evalExtrude` and the shared `emitFullSolid` (draft/revolve/sweep/loft's
  boolean-into-target path) read `boolean.resolvedTargets` — declared.
- `evalBoolean` reads target + tools; `evalPushPull/MoveFace/ScaleFace/
  RotateFace/ReplaceFace` read `face.body`; `evalEdgeBlend` (chamfer,
  fillet), `evalShell`, `evalDeleteFace`, `evalMirror`, `evalPattern` read
  their `body` — all declared.
- There are **no scans** over the body set (`.values`, `.first`,
  `state.order`, iteration): nothing resolves a ref by searching bodies.
- Faces and edges resolve through the declared body's own face table
  (`ElementNaming.kernelFace(of:)`), never another body's.
- `TopoNaming` has one implementation, `SignatureNaming`, a value type with
  no stored state — so a spliced node skips no naming-side mutation.

So the invariant holds for every kind in the codebase today; gotcha 19 in
`STATUS_AND_NEXT_STEPS.md` is the rule for keeping it that way.

### Correctness argument and the conservative default

A node is skipped only when everything it declares as input is unchanged.
Path dependence is preserved because stamps are assigned in graph order and
consumed in graph order. The risk is an UNDECLARED input: an op that reads
state beyond its refs. Every kind's inputs are enumerated above from its
associated values; an op found to read anything else must either declare it
in `consumedBodyIDs` or be marked never-cached (always re-run, exactly as
today). Correct-by-default beats fast.

### Acceptance

1. Pure: replay a graph twice with a cache — the second replay runs zero
   kernel ops for unchanged nodes (observable: their bodies keep the same
   `meshRevision`); editing one node re-runs it and its dependents only;
   a boolean's target edit re-runs the boolean, its tool edit likewise; a
   node that becomes suppressed/unsuppressed invalidates; results are
   identical to the uncached replay body-for-body.
2. End to end: the heavy-document trivial extrude drops from ~18 s to the
   light-document ~0.6 s, and RSS stops growing per op.

Ledgered against §4.5 of `STATUS_AND_NEXT_STEPS.md` (off-main eval S1 and
scene caching S2 remain separate; this is the "don't recompute" layer under
both).
