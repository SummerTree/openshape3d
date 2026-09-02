# Off-main evaluation (S1) — design note

Status: **DESIGN + SLICE 0 LANDED (2026-09-02).** Slice 0 = the rebuild
planner extracted from `performRebuild` as a pure function
(`RebuildPlanner.plan`, `openshape3d/Model/RebuildPlanner.swift`) with
`RebuildPlannerTests` pinning the diff semantics as values: fresh-document
adds, unchanged rebuild → no commands, edit → one replace, removed node →
delete, consumed tool never reaches the document, metadata preserved,
leading commands first. Verbatim extraction, zero behaviour change; suite
1146/1146. Slices 1–3 below are not started.

## Why now

`INCREMENTAL_EVAL_DESIGN.md` removed the *recompute-everything* cost: an
unchanged node is spliced, not run. What is left on the main thread is the
kernel work of the nodes that DID change — and a single heavy node still
blocks the UI for its own duration (the 60M mm³ wheel's union takes seconds;
a fillet on a complex body likewise). Memoisation made this tractable: 

- `FeatureGraph.evaluate(sketches:planes:naming:nextRevision:cache:)` is a
  pure function of **value-type inputs** — `FeatureGraph`, `[Sketch]`,
  `[ConstructionPlane]`, `SignatureNaming` (a struct), `EvalCache` (a struct)
  — and returns a value (`EvalResult`) plus the rewritten cache. It has no
  main-actor dependency except the `nextRevision` closure.
- So a rebuild can be: **snapshot on main → evaluate detached → apply on
  main.** The kernel never touches the document; the document never touches
  the kernel mid-flight.

## What must stay on the main actor

`DocumentSession` is `@MainActor`. These stay there:

1. **The snapshot**: copying `document.features` (with the pending edit
   applied), `document.sketches`, `document.planes`, `naming`, `evalCache`.
   Value copies; cheap (copy-on-write).
2. **Applying the result**: `performRebuild`'s diff → `ReplaceBody` /
   `AddBody` / `DeleteBodies` / upgrade `EditFeature` commands → one
   `CompositeCommand` → `perform`. Unchanged.
3. **Revision minting.** `DesignDocument.nextRevision()` is a `mutating`
   counter on the document. Off-main, evaluate mints from a **local counter
   seeded at the snapshot** (`base = document.revisionCounter`, mints
   `base+1…base+k`), and the apply step first **reserves** the document's
   counter past `base+k` (`document.reserveRevisions(through:)`) before any
   command applies — so every revision stays globally unique.
   `ReplaceBodyCommand.apply` re-mints from the document anyway; spliced
   bodies carry adopted document revisions and are skipped, as today.

## Staleness and cancellation

Edits can arrive faster than a heavy node evaluates.

- Each rebuild request increments a `rebuildGeneration`; the detached task
  carries the generation it was computed for. On completion, **apply only
  if it is still the latest**; otherwise drop the result.
- A newer request **cancels** the in-flight task. The replay loop gets an
  `isCancelled: () -> Bool` hook checked between nodes (a node's own kernel
  call is not interruptible — OCCT has no cancellation — so the granularity
  is one node; the memo keeps the redo cheap).
- The cache returned by a stale or cancelled run is still **safe to keep as
  the starting cache** for the next request: entries are content-keyed
  (fingerprint → delta), so any node unchanged between the stale run and the
  current one hits. Its bodies carry snapshot-minted revisions that never
  reached the document, so they compare unequal on apply and get replaced
  once — correct, one extra replace. Adoption (`EvalCache.adopt`) happens
  only on a real apply, as today.
- **Interaction lock**: while a rebuild is in flight, tools that would
  start ANOTHER rebuild queue behind it (the existing `isRebuilding`
  re-entrancy guard becomes an async gate), and the History panel shows the
  rebuilding node. This is also what keeps the C4 path-dependence caveat
  honest: no command applies against a document mid-rebuild.

## The real cost: the synchronous contract

Today `performRebuild` returns with the document already updated, and its
callers rely on that:

- In `DocumentSession`: `rebuildFrom`, `setSuppressed`, `deleteFeature`,
  `rebuildForSketchChange`, `performWithSketchRebuild` (the atomic
  sketch-edit + rebuild step, S6).
- Above them: the editor's tool commits (`commitToolResult` and the feature-
  edit panel), the History panel toggles, and the agent's `/v1/exec`, which
  **returns the post-op state in its HTTP response** — the rebuild scripts
  read `producedBodyIDs` and `/v1/state` volumes immediately after.

Making rebuild async means every one of those either `await`s it or is
rewritten to observe completion. Surveyed 2026-09-02: `performRebuild` has
**9 callers inside `DocumentSession`** (feature edit, suppress, delete,
reorder, sketch-change rebuild, the atomic sketch-edit step, variables) and
those have **17 call sites in 3 files** outside it (`AgentBridge`,
`EditorViewModel`, `HistoryPanelView`). That ripple — not the evaluation —
is the size of S1. Two ways to slice it:

- **S1a — off-main with a synchronous facade. REJECTED on reflection
  (2026-09-02).** A `@MainActor` method cannot "await and yet return
  synchronously": the only way a synchronous caller keeps its contract while
  the kernel runs elsewhere is a nested run loop (`RunLoop.main.run(mode:
  before:)` spun until the task lands). That does process touches and
  redraws, but nested run loops under SwiftUI are the classic fragility —
  re-entrant actions, transactions and animations mid-loop — and the
  `isRebuilding` guard would turn a user's second tap into a silent no-op.
  Not a foundation to build on.
- **S1b — true async contract. The path.** `performRebuild` becomes
  `async`; the 9 session callers become `async`; the 17 external call sites
  either `await` (the agent's `/v1/exec` must — it returns the post-op
  state) or become fire-and-forget `Task { await … }` where nothing reads
  the result synchronously afterwards (UI toggles, whose views observe the
  document anyway). Sliced so each step gates on the unit suite:
  1. Session: `reserveRevisions(through:)`, snapshot → detached evaluate →
     apply, `isRebuilding` as an async gate, in-session callers `async`.
  2. External sites, audited one by one for synchronous result reads
     (see the audit below); the agent awaits, UI callers wrap.
  3. Cancellation + coalescing (generation tag, between-node cancel hook,
     stale-cache reuse) and the responsiveness UI test.
  Full UI suite at the end (46.5 min).

### Call-site audit (2026-09-02)

What follows each of the 17 external calls decides its migration:

- **Must `await` (reads the rebuilt document right after):** the agent's
  two sites (`rebuildForSketchChange` → `execOK` response; `rebuildFrom` →
  `producedBodyIDs`/`changedBodyIDs`); the editor's feature edits
  (`editFeature` → `save()`, and one selects the produced body), `delete
  Feature`/`setSuppressed` → `sanitizeAfterHistoryChange()` (reads the
  document for ghost picks), and every `performWithSketchRebuild` followed
  by `save()`. That is nearly all of them — "fire-and-forget" applies only
  to the History panel closures and the two `rebuildForSketchChange` calls
  that just reset `mode`.
- **The sketch-edit split.** `performWithSketchRebuild` is one atomic undo
  step (S6): the sketch command and the body rebuild. With an async rebuild
  the sketch command must still apply **synchronously** (drawing feedback
  cannot wait for a kernel), and the body commands are **amended into the
  same undo step** when the eval lands (`undoStack.amendLast` exists for
  live drags). Undo of that step then reverts both, as today.
- **Verification gap.** `DocumentSession` is never instantiated in unit
  tests (SwiftData), so today an async `performRebuild` could only be
  verified by the 46-minute UI suite or the live app — too weak a net for
  a concurrency change on the central mutation path.

### Revised slicing (supersedes the list above)

0. **Extract the rebuild planner as a pure function — first, and unit-test
   it now.** `performRebuild` is snapshot → evaluate → diff (skip-unchanged
   replace, add, delete, upgrade edits) → one `CompositeCommand` → adopt.
   Everything before `perform` is a pure function of values:
   `RebuildPlanner.plan(graph, sketches, planes, naming, cache, liveBodies,
   ownedIDs, title) -> (commands, cache, errors, faceTables, kernelNames,
   resultBodies)`. `performRebuild` becomes `plan` + `perform` + adopt.
   Zero behaviour change; the diff logic (which today is only exercised by
   UI tests) gets pure-value tests: skip-unchanged, add, delete-consumed,
   upgrade edits, adoption. This is the seam the detached evaluate needs.
1. Session: `reserveRevisions(through:)`; `plan` runs detached with a
   snapshot; `performRebuild` async; in-session callers async.
2. External sites per the audit (agent first — its scripts verify the
   post-op contract end to end — then the editor, then History).
3. Cancellation + coalescing + the responsiveness UI test; full UI suite.

Out of scope here: **live tool previews** (drag-to-extrude recomputing per
gesture frame) — the "/preview service" half of S1 in the old backlog. They
do not go through `performRebuild`; separate note when they are next.

## Acceptance (for S1a)

1. Main thread never blocks longer than one frame during a rebuild: a DEBUG
   main-thread watchdog (or `os_signpost` around `performRebuild`) shows the
   kernel time on a background thread and the apply step under 16 ms.
2. During the heavy wheel union, a tap on a palette button registers within
   100 ms (UI test), and the orbit gesture keeps animating.
3. Rapid edits coalesce: N feature edits in quick succession → at most N
   evaluations, exactly the last one applied, no stale result ever applied.
4. Results are identical to the synchronous path body-for-body (the memo
   tests already pin cached == uncached; add a detached == sync case).
5. `/v1/exec` keeps its contract: the response carries the post-op state.

## Sequencing

S1a after the memo's UI-suite gate is green. It touches `performRebuild`
(snapshot / detached evaluate / reserve revisions / apply), the replay
loop's cancellation hook, and `isRebuilding` becoming an async gate. No
kernel changes, no caller changes.
