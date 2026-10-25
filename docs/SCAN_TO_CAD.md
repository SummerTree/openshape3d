# From a 3D scan to a CAD model, over MCP — and graded by the app

A phone scan of a fire hydrant becomes a parametric OpenShape 3D model
without anyone touching the app: a script reads the scan, an MCP client
drives the app's one `os3d` tool call by call, and the app itself measures
how close the result is — orthographic silhouette overlays per view and the
distance from every sampled scan point to the model. The run writes a
transcript, pictures, an HTML report and a narrated film shot in the app.

Everything lives in `scripts/scan_to_cad/`; the app side is
`Kernel/AccuracyKit.swift`, `/v1/accuracy` (docs/AGENT_CONTROL.md), the
`accuracy` / `accuracy.image` MCP ops and Views ▸ **Accuracy Report…**.

## The worked example

The target is laanlabs' own
[Fire Hydrant TrueDepth iPhone 3D Scan](https://sketchfab.com/3d-models/fire-hydrant-truedepth-iphone-3d-scan-9152d01cb27141baa7907fe670b8d074)
on Sketchfab (CC-BY, 63,810 vertices / 114,587 faces, made with the
3D Scanner App): a textured OBJ in metres, Y up, with the sidewalk the
scanner caught around the base, the caps' chains hanging from the nozzles,
and the underside of everything missing. Sketchfab serves the download only
to a signed-in account, so the pipeline was proven on a stand-in first
(`synthetic_hydrant.py`: a scan-like hydrant from Blender, voxel-remeshed,
±0.7 mm noise, bottom missing, tilted and spun in a frame of its own) and
then run on the real file.

| Step | Real scan | Stand-in |
|---|---|---|
| Scan | 114,587 triangles; 73,831 after the ground is cropped; 858 mm tall, body radius 102.8 mm | 107,266 triangles, 706 mm tall, radius 104.0 mm |
| Axis fit | 1.5° from the file's Y | within 0.1° of the truth, origin within 1 mm |
| Bosses found | the two hose nozzles and the pumper (−102°, +80°, −19°), each as its own radius-along profile (neck, cap, nut on the cap face); a 50 mm lump on the bonnet | 3 (−143°, −52°, 128°; truth −143°, −53°, 127°) |
| MCP calls | 86, 56 s in the app | 87, 43 s |
| Revolve volume | 30,170,689 mm³, equal to Pappus from the 61-point profile | 22,072,043 mm³, equal to Pappus |
| Solid | valid B-rep, 152 faces, STL + STEP + OBJ | valid, 44 faces |
| Silhouette overlap (IoU) | front 84.8 %, top 90.3 %, right 86.9 % | 97.4 % / 98.3 % / 97.5 % |
| Scan → model deviation | mean 12.1 mm, 95 % within 58 mm (the chains, the bonnet's cast detail) | mean 1.04 mm, 95 % within 3.26 mm |
| Model → scan deviation | mean 8.1 mm, 95 % within 23 mm | mean 0.94 mm, 95 % within 3.02 mm |
| Size, model − scan | −2.6 × −13.5 × −15.9 mm | −2.9 × −4.9 × +0.1 mm |

On the real hydrant what is left in the overlays is what a body of
revolution plus four bosses cannot say: the chains hanging from the caps,
the bonnet casting sitting a few millimetres off the barrel's axis, and the
ragged bottom edge where the scan fades into the sidewalk. The stand-in,
with none of those, shows the pipeline's own floor: its 0.7 mm noise and
4 mm voxel remesh.

## Running it

```bash
cd scripts/scan_to_cad
python3 -m venv venv && venv/bin/pip install numpy trimesh rtree scipy pillow edge-tts

# 0. (no scan yet?) a stand-in
/Applications/Blender.app/Contents/MacOS/Blender -b --python synthetic_hydrant.py -- /tmp/hydrant/scan.glb

# 1. read the scan: axis, radial profile, bosses → analysis/profile.json, charts,
#    and scan_cropped.glb (the scan without the ground the scanner caught)
venv/bin/python analyze_scan.py /tmp/hydrant/scan.obj --out /tmp/hydrant/analysis --epsilon 2.5

# 2. a DEBUG build of the app with the bridge on, in an empty design
UDID=$(xcrun simctl list devices available | grep -F "iPad Pro 13-inch (M5) (" | head -1 | grep -oE '[0-9A-F-]{36}')
SIMCTL_CHILD_OS3D_AGENT=1 SIMCTL_CHILD_OS3D_FRESH=1 SIMCTL_CHILD_OS3D_AGENT_PORT=8947 \
  xcrun simctl launch "$UDID" com.laan.labs.openshape3d

# 3. build it through the MCP server, grade it, export it (the cropped scan is the reference)
venv/bin/python build_hydrant.py --scan /tmp/hydrant/analysis/scan_cropped.glb --analysis /tmp/hydrant/analysis \
  --out /tmp/hydrant/run --port 8947 --name hydrant --tolerance 3

# 4. the report and the video
venv/bin/python report.py /tmp/hydrant/run --title "Fire hydrant"

# 5. the second opinion: does it actually look like the scan? (no app needed)
venv/bin/python inspect_fit.py --reference /tmp/hydrant/run/scan.stl --model /tmp/hydrant/run/hydrant-cad.stl \
  --out /tmp/hydrant/qa --tolerance 3 --title "Fire hydrant"
open /tmp/hydrant/qa/review.png
```

`document.import` by path is a development-build op (it reads the host's
file system), so step 3 needs a DEBUG build; everything else the script
calls ships in the store app.

## Catching errors — `inspect_fit.py` and the review sheet

The first corpus reel looked fine by its numbers and wrong to the eye: the
pail was a solid drum with a lid, the bollard's dome a stack of flat steps,
the beer mug a lantern of three frustums, the barrel a closed drum with
ribs in the wrong places. The app's grade had let all of that through
(93 % front overlap on the drum, "100 %" on the bollard) because a
silhouette says nothing about what is inside it and the scan-to-model
distance says nothing about model surfaces no scan point is near. So the
process is now, after every build:

1. **Numbers both ways.** `inspect_fit.py --reference scan.stl --model
   part-cad.stl --out qa/` samples both surfaces and measures each to the
   other. The model-to-reference direction finds the lid: a drum modelled
   over an open bucket has 44 % of its area more than 6 mm from any scan
   surface. The volume ratio catches the same thing when the scan is
   closed (the barrel: 2456 %).
2. **Depth, not just outline.** For front, right, top and an isometric
   view it splats both meshes into depth maps on one grid and compares
   them where both are present: the lid sits 260 mm nearer than the
   bucket's floor, so the top view is 63 % orange. Each view also reports
   its worst of twenty horizontal strips, so a wrong top does not hide in
   a long body that fits (the bollard's dome: 6 % of the top view, 100 %
   of its top strip).
3. **A sheet to look at.** `qa/review.png` — reference and model shaded
   the same way, their silhouettes overlaid (blue where the model lacks
   material, orange where it has too much) and the depth difference, per
   view, with every check's verdict in the margin. Read it at full size;
   a contact-sheet thumbnail hides a 10 mm step. Numbers decide, the
   picture says where.
4. **A verdict that gates the rest.** `checks.json` holds every check with
   its value, limit and PASS / WARN / FAIL (limits scale with
   `--tolerance`, default 1 % of the longest extent, at least 0.5 mm).
   `run_corpus.py` runs the inspection after each build and writes the
   verdict into `results.json`; `film_corpus.py` and `reel.py` skip a
   FAIL unless `--allow-fail`.

The checks: `size` (bounding box, model − reference, per axis), `volume`
(when both meshes are closed), `ref_to_model_mean` and `ref_far_share`
(missing features), `model_to_ref_mean` and `model_excess_area` (material
the scan does not have), `terraces` (sign changes of the mean signed error
along the up axis — ridges where the scan is smooth), and per view
`silhouette_<view>` (IoU and its worst strip) and `depth_<view>` (share of
the shared silhouette more than three tolerances deeper or nearer, and the
worst strip). The depth maps are point splats, not a rasteriser: four
samples per pixel-area of surface, 1.2–8 million per mesh, and the nearest
depth over each pixel's 3 × 3 neighbourhood — with two samples per pixel
a tenth of the pixels held only a back-wall sample and the bollard read
its own thickness out over a quarter of its body.

Calibrated against the ten corpus builds as first made: eight FAIL, the
bollard and the spray can WARN (their flaw is one small region, which the
worst-strip rule now scores), and the eye agrees with all ten sheets.
Offline tests: `test_scan_to_cad.py` (a drum for a bucket fails on excess
and the top view, a terraced dome fails its top strip, an identical part
passes; the arc fitter on a rounded rectangle, a stadium, a dome).

### The largest patch (2026-10-25)

The checks above are owned by the big turned body: a valve at 94 %
overlap has its whole branch missing, a mean of 0.7 mm hides a 60 mm part
because it is small. A person judges by the biggest thing that is wrong,
so `inspect_fit.py` now finds it. The reference samples farther than
1.5 tolerances from the model ("missing": the scan has material the model
lacks) and the model samples farther than that from the reference
("excess", the hole-facing ones left out as before) are joined into
connected regions — a radius graph on the samples (`cKDTree`, radius
2.5 × the mean sample spacing, spacing = √(area / n)) and scipy's connected
components. The samples are dense enough that a 10 mm feature is a patch
of twenty-odd: one per 15 mm² of surface, at least 40 000 and at most
120 000 per mesh (the cap binds only on the barrel and the truck wheel, at
30–37 mm² a sample, and keeps the wheel at 21 s). Each patch records its
kind, area (samples × area per sample), mean and max distance, centre,
extent and a location in words against the part's bounds and up axis —
"in the upper third, on the left, towards the front"; an axis a patch spans
most of is said so ("across the width"). `checks.json` keeps the top five
of each kind under `patches` (with the total missing and excess area and
their shares at that threshold), and two checks gate on the largest:

    largest_missing_patch, largest_excess_patch   value = area in mm²
        WARN above max(300 mm², 0.25 % of the reference area)
        FAIL above max(1000 mm², 1 % of the reference area)

The `why` names the patch: *the largest missing patch is 5 218 mm²
(58 × 48 mm, 5.38 % of the reference area) in the middle third, in the
centre, 5.1 mm from the model on average, 17.9 mm at most; 45 patches of
this kind in all, 17 003 mm² together*. On `review.png` the three largest
of each kind are ringed on the reference and depth tiles (blue M1–M3,
orange E1–E3, the ring the patch's projected extent) with a legend line
each, and `views/patches.png` is the shaded reference from the four sides
with only the marks. `run_corpus.py` writes the same lines into the
results row as `qa.patches`; `film_corpus.py` prints them under a part it
skips.

Why 1.5 tolerances and not one: at one tolerance a scan's noise and cast
detail put more than a quarter of the surface over the line, and in a
radius graph that dense the far samples percolate into a single patch
the size of the part — the rusty extinguisher's largest went from
1 983 mm² (the valve knob) to 8 389 mm² (185 × 72 mm of its body at 4.2 mm)
and the hydrant's bonnet became one 223 × 221 mm patch at 4.1 mm. At 1.5
the patches are the features. The limits above are the first ones tried
and were not adjusted: on the ten corpus builds of 2026-10-24 nothing
clean fails and nothing broken passes (`--patch-far` is the knob, for the
next calibration):

| Part | Before | After | Largest missing | Largest excess | Total missing / excess | What it is |
|---|---|---|---|---|---|---|
| Rusty extinguisher | WARN | WARN | 1 983 mm² WARN, upper third, centre | 3 883 mm² WARN, middle third, right | 2.1 % / 3.6 % | the valve knob read as a plain cap; the strap handle a few mm off — the eye agrees |
| CO2 extinguisher | FAIL | FAIL | 19 620 mm² FAIL, upper third, left | 9 680 mm² FAIL, upper third, centre, front | 13.1 % / 12.5 % | the horn, hose and grip, crudely made: M1 is the horn, E1 the grip |
| Hydrant 02 | WARN | **FAIL** | 3 615 mm² WARN, upper third, centre | 10 410 mm² FAIL, middle third, right, back | 3.3 % / 3.7 % | E1 is a 173 mm wedge the model hangs under the right nozzle (orange in the silhouettes) — a real flaw the old checks let through; M1 the bonnet nut |
| Bollard | PASS | PASS | none | none | 0 / 0 | clean |
| Pail bucket | FAIL | FAIL | 71 560 mm² FAIL, middle third, left | 227 432 mm² FAIL, lower third, across the width | 15.7 % / 41.0 % | the oval scan against a round model: one side missing, the other excess, all the way round |
| Tin barrel | FAIL | FAIL | 538 003 mm² FAIL, upper third, across the width | 513 726 mm² FAIL, most of the height | 31.8 % / 33.8 % | a dented, leaning scan: a third of the surface is 9–17 mm out |
| WD40 can | PASS | PASS | none | 14 mm² PASS | 0 / 0 | clean |
| Beer mug | WARN | **FAIL** | 1 609 mm² FAIL, middle third, right, back | 2 056 mm² FAIL, middle third, right, back | 5.5 % / 5.8 % | both patches are the handle: its lower arm sits 4 mm from the scan's over 76 mm. The rough handle is the known flaw; at 1 % of a 150 000 mm² mug that is a FAIL, not a WARN |
| Truck wheel | FAIL | FAIL | 529 025 mm² FAIL, most of the height | 730 696 mm² FAIL, most of the height | 33.6 % / 36.8 % | tread and hub detail everywhere: here the story is the totals, a third of each surface, not one patch |
| Pipe wheel (valve) | FAIL | FAIL | 5 218 mm² FAIL, middle third, centre | 977 mm² WARN, middle third, right | 17.5 % / 9.4 % | M1 the left branch's elbow (the model's is straight), M2 the right branch, M3 the bottom port; the wheel's openings are the blue in the top view |

Two parts change verdict and both for a reason a person can point at on
the sheet. The other way round would be the worry — the wedge on the
hydrant is exactly the kind of thing a 98 % overlap and a 1.1 mm mean
were hiding. Offline tests: a cylinder whose 20 mm boss the model lacks
is exactly one missing patch of 1 744 mm² (the boss's 2 000 mm² less the
strip within 3 mm of the wall) "in the upper third, on the right"; the
drum for a bucket has the lid as its largest excess patch (27 000 mm² at
the rim's height); identical parts have no patch.

## Recipes — `fit_primitives.py` and `build_recipe.py`

A part that is not one revolution needs more than `build_hydrant.py`'s
recipe, and the practice piece for that was a CAD model rather than a
scan: devkrsm's
[Mechanical CAD Model Showcase](https://sketchfab.com/3d-models/mechanical-cad-model-showcase-344f5b216ee04b378c07b7f8863d737f)
(CC-BY, 11.2k triangles), a C-clamp assembly — a C-frame with a 10 mm
plate, a 30 mm rib along its inner edge, a round screw boss and lettering
pockets, plus a screw, a swivel pad, a tommy bar and two balls, six solids
in one glTF with a 0.01 scene scale. The pieces:

- `fit_primitives.py` reads geometry: `fit_sphere`, `fit_axis` (principal
  direction refined through slice centres), `radial_profile` (max radius
  per band for a CAD mesh — sample the surface, not the vertices, or a
  cylinder's middle has no bands at all), `section_loops` (a planar cut as
  2D loops), and `segments_from_loop` / `arcs_in_polyline`, which turn a
  traced loop or an open profile into `line` and `arc` segments:
  consecutive vertices turning the same way are one run, a circle is
  fitted through the run's own vertices (a tessellated arc's tangent points
  are vertices turning by half a step, so they belong to the run), and the
  arc is kept when every point sits within the tolerance; a run that does
  not fit is split at its longest edge (two corners with a line between
  them turn the same way). Collinear mid-chord vertices and 0.25 mm stubs,
  both common in CAD tessellations, are merged first. `sketch_entities`
  writes the app's entities, arcs counter-clockwise with the line ends
  snapped onto the arcs so the loop closes exactly.
- `build_recipe.py` executes a JSON recipe over MCP: `extrude` parts with
  a sketch plane (origin, xAxis, yAxis in world mm; the extrude goes along
  xAxis × yAxis), an outline of segments or a circle, a distance and an
  optional boolean into an earlier part; `revolve` parts with an axis and a
  radial profile or a sphere's arc. It finds the extrude's seed point by
  walking in from the outline, checks every body and exports each one and
  all of them together for `inspect_fit.py`.

The clamp recipe (rib outline from a section at z = 12, plate from z = −4.5,
bore circle from a section through the boss, profiles of the turned parts
at 0.5 mm bands, spheres at the bar's ends) built in 58 MCP calls and
first inspected WARN: the top view showed blue on the screw boss. The
boss is round — an r 15 cylinder about the screw's axis on the arm's
block, a D in the x = −85 section — and the rib outline had squared it.
With the block clipped at the axis and the cylinder unioned in before the
bore is cut, the inspection passes at 0.5 mm: silhouettes 99.5–99.8 %,
mean distance 0.05 mm one way and 0.08 mm the other, volume 102 % (the
raised lettering, 0.2 mm tall, is the difference). The sheet, the recipe
and the run live in `marketing/scan-to-cad/practice/clamp/` (gitignored).

## How each piece works

### `analyze_scan.py` — what the scan is

1. **Axis.** The scan's frame is the phone's. Each of the three principal
   directions of the vertices is tried as the axis and refined by fitting a
   line through the centres of forty thin slices along it; the one whose
   slices are the roundest wins (`axis_quality`: the share of all vertices
   that sit on their slice's fitted circle — a hydrant about its own axis
   scores ~0.6–0.8, sliced across ~0.3). The largest direction alone was
   wrong for a bucket, whose handle's arch pulls PCA 20° over (every band
   then read a sine wave around the axis), and for a wheel, whose axis is
   its thinnest direction. `--axis largest|middle|smallest|X,Y,Z` forces
   it. When no principal direction is clean (quality under 0.75 — a pipe
   valve, whose principal direction is the diagonal between its body and
   its pipe and scores 0.65 against 0.64 for the body itself), the axis
   finder's strongest body of revolution is the main axis instead (see
   *More than one axis* below: the body holds 31 % of the surface in
   rings, the diagonal 4 %). `--units <mm per file unit>` overrides
   the format's units: Sketchfab glTF scans come at any scale (a bollard
   12 m tall, a spray can 1.3 m), and `scan_cropped.glb` is always written
   at the corrected size, so the app imports it right. Each slice centre is a RANSAC circle fit (three random
   points, count the points within 2.5 mm of that circle, keep the best,
   then an algebraic fit on the inliers) — a nozzle's points never lie on
   the barrel's circle, so they are ignored rather than pulling the centre
   toward the nozzle. The first version used the slice's bounding-box
   centre and sat 12 mm off toward the pumper nozzle; the top-view overlay
   showed it as a crescent. Only the slices that are a clean ring vote for
   the line — more than half their points on one circle, of about the
   typical radius — and the vote is taken twice, without the centres that
   still sit off the line: a flange, the nozzle band and the dome give
   centres that are off by a bolt ring or a cap, and a line through all
   forty again sat 12 mm beside the barrel, so that every sector read a
   different radius (93 to 121 mm around one 107 mm band) and no profile
   taken from them could be clean. A ring must also have been seen most
   of the way round — no empty arc wider than 120° about its centre: a
   slice through a pail's handle is two short arcs, a circle through both
   passes the share test with a perfect score, and those slices had the
   pail's axis bouncing between 4° and 17° off from one round of the fit
   to the next (the model came out visibly tilted in the front view).
2. **Up.** When the axis is within 30° of the scan's +Y, +Y is up (glTF
   and the app agree on Y up; a valve's hand-wheel is wider than its
   base); otherwise the wider end is the base. `--flip` inverts either.
   The body
   ends where the rings do: a band whose points leave more than a third
   of the circle empty (a bucket's handle arching above the rim, a lever
   across a valve) is not the part's cross-section, and the revolve stops
   under the run of such bands at the top (`topNotARingMM` in the JSON);
   the handle's "radius" shrinking toward its apex had read as a dome over
   the bucket. A coarse mesh's dome has a dozen points per band spread
   all the way round and stays. The comparison still sees the whole scan,
   so the handle shows as missing — which it is. The scanner's ground — bottom bands
   whose radii spread over a wide range, where a band of the part is a thin
   ring — is trimmed, and the scan is written out again without it
   (`scan_cropped.glb`, metres, texture inside) so the comparison is hydrant
   against hydrant. The revolve starts where the scan has solid coverage,
   not in the sparse last bands above the sidewalk.
3. **Profile.** Vertices are binned in 4 mm height bands. The band's body
   radius is what most 10° sectors agree on — the densest ±3 mm cluster of
   the per-sector median radii, not a percentile of them: at the nozzle
   band three caps, their flared roots and the chains hung from them fill
   most sectors, only 2–9 of 36 still show the barrel, and a percentile
   climbed onto the caps (the revolve grew rings there). A cluster that
   continues the band below (within 6 mm, at least two sectors) wins over a
   denser one — a barrel does not jump 100 mm between bands; a flange does,
   and its cluster is nowhere near the band below. A spike of one or two
   bands between bands that agree is a cap filling the sectors, not an
   8 mm flange. Then `straighten`: a run of bands whose radii agree within
   ±3 mm with no trend from its first third to its last becomes ONE
   vertical segment at their median (a cylinder; a run that drifts is a
   dome or a cone, and collapsing it cut the bonnet into terraces), a jump
   in radius over little height a level step (a flange face), and what is
   left — a cone, the dome — keeps its points for Douglas–Peucker at
   1.5 mm. The hydrant's barrel is one segment from 262 to 578 mm; the
   first films had traced the scan band by band and the barrel came out
   ridged where the casting is smooth.
4. **Bosses.** On the (band × sector) grid, cells whose maximum radius
   stands more than 6 mm proud of the band's body radius are grouped by a
   watershed from their peaks (regions merge only across a saddle at least
   60 % as high as the lower peak). Each region is judged on its core —
   cells at least half as proud as its peak, in bands at least three
   sectors wide — because a cap's chain hangs as far from the axis as the
   cap and would otherwise tie it to a flange ring below or drag its centre
   down. Rings (a flange step straddling two bands, broken into pieces by
   scanner holes) are dropped by angular extent. A boss is centred on its
   widest band (a cap fills many sectors, the chain hanging from it one or
   two — and it reaches as far as the cap, so neither the farthest cell nor
   a weighted centre is safe from it), gets its direction from its cap's
   face (the farthest points), its centre height from the median height of
   that face's points within the wide bands (a cap is a disc; the top edge
   minus the neck radius had put the pumper 20 mm low because its flared
   root is wider than its cap — the deviation preview showed the model
   missing the cap's top half), and a radius-along profile
   read in 8 mm slices as the horizontal half-extent (chains hang down, so
   the horizontal extent is clean) among the points within the lump's own
   azimuth span plus a sector each side (a fixed 60° reached the next
   nozzle's cap) — the flared casting, the threads, the cap and the nut on
   its face come out as steps. Dropped afterwards: a lump whose root is
   wider than twice its neck (a thin spike on a wide base — a chain link, a
   flange's edge), and one that sits within 40 mm under a flange and
   reaches less than 30 mm past its rim (bolts, the eyelets the chains hang
   from, the chains), and one that runs on into the non-ring top (the
   handle's root). The pumper nozzle really is ~200 mm wide. `--debug`
   says why every candidate lump was dropped, and prints each kept one's
   slices.

`profile.png` (radius by height, with the polyline) and `azimuth.png` (the
band × azimuth map: nozzles are blobs) are written for the report.

### A corpus of scans — `run_corpus.py`

Ten more Sketchfab scans (CC-BY; `marketing/scan-to-cad/corpus/`, gitignored:
two extinguishers, a second hydrant, a bollard, a pail, a tin barrel, a
spray can, a beer mug, a truck wheel, a pipe valve) exercise the same
recipe. One folder per part: `download/scan.glb` as it came, `prep/scan.glb`
when one mesh had to be picked out of a multi-mesh file, `analysis/` from
`analyze_scan.py` (`analysis-flags.json` lists each part's flags), and
`spec.json` — what the part is for the build and the film: `label`,
`color`, title and narration lines, the `credit` line. `run_corpus.py
corpus/ --port 8947 --python venv/bin/python` relaunches the app in an
empty design before each part, runs `build_hydrant.py` (`--label`,
`--color` from the spec) and `report.py`, then `inspect_fit.py` into
`<part>/qa/` (its verdict lands in the row as `qa`), and writes
`results.json` — the app's own numbers per part, or the error that
stopped it. `--analyze` re-runs `analyze_scan.py` first (`--epsilon 2.5`
plus the part's flags). `film_corpus.py` then films each built part the
way the hydrant was filmed (`demo_video.py take --ui --spec` and `compose
--spec`, one music bed for the series), skipping a part whose inspection
FAILED unless `--allow-fail`; `reel.py` leaves such a part out the same way.

The ten, built on 2026-10-21 (every one a valid solid; overlap is the mean
silhouette IoU over the three views, the deviations are mean surface
distances, calls are all the MCP calls of the build including its checks
and the report):

| Scan (Sketchfab, CC-BY) | Calls | Overlap | Model→scan | Scan→model | Note |
|---|---:|---:|---:|---:|---|
| Fire Extinguisher Old Rusty 3D Scan — grafi | 62 | 92 % | 8.0 mm | 4.9 mm | the valve outlet as a boss; the carry handle stays out |
| Fire Extinguisher — 3dhdscan | 54 | 70 % | 4.5 mm | 57.2 mm | scanned on its head (`--flip`); hose and valve stay out |
| Scan Fire Hydrant 02-Freepoly.org — Freepoly.org | 78 | 96 % | 4.6 mm | 6.1 mm | three nozzles as bosses |
| Concrete Bollard Scan 01 · Retopologized — Kai Moisch | 54 | 100 % | 3.8 mm | 0.6 mm | file in cm (`--units 100`) |
| Pail Bucket Plastic 3D Scan — grafi | 54 | 76 % | 7.9 mm | 12.9 mm | the handle stays out (not a ring); the ring rule fixed a 7° tilt |
| Old tin barrel — 3dhdscan | 54 | 97 % | 9.7 mm | 5.2 mm | one mesh picked out of three (`prep/`) |
| WD40 Scan LOWPOLY — sixonetwo | 54 | 98 % | 0.8 mm | 1.2 mm | 1.5k triangles (`--band 6`); odd file units (`--units 160`) |
| Bavarian Beer Mug - #KitchenScanChallenge — Antoine Dresen | 54 | 91 % | 1.8 mm | 6.3 mm | the handle stays out; the liquid's discs dropped (`prep/`) |
| Truck wheel with rusty rim — Оrрндп ЯТG | 54 | 85 % | 9.7 mm | 23.1 mm | tyre and hub as one profile; the rim's bracket is not a boss |
| Pipe Wheel 3D scan — grafi | 54 | 43 % | 11.4 mm | 13.8 mm | a valve with a handwheel: two axes, the recipe takes one |

Findings: a handle (bucket, mug) and a hose are not turned shapes and stay
out of the model — the Deviation Preview shows them in blue, which is the
point; a low-poly scan (1.5k triangles) needs wider bands (`--band 6`); a
valve with a handwheel has two axes and the recipe takes one (43 %, the
honest failure of the set). Two more downloads were dropped before a
build: a candelabra (not one revolution) and a gas valve (a box with a
wheel).

Rebuilt on 2026-10-22 with arcs, hollow sections and the inspection in
the loop (`run_corpus.py --analyze`). The app's overlap barely moves —
it never saw the flaws — while the sheets and the model-to-scan distance
do; the verdicts are strict, and what still fails is what a single
revolve cannot say (an arrow marks a number that changed):

| Scan (Sketchfab, CC-BY) | Overlap | Model→scan | Scan→model | Inspection | What the sheet shows |
|---|---:|---:|---:|---|---|
| Fire Extinguisher Old Rusty 3D Scan | 92 % | 8.0 mm | 4.9 mm | FAIL | the carry handle and the valve lever are missing (size, top view) |
| Fire Extinguisher | 70 % | 4.5 mm | 57.2 mm | FAIL | hose and valve missing; the lever had been read as a ring |
| Scan Fire Hydrant 02-Freepoly.org | 96 % | 4.6 → 4.1 mm | 6.1 mm | FAIL | nozzle caps and the bonnet's casting sit a few mm off; a trimmed ground |
| Concrete Bollard Scan 01 | 100 % | 3.8 → 2.0 mm | 0.6 mm | WARN | dome now an arc to its apex (was a stepped cap); the shoulder step is sharper than the scan's |
| Pail Bucket Plastic 3D Scan | 76 % | 7.9 → 5.4 mm | 12.9 → 14.7 mm | FAIL | now a 3 mm shell with its lip (was a solid drum); the handle is missing and the scan is oval |
| Old tin barrel | 97 % | 9.5 mm | 5.2 → 4.2 mm | FAIL | now an open 2.4 mm shell with ribs (was a solid drum, volume 2456 %); the scan leans off the fitted axis |
| WD40 Scan LOWPOLY | 98 % | 0.8 mm | 1.2 mm | WARN | a cone for the rounded shoulder and cap |
| Bavarian Beer Mug | 92 % | 1.7 mm | 6.5 mm | FAIL | belly now an arc (was three frustums); the handle is missing; the lid reads closed |
| Truck wheel with rusty rim | 85 % | 9.7 → 9.3 mm | 23.1 → 23.5 mm | FAIL | tyre and hub as one profile; the rim's dish and bracket are not |
| Pipe Wheel 3D scan | 43 % | 11.4 → 9.7 mm | 13.9 mm | FAIL | two axes, the recipe takes one |

A FAIL here is not filmed and not in the reel without `--allow-fail`;
the films and reels made on 2026-10-21 predate the rebuild and show the
old models.

Rebuilt on 2026-10-24 with every axis of revolution found (`fit_axes.py`,
*More than one axis* below), the residual fit's bars, no spikes to the
apex and a hand-wheel's openings cut (`run_corpus.py --analyze`; every
one a valid solid):

| Scan (Sketchfab, CC-BY) | Overlap | Model→scan | Scan→model | Inspection | What changed |
|---|---:|---:|---:|---|---|
| Fire Extinguisher Old Rusty 3D Scan | 98 % | 0.8 mm | 0.9 mm | WARN | strap handle, knob and outlet as features |
| Fire Extinguisher | 92 % | 3.7 mm | 2.5 mm | FAIL (depth) | no spike to the apex; hose, horn, grip and levers as features |
| Scan Fire Hydrant 02-Freepoly.org | 98 % | 1.1 mm | 1.8 mm | WARN | the three nozzles are bodies on their own axes (the twin side nozzles one axis through the barrel, split at it); was 6.3 mm |
| Concrete Bollard Scan 01 | 100 % | 1.4 mm | 0.6 mm | PASS | unchanged |
| Pail Bucket Plastic 3D Scan | 77 % | 1.8 mm | 2.3 mm | FAIL (oval scan) | unchanged |
| Old tin barrel | 97 % | 5.0 mm | 7.1 mm | FAIL (dented scan) | the floor disc is no longer trimmed as a sidewalk |
| WD40 Scan LOWPOLY | 99 % | 0.2 mm | 0.3 mm | PASS | unchanged |
| Bavarian Beer Mug | 97 % | 1.1 mm | 0.7 mm | WARN | unchanged (its handle's arms are no bodies: the scan runs on past them) |
| Truck wheel with rusty rim | 95 % | 9.3 mm | 4.9 mm | FAIL (depth) | the stand's post and beam as bars; was 89 % / 17.9 mm |
| Pipe Wheel 3D scan | 95 % | 0.7 mm | 2.0 mm | FAIL (depth) | body, pipe, two branches and side port on five axes, hand-wheel openings; was 65 % / 8.2 mm |

The depth checks (2–3 mm) still fail where a scan is oval or dented, on a
tyre's tread, and on cast detail a revolve smooths over; the silhouettes
pass everywhere but the oval pail's top view.

Rebuilt on 2026-10-25 with the model painted the scan's colour, the
inspection gated on the largest unexplained patch and the parts library
(*Colour*, *The largest patch* and *The parts library* below; `run_corpus.py
--analyze`; every one a valid solid). The last column is the biggest thing
still wrong, in the inspection's own words:

| Scan (Sketchfab, CC-BY) | Overlap | Model→scan | Scan→model | Parts fitted | Largest patch |
|---|---:|---:|---:|---|---|
| Fire Extinguisher Old Rusty 3D Scan | 98 % | 0.8 mm | 0.9 mm | 3 plates | missing 1 983 mm², upper third, centre (the knob) — WARN |
| Fire Extinguisher | 95 % | 3.5 mm | 1.7 mm | hose, horn, bar, sweep, 2 plates, revolve | missing 6 517 mm², upper third, right (the valve head) — was 92 % |
| Scan Fire Hydrant 02-Freepoly.org | 98 % | 1.1 mm | 1.8 mm | 3 plates, chain | missing 3 615 mm², upper third, centre (the bonnet nut) |
| Concrete Bollard Scan 01 | 100 % | 1.4 mm | 0.6 mm | none | none — PASS |
| Pail Bucket Plastic 3D Scan | 96 % | 1.6 mm | 2.1 mm | handle sweep, 3 plates | missing 72 720 mm², middle third, left (the oval scan) — was 77 % |
| Old tin barrel | 97 % | 5.0 mm | 7.1 mm | none | missing 538 003 mm² across the upper third (dented, leaning scan) |
| WD40 Scan LOWPOLY | 99 % | 0.2 mm | 0.3 mm | none | excess 14 mm² at the nozzle tip — PASS |
| Bavarian Beer Mug | 97 % | 1.4 mm | 0.8 mm | handle sweep, lug, lid lever | missing 3 112 mm², upper third, right, back (the handle) |
| Truck wheel with rusty rim | 94 % | 8.2 mm | 4.8 mm | 3 bars | missing 920 952 mm² over the tyre (tread, hub) |
| Pipe Wheel 3D scan | 95 % | 0.7 mm | 2.0 mm | 2 plates, 3 lugs | missing 5 218 mm², middle third, centre (the left branch's nut) |

What a person still sees: the valve's branch nuts and flange (the
secondary bodies get no feature pass yet) and its filled bores (the
excess patches); the CO₂ extinguisher's valve head as a tube, not a
lever; the oval bucket and the dented barrel (the scans); the tyre's
tread and hub detail.

### The reel — `reel.py`

One film of the whole corpus, cut two ways: `reel-16x9.mp4` for a page or
a channel and `reel-9x16.mp4` for a phone. `reel.py corpus/ --port 8947
--derived-data …` first puts the simulator in the pass's orientation
(`rotate_device`, `rotate.log` in the orientation's folder) and then runs
the app inside the film's take UI test, one fresh session per part. An
iPad simulator boots in portrait, and `XCUIDevice.shared.orientation`
turns it to landscape from there — but not back: with the device in
landscape, the take test (`OS3D_TAKE_ORIENTATION`) and the one-shot
`RotateDeviceUITests` both log "Setting device orientation to Portrait"
and the home screen, the app and every recording stay landscape (a
portrait pass on a landscape simulator filmed ten clips on their side —
the landscape picture inside the portrait framebuffer, exactly what the
landscape pass records — twice). So portrait is a `simctl shutdown` and
`boot`, landscape is the rotate test, and the run ends by turning the
device back to landscape for the part films. Clearing the design over the bridge
between parts left the previous model standing beside the next scan, so
every part starts the app again; the session's control server closes its
socket when the part is done (`shutdown` alone leaves it bound, and a
later session died on "Address already in use") and takes the first
free port. Each session opens a new
design, imports the scan with its base on the floor, rebuilds the model
from the part's analysis with the build's own half-section
(`build_hydrant.body_section`), films the Deviation
Preview turning over the dark studio backdrop and then the pair — the
untinted scan beside the model — turning: two short clips per part, over
the bridge; a part that fails is tried once more in a session of its own.
`compose` (or `--skip-take`) lays a title over the first pair, one segment
per part (the pair, then the preview) sized to the part's narration line,
and an outro over the last pair. The 16:9 cut crops the iPad's screen in on
the parts — a 16:9 window around where they are, found from a frame (the
backdrop is one flat colour, the app's chrome masked), with a tenth of
headroom — and lays the caption pills over it; the 9:16 cut keeps the
whole portrait screen at the phone's width and writes the captions in the
bands above and below it (a line wider than the frame breaks at its ` · `
separators — the subtitle and the outro's links once ran off both edges;
the contact sheet's tiles are too small to show that, so check a frame of
the 9:16 cut at full size). Every pair segment, the title's included,
starts 3 s into its clip, past the app's "Imported 1 part" notice; the
title line outlasts what is left of its 10 s pair, so a segment holds its
last frame (`tpad`) when the source runs out. The narration goes through `demo_video.narrate`
(Gemini 3.8, each line cached by its text; `--tts edge` for a stand-in
voice), the per-part line is the spec's `reelSay` with `{label}`, `{iou}`
and `{mean}` filled from `results.json`; one music bed under it all. Next
to the films: `script.txt` (the lines with their cues), `captions-16x9.srt`
and `captions-9x16.srt`, `credits.txt` (every scan's author, licence and
link) and `post.txt` (a paragraph for the post, credits appended).

### `mcp_client.py` and `build_hydrant.py` — building it over MCP

`MCPClient` speaks JSON-RPC 2.0 over the stdio of `scripts/mcp_openshape3d.py`
exactly as Claude Desktop does — `initialize`, `notifications/initialized`,
`tools/list`, then `tools/call` on the one `os3d` tool — and logs every call
(`mcp_client_calls.jsonl`; the server keeps its own log through
`OS3D_MCP_LOG`). `transcript_markdown()` writes the session up as a table.

The recipe, in `os3d` calls:

| Step | Calls |
|---|---|
| Handshake and state | `health`, `state` |
| Import the scan | `document.import {path}` → a mesh body placed as the file places it; `body.setMaterial` (see-through grey-blue) |
| The turned body | `sketch.create` on the fitted axis (`origin` = axis origin, `xAxis` = azimuth 0, `yAxis` = the axis), `sketch.addEntities` with `body_section(analysis)` — the half-section as a closed loop with the axis at u = 0: lines, lines and arcs when the analysis found a dome or a belly, or a hollow half-section for an open container — then `feature.revolve` 360° about `[0,0]`,`[0,1]`. `demo_video.py take` and `reel.py` call the same `body_section` and `boss_section`, so a film shows the model the inspection graded |
| Each boss | `sketch.create` through the boss's own axis, 12 mm inside the body (`xAxis` = axis × direction, `yAxis` = the direction); `sketch.addEntities` with its radius-along profile closed back along the axis; `feature.revolve` 360° with `"boolean":"union"` — a body of revolution about its own axis, unioned into the barrel |
| Verify | `check` (valid solid), `state` (volume; the revolve's volume is held to Pappus from the profile's own area and centroid) |
| Pictures | `command.run view.*` + `view.fit`, `screenshot`; `item.setHidden`; `view.visualize` for a studio render |
| Grade | `accuracy {reference: scan, model: cad, tolerance, views}` → `accuracy.json`; `accuracy.image {view}` → the three overlay pictures |
| Export | `document.export` STL / STEP / OBJ of the model, STL of the scan; STL after every feature (`stages/`) for the video |

Because the model is built on the scan's own axis and base, the comparison
runs with `align: none` — no registration between scan and model, so the
numbers include any axis error.

### `AccuracyKit` — how the app grades it

`Kernel/AccuracyKit.swift` is pure value math (Foundation + simd), the same
on iPad, Mac and in the browser build:

- **Silhouettes.** Both bodies, placed in the world, are projected along a
  standard view direction and rasterised on one shared grid (512 px across
  the longer side, a one-pixel empty border). Pixel centres inside a
  triangle are filled; edge-on triangles fill nothing (a first version
  marked their pixels and spilled one pixel past the silhouette onto the
  border, where an outline cannot close). IoU is overlap over union; the
  areas are pixel counts. Each silhouette's outline pixels are measured to
  the other's with an exact Euclidean distance transform (Felzenszwalb &
  Huttenlocher), pooled both ways: mean, RMS, 95th percentile, max.
- **Outlines.** Marching squares over the pixel centres; crossings are
  keyed by the grid edge they sit on and the loops walked in linear time
  (the first version chained segments by endpoint distance, which was
  quadratic — 19 s on the hydrant; now about 4 s for the whole report in a
  Debug build). Loops are oriented by nesting: outer counter-clockwise,
  holes clockwise.
- **Surface deviation.** Up to 20,000 points of one surface (its vertices,
  thinned) are measured to the nearest point of the other's triangles,
  bucketed on a uniform grid sized to the mesh's density (compressed rows,
  ring-by-ring search), with Ericson's closest-point-on-triangle. Both
  directions; signed by the triangle normal so the bias says whether the
  model is under- or oversized.
- **Watertightness** after welding coincident vertices (a textured scan's
  UV seams are not holes), the volumes, bounds and a plain-English
  `summary`.

Views ▸ **Accuracy Report…** runs the same comparison off the main thread
and draws the overlays with SwiftUI `Canvas`; Share saves the page as an
image or copies the summary / JSON. `AccuracyKitTests` (11), the router and
MCP tests pin the behaviour with boxes of known overlap.

### `demo_video.py` — the film, shot in the app

`--spec part.json` (both `take` and `compose`) makes the one script film
any part: the label names the sketch, the colour paints the model, the
captions and narration lines replace the hydrant's (`{calls}`, `{mean}`,
`{iou}`, `{label}` are filled in), and the credit line names the scan's
author. The hook's step-aside scales with the part (a little under half
its size), so a 60 mm can and a metre of bollard both share the frame
with their scan. `demo_video.py take` records the iPad simulator (`simctl io recordVideo`)
while the recipe runs over MCP at a camera's pace (the body's half-section
and each boss's profile come from `build_hydrant.body_section` and
`boss_section`, the build's own; the take and the reel used to trace their
own loop from the straight profile, which after the arcs and hollow
revolves would have filmed the old solids) — the textured scan
appearing and turning, the revolve, each nozzle with the view still
turning, a slow turn in Visualize with the panel kept closed
(`view.visualize` with `panel: false`), the Accuracy Report on screen, and
last a hook. With `--ui` the app is launched by `TutorialTakeUITests` (the
YouTube series' remote-controlled touch test, `scripts/youtube_series/
common.py`) and the report is opened the way a person opens it — the Views
menu, Accuracy Report…, the sheet with its pickers already on the mesh and
the solid, Compare, a scroll through the results, Done — real taps on the
recording; the take marks `computeStart` / `computeEnd` so the cut skips
the computing wait. Those taps go through SpringBoard (the test's
`raw_tap` / `raw_tap_at` / `raw_drag` actions): an open menu and a sheet
computing behind a ProgressView keep the app from reporting idle, and an
app-side XCUITest tap then stalls for up to 60 s. The Views menu is taller
than a landscape iPad shows, so the take scrolls it before tapping. Without `--ui`, `view.accuracyReport` opens the sheet
from the agent. The hook: the model steps aside (`feature.transform`; an
imported mesh cannot move, so the feature body does) and a fresh copy of
the scan is imported beside it, both turning in the studio — on a dark
backdrop (`--hook-background`, default white) so the photo texture and the
red model pop. An import lands selected, and a selected body is drawn with
45% of the accent blue mixed into its texture (hiding and showing it does
not clear that), so the take clears the selection with `item.select`
(`ids: []`) right after each import — the one agent op this film added.
The film's copy of the scan stands with its fitted base at the origin
(`scan_on_floor`), so the studio floor is under it and the ground shadow
lands where a shadow should. The take writes `take.mov` and a
`timeline.json` of when each beat happened (and when its picture was
ready). `compose` resamples the recording to a constant 30 fps (the
simulator writes a frame only when the screen changes, so a still moment
has none and a cut through it is empty), turns it upright (the framebuffer
stays portrait with the landscape picture inside it; a one-shot UI test,
`RotateDeviceUITests`, turns the device), crops each beat to 16:9 (the
toolbar in frame for the build, closer on the pair for the opening and the
ending, the whole screen on a blurred copy for the tall report sheet),
cuts each beat to its narration and lays a caption pill over it. A line
that would still be running when the next beat's line is due holds that
line back by the overlap and a breath, so a longer line costs a slightly
later cue, never two voices at once. Given
`--report` and `--overlays`, a report beat follows the sheet: the HTML
report itself scrolling from its title to the overlays (headless Chrome at
a 1.5× device scale, so the text is crisp at 1920), a sheet of the three
orthographic overlays with their overlap, and the front view panned top to
bottom at full width, so the blue (scan only) and orange (model only)
margins read. There are no cards: the film opens on the hook footage under
the title and closes on it under the numbers and the credits. It narrates (Gemini TTS — `gemini-3.8-flash-tts` through the Developer API
when a key is in `GEMINI_API_KEY` or `~/.config/openshape3d/gemini-api.key`,
mode 600 and outside every repo; else the Vertex AI catalog through
`gcloud auth`, which stops at `gemini-3.1-flash-tts-preview`; else the
edge-tts voice — `--gemini-model` picks another), adds a music bed (Lyria through Vertex AI, else a
generated one; looped to the film's length first, because an endless
`-stream_loop` input into `amix` never ends and the mux hangs) and writes
`<name>.mp4` plus a contact sheet.

    venv/bin/python demo_video.py take --scan …/scan_cropped.glb --analysis …/analysis --out …/demo --port 8947 --hook-background 0.13 0.14 0.16 --ui --derived-data ~/Library/Developer/Xcode/DerivedData/openshape3d-…
    venv/bin/python demo_video.py compose --out …/demo --name fire-hydrant-demo --report …/report.html --overlays …/run/overlays [--tts gemini --music lyria]

### `report.py`

`view.deviationPreview` (2026-10-21) puts the comparison on the part in
the viewport: the scan coloured by its distance to the model — blue where
the model is missing material, orange where it has too much, grey within
tolerance — the model ghosted behind it, a legend with the per-vertex
numbers. The Accuracy Report sheet's "Show Deviation in Viewport" row and
Views ▸ Deviation Preview do the same by hand; the film's report beat ends
on it. It is the feedback loop the rules above ask for: a ring the scan
does not have, a nozzle set too low, a lug that should not be there all
show as colour where they are, before any number is read.

`report.py` inlines the app's overlay pictures, screenshots, the deviation
histograms (SVG), the size table, the recipe and the MCP transcript into
one HTML file. (The first film was rendered in Blender by `make_video.py`
and `blender_video.py`; `demo_video.py`, shot in the app itself, replaced
them on 2026-10-20 and they were removed on 2026-10-21. `synthetic_hydrant.py`
still uses Blender, to make the stand-in scan.)

### The fine trace — how the profile got its detail (2026-10-22)

"Almost none of the CAD models are good matches": the spray can had come
out as four points — a cone for a shoulder, no crimp, no valve cup, no
foot — because the trace read vertex *bands* 4–6 mm tall and simplified at
2–2.5 mm. `analyze_scan.py` now traces the **surface**:

- 200 000 points are sampled over the faces (seed 7) and added to the
  vertices, so a low-poly can with one vertex row every 10 mm is read
  between its rows too. Faces that look along the axis within 10° (ends,
  shelves) are left out — a band through a flat top would read the disc's
  spread of radii as the wall's — and only points facing **away** from the
  axis (normal·radial > 0.2) define a band's radius: a bucket or a drum is
  scanned inside as well as out, and the band used to land on whichever
  wall had more points. The wall thickness is median(outward r) −
  median(inward r) (`detect_open_top`).
- `estimate_noise` reads the scanner's point noise off the cylinder bands
  (half the 16–84 % spread inside a band × sector cell) and sets the band
  at 3× that (1–4 mm). The profile's own noise is the 80th percentile of
  the band medians' distance from a 12 mm running median, and sets the
  simplifier at 2.5× that (0.4–2.5 mm; a noisy profile never finer than a
  thousandth of the height, a clean one — a bollard's collar — keeps its
  1 mm steps). `--band` and `--epsilon` default to `auto`;
  `corpus/analysis-flags.json` holds per-part overrides.
- An out-of-round body (a squashed pail, a dented drum: ±6–7 mm) is read
  as its mean circle — the densest ±3 mm cluster of a sinusoid sits at an
  extreme, so the band's radius is refined with a reach of 3 × 1.48 × MAD
  of the sector medians. A lobed flange (a hydrant bonnet's bolt lugs,
  8–14 mm between lobe and hollow on a 110 mm ring) keeps the radius the
  band below settled on (`agreed_radius` continuity = max(6 mm, 8 %)), and
  the running median smooths flips under a seventh of the radius.
- Arcs (`arcs_in_polyline`): three vertices suffice on a fine trace; a
  chord under 10 mm or a bow under max(2ε, 1 mm) is lines; a clean scan's
  tolerance is max(4 × noise, 0.2, 0.6 % of the radius) plus a facet
  allowance of gap²/8r for a low-poly mesh's chords, capped at 1.5
  tolerances (a drum's 230 mm quad once excused a 21 mm residual). A dome's
  arc is carried to the axis (tail ≤ max(4 bands, 12 mm, 0.2 R)); a
  polyline that stops under the apex is carried to it — but only a cap's
  worth, a gap of at most max(2 bands, 0.6 × the last radius): a valve's
  lever 76 mm above the last ring and an extinguisher's handle 97 mm
  above it had come out as spikes to the apex; they are the residual
  fit's. An "arc" that rises less than max(3 bands, 0.4 × what it
  narrows by) is a step with a band caught between (a 6 mm stem out to a
  34 mm rim over 2 mm; a rim's flat top in to its hub over 5 mm) and
  stays lines — three points on a step fit a circle as well as a
  quarter-round does. A gap in the bands (the stem under a hand-wheel,
  hidden from the scanner) carries the lower radius up to the gap's end
  and steps there, instead of a cone from the band below to the band
  above.

`body_section` (build_hydrant.py — the build, the film and the reel all
revolve it): `keep_off_axis` pulls an arc end that rounding put at
u = −8e-5 back to u = 0.05 (a profile across the axis revolves to
`emptyGeometry`); `sketch_entities` snaps lines onto the arcs' *computed*
ends and bridges arc-to-arc gaps (a 0.007 mm gap is "revolve profile
unresolved" — the detector bridges nothing). A **container** is a solid
revolve plus the cavity — the outer profile eroded a wall in
(`fit_primitives.cavity_section`), from the floor (where the profile first
reaches 0.9 × the widest it gets in the bottom quarter, one wall up) to
5 mm past the open rim — revolved with `boolean: subtract`. The one hollow
loop offset round a ribbed profile folded over itself; the kernel's shell
refused the barrel at every wall.

### Dished parts — the half-section tracer

A truck's dual wheel (two tyres, a dished rim, a hub, an axle) has two
rings in one band 400 mm apart with nothing between: one radius per
height cannot say it. `surface_grid` collapses every point to (r, h)
cells (cell = max(band, 2 mm)); a cell is surface when ≥ 35 % of the 24
azimuth sectors reach it (a bracket or a handle fills a few and is left
out). `is_dished` asks, on a stricter 60 % grid, for rows holding two ring
runs more than 40 mm apart, on a part with no open end (a bucket's floor
sits a wall in from its skin and is no dish). Then `trace_section` decides
inside/outside from the 8 nearest surface cells' mean outward normals
(a flood from the outside leaked through every hole in the scan; ray
parity was fooled wherever the outline ran along the ray), fills holes,
keeps the largest component, chains the cell edges into the outline,
simplifies it at 0.9 cell and `refine_section` moves the axis-aligned runs
onto the points' medians. `analysis["sectionLoop"]` is then the sketch
loop itself (`body_section` seeds it with `section_seed`), and the lumps
the boss detector found are left to the residual fit.

### What the revolve cannot make — `fit_features.py` and `build_features.py`

    python3 fit_features.py --scan run/scan.stl --model run/part-cad.stl --analysis analysis/profile.json --tolerance 2 --out features/
    python3 build_features.py --features features/features.json --run run/ --port 8947

`run_corpus.py` runs both after the revolve (`--no-features` skips;
`FIT_DEBUG=1` is set so `<part>/features.log` says why each fit won or
lost). The scan's triangles farther than max(4 mm, 2.5 tolerances) from
the model are split by adjacency into pieces; a piece that is a *sheet*
(95 % of it within max(2 far, 12 mm) of the model, or area > 25 × that
distance²) is the body's own surface — an out-of-round wall — and is
reported, not fitted. Each other piece is tried three ways and the best
coverage wins (+0.08 for a sweep, +0.05 for a revolve; a sweep is kept
from 25 % since each of its runs is proved on its own points, a revolve
or a block from 50 %), and what it leaves uncovered is split and tried
again to depth 3:

- **sweep** — a handle, a hose, a strap. Rays from the points inward give
  the chord, so the radius r₀; the points standing clear of the body
  (> max(3 far, 2 r₀) — the lugs a wire hooks into and the rim they sit
  on would tangle the path) are binned by geodesic distance from one end
  on a kNN graph, a tube's width per bin with a score of points each, so
  each bin's mean sits on the centreline and the order cannot double
  back. Runs of one radius (±35 %) are each proved on their own points
  (≥ 60 % within tolerance of the tube); a run whose radius grows
  steadily is a **cone** and becomes a revolve about its own line (a CO₂
  horn); runs of a steady radius within 1.6× of each other merge into
  one sweep (a stein's handle, thick above, thin below); ends march in
  1 mm steps into the body (`reach_body`) so the union fuses. The
  section is a circle, or an oval written as the draughtsman's four
  tangent arcs (`oval_entities`) — a true ellipse section sweeps to an
  invalid shell ("boolean: the tool solid is invalid").
- **revolve** — `fit_axis` on the piece, roundness per band (circle
  residual ≤ max(2 tol, 12 %), centre within max(2 tol, 10 %)) on ≥ 60 %
  of the bands, then the 75th-percentile radius per band (a thin horn
  shows two skins), simplified; the end that meets the body runs 4 mm
  past `far` into it.
- **extrude** — PCA gives the plane and the thickness (3rd–97th
  percentile along the thin axis); the outline is an alpha shape of the
  projected points (alpha = max(3 × spacing, 1.5 mm, 0.6 t)), simplified,
  turned into lines and arcs by `segments_from_loop`, extruded
  symmetrically; a face that meets the body is grown into it. Covered
  means within tolerance of the slab's *surface* — a face or the edge —
  not merely inside it (a wire arch sits inside an 8 mm slab shaped like
  itself without touching its faces).

`build_features.py` builds the list into the revolved body over MCP with
`boolean: union` (one sketch + one op each; a refused feature is undone
with `edit.undo` and recorded), then re-runs check, the app's accuracy
report and the exports; `summary.json` gains `features`. `demo_video.py
take` and `reel.py` build the same list (the features the summary says
were ok) through `build_features.build_feature`, each under its own
caption, so a film shows the model the inspection graded.

What this gave, 2026-10-22: the can PASS at 0.3 mm with every ring; the
bollard PASS with its dome and collar; the mug its lid, handle and lever;
the pail its wire handle and lugs; the CO₂ extinguisher its hose, horn
and valve; the rusty one its carry handle; the dual wheel its tyres, dish
and hub; the valve its stem, hand-wheel, side port and branch. The pail
and the drum stay FAIL on depth: the scans are out of round by ±6–7 mm
and a revolve cannot follow a squashed bucket — say so rather than chase
it. The wheel's stand and the valve's threaded nipple are still rough.

### More than one axis — `fit_axes.py` and the secondary bodies (2026-10-24)

A valve is a vertical body with a horizontal pipe into it, two branches
and a side port: four bodies of revolution on four axes. One axis and one
profile cannot describe it — revolved about the pipe's axis the body was a
43 mm drum, the pipe's nipple end a cone to the apex, the branches lumps —
and it scored 65 %. `analyze_scan.py` now asks `fit_axes.py` for every
axis first.

- **Directions** come from the normals: on a cylinder every normal is
  perpendicular to the axis, so the cross product of two nearby normals
  points along it. Pairs within 8 % of the diagonal vote on a 2° sphere
  grid (smoothed over 1.5 cells, since the main axis sits on the equator
  and would split four ways); the principal directions join the list so
  a barrel-shaped mug, which has no cylinder to vote with, gets its axis
  too. Distinct directions only (a noisy scan's main axis peaks again
  7–10° off).
- **Positions**: for a direction, every normal line crosses the axis, so
  projected along the direction the normal lines meet at the axis's
  point — a vote along each line (both ways; a scan's normals are not all
  outward) in a plane grid. Each candidate is refined on its inliers (the
  points whose normal line passes within a tolerance — 1.2 % of the
  diagonal, 1.5–12 mm — of the axis): least squares on the normal lines
  for the point, the ring-centre fit for the direction.
- **A body is rings.** A normal line through the axis is a loose test: a
  flat face whose plane holds the axis direction (a nut's side, a block's
  wall) and the skin of another body the axis happens to cross both pass
  it in stripes. So the inliers are sliced along the axis and a bin is a
  ring only when the medians of at least ten of 24 sectors agree within
  max(12 %, min(2 tolerances, 30 %)) of the radius — a flat lever 8 mm
  thick is no 14 mm bar — and only the points on that ring are the
  body's. Its extent runs from the first ring bin to the last (a body
  keeps its rings across the band where a pipe joins it), plus two bins
  of inliers at each end for a rim with its hub.
- **Selection is best-first, outside what is already taken.** The main
  axis comes first (the tracer's choice, or the strongest candidate).
  Every later candidate is judged on the points *outside* the accepted
  bodies' envelopes, skin included: a branch's axis runs on into the pipe
  it leaves, where the pipe's skin, cut obliquely, passes for rings; the
  twin side nozzles of a hydrant share one axis through the barrel, whose
  crossing band is no ring at all. It must show rings of its own there
  (roundness ≥ 0.7, 60 % unclaimed, ≥ 0.8 % of the surface, at least 12 mm
  and 0.6 radii long), and it must **run into** an accepted body — its
  axis, followed up to 0.8 radii past an end, enters one (a pipe runs
  into the body it feeds; a hose alongside a tank never enters it), or
  passes through one with rings on both sides (the twin nozzles; not a bar
  laid across a valve's top). A free end must be free: scan surface
  straight on past it (within 1.2 radii, up to half a radius beyond) means
  a bend — a mug handle's straight arm — not a body of revolution. At each
  step every remaining candidate is judged afresh and the one with most
  fresh ring points taken: a line parallel to the barrel through a cap's
  chain explains more normals than the nozzle's own axis, but fewer rings.
- **Faces are labelled** by the same rule (`label_faces`): a face goes to
  the axis its normal line crosses most closely, among those whose
  envelope reaches it; a later body takes a face from an earlier one only
  when it explains the normal clearly better (a quarter tolerance — on the
  barrel's own skin the side nozzles' axis passes as close as the
  barrel's). A face no normal line claims (a hex nut's flats) goes to the
  body whose ring radius it sits just under; the rest — spokes, a lever, a
  chain — stays with the main trace, as before.

Then the main trace runs on the faces that are the main body's or
nobody's (the pipe's rings in the body's bands had made a drum of the
body; the ground trim is judged on the main body's own points, a hex nut
100 mm out having read as a sidewalk), and each other body is traced by
the same function on its own faces with its axis fixed (`secondary=True`:
no ground trim, no bosses, no flip, no open top, no apex carry; the main
trace's band and simplifier, since the scanner's noise is the scan's).
Its **root** — where its rings are cut by the parent's skin, over
2 r_parent / tan θ along a branch leaving at θ, plus a fifth of its own
radius — is cut off (`trim_profile`), and the body is lengthened into its
parent at the first clean radius by min(r_parent, 0.6 r + 2 tolerances)
plus the root (`extend_profile`; the new line meets the first segment
exactly — the profile's rounded radius sat 0.02 mm off it: "revolve
profile unresolved"). A boss candidate that is a traced body (the pipe
off a valve, a hydrant's nozzle) is dropped. The analysis JSON lists them
under `bodies` (frame, profile, segments, parent, junction, what was
trimmed and added); `build_hydrant.secondary_sections` turns each into a
sketch plane through its axis and the half-section to revolve, and the
build, the film and the reel revolve them 360° with `boolean: union`
right after the main revolve (and a container's cavity), in the
finder's order, so each union meets material already there.

**A hand-wheel's openings.** One radius per height makes a wheel a disc.
`find_windows` looks, in the (r, h) grid, for rows that hold a run of
ring cells near the axis facing out (the hub — a bore's wall faces in and
is no hub) and, past a gap of 6–60 mm that fewer than 65 % of the sectors
reach, another run (the rim). Three or more such rows are a window; the
spokes are where the middle half of that annulus has points, on 48
sectors (five spokes leave openings under 60°), and what lies between
them, half a sector short of each spoke, are the openings — each a partial
revolve of the annulus rectangle about the axis, on a sketch plane turned
to the opening's first azimuth, revolved by its span and subtracted
(`window_sections` / `cut_window`; the build, the film and the reel). The
valve's wheel: five openings of 30° between hub r 14 and rim r 28 over
h 228–240. A solid flange has no hub run beside it; a thin wall's two
skins are a cell or two apart; a stem in a cup is a recess and is cut as
one. Not on open containers, dished parts or secondary bodies.

What it finds: the valve's body (29 %), pipe (19 %), both branches, the
side port — the 54 mm stub at the bonnet's height took the horizontal
direction until the direction list stopped filling up with the main
axis's neighbours; the hydrant's twin side nozzles (one body through the
barrel) and the pumper nozzle; nothing on the can, bollard, barrel, pail,
mug, both extinguishers and the wheel (the CO2 extinguisher's horn and
hose run into nothing; the mug handle's arms run on into their bends; the
handle bars across the CO2 extinguisher's valve are no rings at 30 % of
their radius). Tests: a synthetic T (a body with a pipe into it — two
bodies, the pipe's extent stopping at the body's skin, its faces
labelled), a lone cylinder, `trim_profile` / `extend_profile`, and the
ring-over-continuity rule.

### Colour — the model painted like the scan (2026-10-25)

The films and the reel used to paint the model from a hand-picked `color`
in each part's `spec.json` (hydrant red by default), so a red valve stood
beside a grey scan and a yellow can beside a blue one, and the eye read
the colour mismatch as a shape mismatch. The model's colour now comes
from the scan's own texture:

- `analyze_scan.scan_color(source)` samples ~20 000 surface points
  (area-weighted faces, barycentric UVs looked up in each geometry's
  base-colour image, times the material's base-colour factor; vertex
  colours are the fallback, a plain mesh gives None) and finds the
  dominant colour by k-means into four clusters. The winner is not the
  raw largest cluster: a spray can's white lettering, bare-metal ends and
  highlights make one light cluster of 40 % against the label's blue at
  31 %, and a person still calls the can blue — so each cluster's share is
  weighted by one plus its saturation ((max − min) / max of its centre)
  before the largest is taken, and the swatch is the mean of that
  cluster's samples. A painted colour thus beats a neutral one of nearly
  twice its area, while a grey bollard or a white mug, with no saturated
  cluster of any size, stays grey or white. Shadow baked into the texture
  is lifted (a colour whose brightest channel is under 0.25 is scaled up
  to 0.25, hue kept — the truck's black tyre). The analysis JSON records
  it as `"scanColor": {"rgb": [r, g, b], "share": <raw share of the
  winning cluster>, "source": "texture" | "vertex"}`, read off the source
  file's scene (the cropped copy may have lost its texture); the scene is
  loaded once and shared with the geometry, because a 4096² RGBA PNG
  costs five seconds to decode and the colour itself takes 0.1–0.6 s.
- `spec_color.model_color(spec, analysis)` (re-exported by
  `build_hydrant`): a spec `color` that is a list is itself; `"scan"` or
  no `color` at all is the analysis's `scanColor`, and hydrant red when
  the analysis has none (older analyses). `build_hydrant.py --color scan`
  (the default now), `run_corpus.py` (the build and `inspect_fit.py
  --model-color` painted alike), `demo_video.py take --spec` and `reel.py`
  all resolve the colour this way; every corpus spec now says `"color":
  "scan"`. The resolver lives in its own standard-library-only module
  because `run_corpus.py` runs under whatever `python3` is on the path and
  hands the venv to the scripts it launches — importing it from
  `build_hydrant` dragged numpy in and broke `python3 run_corpus.py`.
  `--color` refuses anything but `scan` or three numbers with the usage
  line (`--color scan 1 2` used to die in `float('scan')`).
- Two edges fixed in review: the base-colour factor multiplies in linear
  light (glTF's rule — half of white is 0.735 in sRGB, not 0.5; none of
  the ten corpus scans carries a factor, so their swatches did not move),
  and `analyze()`'s re-trace of a drum whose open rim came out at the
  bottom now forwards `source`, so the inner call that writes
  `profile.json` records `scanColor` too (checked on a synthetic cup
  standing on its rim: the re-trace fires and the profile carries the
  colour; a test reads the call in place because a full run takes 40 s).

Measured on the ten corpus scans (sRGB in 0…1, the share of the samples
in the winning cluster): rusty extinguisher 0.49 0.28 0.27 (42 %), the
3dhdscan extinguisher 0.73 0.34 0.28 (56 %), hydrant 0.52 0.09 0.10
(31 %), bollard 0.52 0.47 0.39 (37 %, a warm khaki grey — what its
texture holds), pail 0.51 0.55 0.59 (31 %), tin barrel 0.53 0.51 0.51
(40 %), WD-40 can 0.06 0.09 0.40 (32 %, blue; the raw largest cluster
was the light one at 40 %), beer mug 0.87 0.88 0.87 (47 %), truck wheel
0.25 0.23 0.24 (36 %, lifted from a near-black tyre), pipe valve 0.38
0.38 0.34 (41 %). Offline tests: a quad with a 70/30 texture gives the
70 % colour within 0.03, a 45 % white / 40 % blue / 15 % yellow texture
gives blue, a white texture under a 0.5 factor gives 0.735, vertex
colours and a plain mesh, `model_color`'s and `--color`'s cases, and that
the resolver imports nothing.

### The parts library — `fit_features.py` names what it fits (2026-10-25)

Nearly every visible error the corpus had left was a recognisable part
fitted as a lump: the CO₂ extinguisher's grip, hose and horn as three
overlapping sweeps on one piece (radii 19, 8 and 26 mm), the stein's
handle as two sweeps with a block at the knuckle, levers and lugs as
blobby alpha-shape extrudes. Real parts are designed — a lever is a bar
with rounded ends, a nut a regular hexagon, a flange a rectangle with
rounded corners, a hoop a ring on the body's own axis, a hose ONE tube
along ONE spline at one radius with the horn a cone on its end — and
`fit_features.py` now fits that intent.

- **Parametric outlines** (`regular_candidates`, `regularise_outline`).
  After `extrude_fit`'s alpha shape or `bar_fit`'s raster outline, the
  same projected points are fitted with a circle (least squares on the
  convex hull), a stadium, a rectangle with rounded corners and an oval
  (all on the tightest box round the hull — rotating calipers; the
  corner radius from the area the hull lacks against its box, r² =
  (LW − A) / (4 − π)), and a hexagon and an octagon (about the hull's
  centroid, at the rotation whose n-gon needs the smallest apothem to
  hold every hull vertex). Each candidate is scored with the fit's OWN
  coverage test on the piece's points (`slab_covered`, `prism_covered`)
  and the designed shape is taken when its outline runs along the points
  (nine tenths of it within two tolerances of a projected point — a box
  round an L-shaped plate crosses the notch in air; an area guard was
  tried first and threw out nearly every lever, since an alpha shape
  hugging a noisy cloud has a much smaller area than any convex shape)
  and it covers at least the free-form coverage − 0.03; ties to the
  hundredth go to
  the simpler shape (circle < stadium < square < rectangle < hexagon <
  octagon < oval). The outline is emitted as the same lines and arcs
  `segments_from_loop` produces (a circle as two semicircles), so
  `build_features.py`, `preview_model.py`, the film and the reel build
  it unchanged; the feature gains `shape` — `{"kind": "stadium",
  "lengthMM", "widthMM"}`, `rectangle`/`square` with `cornerMM`,
  `hexagon`/`octagon` with `acrossFlatsMM`, `circle` with `diameterMM`,
  `ellipse` — and `seed` (the shape's centre). `explain()` gives a
  designed outline +0.03 over a free-form one; the coverage thresholds
  are unchanged.
- **One tube, one spine** (`tube_fit`). The centreline samples split
  into runs only where the radius steps by more than max(2 tol, 35 %) of
  the run's median; neighbouring runs that agree to that merge into one
  run at one radius (the stein's handle, 14 mm at the top and 9 below,
  is one tube now). A run whose radius grows steadily (|trend| > 0.85
  over more than half its radius) is a cone and becomes a revolve on the
  line that continues the spine (the horn). The longest tube and the
  runs that follow it along the spine within six bins are the piece's
  story — one sweep, or a short chain meeting end to end where the
  radius really steps, with the horn on the end; a chain member reaches
  a radius into the next so the union fuses — and whatever else the
  geodesic crossed (a valve body, a lever) is left for the next pass to
  explain as what it is. `reach_body` now also carries an end straight
  to the nearest skin when the tangent misses it but the body is within
  three radii (a handle meets a belly at an angle), and says which ends
  met the body (`attached`), which run on into the chain (`joins`) and
  whether a horn follows (`intoHorn`).
- **Hoops** (`hoop_fit`, with `--analysis profile.json`, which
  `run_corpus.py` now passes). A piece is a ring round the main body's
  axis when a band of height bins (max(2, tol) mm each) has its points
  in at least 12 of 24 azimuth sectors, the sectors' outer radii (each
  sector's 75th percentile; the 10th to 90th percentile of those, so the
  two or so oddest sectors a dent or a stray patch makes do not decide)
  agree within max(2 tol, 4 %) — a squashed bucket's bulge is one-sided
  and fails — and the band is no taller than 0.35 of its diameter: a
  ring is a ring, not a wall. Without that last rule a body skin merely
  out of round by a few mm (within the 4 %) over its whole height ran
  all 24 sectors at one radius and passed as one 900 mm "hoop" (a probe:
  a 900 mm wall r 303 round a body r 295, ±6 mm out of round, tol 3 →
  accepted, lengthMM 897; now refused, "897 mm tall on a 606 mm
  diameter — a wall, not a ring"), and on a sparse sheet the band's
  extent was set by where the samples fell, not by the geometry. A hoop's
  coverage counts a vertex within `tol` of the ring's outer face or its
  end faces — the same tolerance every other fit is held to, so the
  score `explain()` ranks it by is comparable (it was max(tol, 5 % of
  the radius), 15 mm on a barrel). For that to be fair the profile has
  to be true: the outer radius per bin is taken from the points that
  face sideways (normal across the axis, not along it) and the band ends
  where its points stop, not at the bin edge beyond them — a hoop's top
  and bottom faces pulled the end bins' 75th-percentile radius 3 mm in
  and the bin edges made a 10 mm ring 12 tall, so the test ring covered
  25 % under an honest `tol`; it covers 100 % now. The section is the
  outer radius per bin out,
  and the body's own skin back, a little inside it (half the wall of a
  hollow body so the cavity stays, far + 4 mm of a solid one): a CLOSED
  annular profile (first point = last) revolved on the body's axis as
  kind `revolve` with `hoop: true`. `build_recipe.revolve_entities`
  draws a closed profile as the loop it is and `revolve_region` seeds it
  at its centroid (the half-section case is unchanged); a hoop earns
  +0.08 in `explain()` and is proved on its band, so it counts from 30 %
  coverage. A piece the sheet rule would drop (a wall a few mm out of
  round) is still offered to `hoop_fit`, and only to it.
- **Names** (`name_part`): `part` on every feature the rules know —
  `handle` (a sweep from the body back to the body), `hose` (long, into
  a horn or thin out of the body), `grip` (short and fat out of the
  body), `horn` (a cone), `hoop`, `knob` (a revolve no longer than its
  diameter, or a disc as thick as half its diameter), `nut` (a hexagon
  or an octagon), `lever` (a stadium twice as long as wide), `lug` (a
  short stadium, a thick rectangle or oval), `flange` (a thin rectangle
  or disc standing on the body by a face), `plate` (a thin one that does
  not), `bar`. `build_features.feature_caption` (which the film and the
  reel call) says "A lever · a bar with rounded ends, extruded and
  unioned in", "A hex nut · a hexagon extruded along the branch, unioned
  in", "A hoop · a ring on the body's own axis, revolved and unioned in";
  the old caption stands when the rules do not know (a chain, a stein's
  handle whose top meets a hinge the model lacks).

Measured offline on the ten corpus parts (`preview_model.py` with every
feature of the file, against the model before features — the revolve,
cavity, bodies and bosses — and the same tolerance as the run):

| part | IoU before → after | model→scan mm | scan→model mm | features before → after (kind, shape → part) | unexplained |
|---|---|---|---|---|---|
| extinguisher-rusty | 97.6 → 97.7 | 0.85 → 0.87 | 0.81 → 0.80 | 3 extrudes → 3 extrudes | 0 → 0 |
| extinguisher-3dhd | 92.5 → 93.3 | 3.95 → 3.78 | 2.43 → 1.76 | 3 sweeps (r 19, 8, 26) + revolve → sweep (grip region), sweep → **hose**, cone → **horn**, 4 extrudes, revolve | 0 → 1 |
| hydrant-02 | 98.0 → 98.3 | 1.03 → 1.11 | 1.46 → 1.44 | 3 extrudes + sweep → 2 sweeps (the cap chains) + 3 extrudes (the lugs) | 0 → 0 |
| bollard | 99.6 → 99.6 | 1.03 → 1.03 | 0.52 → 0.52 | none | 0 → 0 |
| pail-bucket | 77.0 → 77.0 | 1.92 → 1.86 | 2.15 → 2.15 | sweep + 2 extrudes → the same | 4 → 4 |
| tin-barrel | 96.5 → 96.5 | 5.18 → 5.18 | 7.20 → 7.20 | none → none | 2 → 2 |
| wd40-can | 99.5 → 99.5 | 0.20 → 0.20 | 0.27 → 0.27 | none | 0 → 0 |
| beer-mug | 97.3 → 97.4 | 1.36 → 1.83 | 0.71 → 0.76 | 2 sweeps + 2 extrudes → 2 sweeps (one spine, 11.9 then 7.2 mm), extrude ellipse → **lug**, extrude | 0 → 0 |
| truck-wheel | 94.5 → 94.6 | 9.01 → 9.01 | 4.43 → 4.36 | 2 bars + sweep + 2 extrudes → 2 **bars**, sweep → **grip**, 3 extrudes | 4 → 4 |
| pipe-wheel | 94.7 → 94.6 | 0.64 → 0.64 | 2.09 → 2.09 | 5 extrudes → 3 extrudes, extrude circle → **plate** (a 34 mm disc), extrude stadium → **lug** | 1 → 1 |

Nothing got worse by more than 0.1 point; the CO₂ extinguisher gained
0.8 (its scan→model mean fell from 2.43 to 1.76 mm) and now reads as a
hose (one 7.9 mm tube), a horn (a cone revolve, 16 → 33 mm over 236 mm)
and the grip region as one 17.6 mm tube with the levers as plates; the
stein's handle is one spine from the belly (which `reach_body` now
reaches) up to the knuckle, with its lid lever back as a plate and the
knuckle an oval lug. What did not happen, honestly: the designed outlines
win in 15 fits across the corpus but survive in the final list on only
three features — most levers in this corpus are bent straps (the rusty
extinguisher's carry handle is a 190 mm arch; no convex shape runs along
it) or corroded blobs whose wiggly alpha outline covers 8–12 points more
than any designed shape within tolerance; the valve's hex nut was never
a residual piece of its own (the hub is one piece with the wheel's
spokes, 53 % coverage free-form, every designed outline under 45 %); and
no hoop was accepted — the barrel's bottom chime runs all 24 sectors but
its outer radii spread 23 mm (the barrel is that far out of round), the
truck wheel's bands 11–13 mm, and the pail's rim pieces cover only 40 %
of the azimuth — so a squashed part is still reported, not chased. The
grip region of the CO₂ extinguisher is still a fat tube, not a lever.

Tests (`PartsLibraryTests`): a stadium plate 90 × 24 → `stadium`, length
and width within 5 %, named `lever`; a hexagonal prism of 36 mm across
flats → `hexagon` within 5 %, `nut`; a 6 mm tube along a quarter circle
→ exactly one sweep with one circle section; a 12 mm ring round a
cylinder's axis → one `revolve` on that axis with a closed section that
revolves to the ring's volume, while a one-sided bulge (3 of 24
sectors), the same ring stretched 10 % on one axis (radii spread 11 mm
against 4.5 allowed) and a round 4 mm wall 120 mm tall on a 216 mm
diameter are each refused, and that wall cut to 20 mm tall is a band
again.

### Bent bars and levers (2026-10-26)

The CO₂ extinguisher's valve head carries a squeeze lever under a carry
handle: two flat steel strips the scan fuses into one bar about 50 mm
wide and 22 thick that leaves the valve head, bends about 50° and runs
down beside the hose. `tube_fit` read it as an oval tube (52 × 23 mm,
an eleven-point spine) because the lever is the first run of the
piece's chain — lever, valve head, hose, horn — and nothing in the parts
library was a bar that bends. Now there is one.

- **A flat run is a bar, not a tube.** In `tube_runs` (the second half
  of `tube_fit`, split out so the centreline tracer — `trace_centreline`
  — and the chord reader can be shared) a run whose section is at least
  1.8 times as wide as it is thick (`FLAT_RATIO`; a stein's handle at 1.6
  is still an oval tube, the lever reads 2.3) is handed to `bar_along`
  with its own points and its centreline samples, and becomes a flat bar
  in the chain when the bar covers half its points; a flat oval thinner
  than one and a half tolerances is a torn skin and is dropped (the app
  had refused a 17.8 × 4.2 mm one on the horn, a 15 × 1 mm one followed
  it). The chain's story is unchanged: lever + hose + horn, each end
  reaching into the next.
- **The spine** (`corner_spine`): the centreline samples are split into
  runs, a line fitted to each, the split (or the two splits) chosen for
  the least orthogonal residual, each leg refitted on the samples clear
  of the corner by half a section (the bins round a corner hold both
  legs and lean a short leg by ten degrees). One leg when the samples'
  RMS distance to it is within max(tol, 15 % of the width); else two
  when they fit, bend ≥ 15° (`MIN_BEND_DEG`), both legs at least a
  section long and the residual under three quarters of one leg's; else
  three on the same terms against two; else none — a strap along a
  curve stays the oval sweep it was. Then `refine_legs` refits each leg
  on the bar's own surface points as the line through the centres of
  quarter-section slices across it — each centre the middle of the
  slice's lateral extent, not its mean (a scan is denser on the face it
  saw best and the bin means lean to it), and a slice whose spread is
  under 70 % of the median left out (the geodesic's bins cut a free end
  at a slant and the last bins hold half a ring; the L-bar test read 79°
  from the samples, 98° from the means, 90.0° from the slice centres).
- **The section** (`bar_along`): the longest leg's points within a
  quarter section of its middle, projected on the plane across it, go
  through `regularise_outline` with no free-form baseline — the designed
  outline (a rounded rectangle, a stadium, a disc, an oval) that covers
  the most of the bar's points within `tol` of the prism it makes along
  EVERY leg (`prism_covered`, leg by leg, the frame carried round the
  corners by `sweep_frames` with the same minimal rotation
  `preview_model.sweep_section` and the app's sweep use). Read at the
  middle because a lever tapers (the extinguisher's from 49 to 42 mm
  over its long leg): the hull of a whole leg is its fattest end,
  tilted, and the rectangle it gave sat 3 mm off the bar and 2 mm too
  thick (64 % of the lever's points on it; 75 % read at the middle). A
  run that measured flat but whose section reads round at the middle
  (a disc, a hexagon) is not a bar — the horn's torn sliver.
- **The bends** are arcs: of radii ½, 1, 1½, 2, 3 and 4 sections, the
  one whose arcs put the most of the bend's points (within 1.5 sections
  of a corner) on the prism, a sharp corner unless an arc wins by a
  point (`fillet_spine`, points every 7.5°, an arc may take no more than
  45 % of either leg). A real bar is bent round a former; a sharp mitre
  stood 8 mm proud of the lever's bend outside and short of it inside.
- **The feature** is a `sweep` with `"section": {"shape", "widthMM",
  "thicknessMM", "cornerMM", "segments", "seed"}` (the outline as the
  same lines and arcs an extrude's is drawn with, in the sketch frame
  `xAxis`, t₀ × `xAxis` at the spine's start), `"profile": {"shape":
  "section", …}` so nothing that reads a sweep's profile breaks, a
  `spine` of the legs with the arcs drawn in, `corners` (the sharp
  corners the legs meet at), `bendRadiusMM`, `bendsDeg`, `legsMM`,
  `lengthMM`, `bent`, and `attached` / `joins` / `intoHorn` as a tube's.
  The app's `feature.sweep` takes any closed sketch region and a world
  polyline, so `build_features.sweep_sketch` draws the section's
  entities instead of a circle and the build is one sketch and one op
  as before; `preview_model.feature_mesh` goes through the same
  `sweep_sketch`, so it mirrors the app's build without a change of its
  own (a 20 × 5 bar, 130 mm long, previews to 13 200 mm³ with its free
  ends run on a tolerance each). No per-segment extrudes were needed.
- **Names and captions**: `name_part` calls a section sweep a `lever`
  when it is flat (width ≥ 1.5 × thickness) and hangs from the body or
  the run it joins at one end, a `handle` when it comes back at both, a
  `bar` otherwise; `build_features.bar_words` says "a 51 × 22 mm flat,
  rounded-edged bar bent 51° on a 26 mm radius, 211 mm long", and the
  caption "A lever · …, swept along its legs and unioned in".
- **`bent_bar_fit`** is the same machinery for a piece on its own, a
  sixth candidate in `explain()` (+0.05, proved at half the piece like a
  revolve): the centreline traced as for a tube, a straight spine left
  to `bar_fit`, a round section left to the sweep (a quarter circle
  reads as three gentle legs; the tube follows its true curve).
- **Leftovers**: a flat bar's chain accounting counts points within TWO
  tolerances of its prism as its own (the bar's fit is proved at one).
  What a constant section leaves of a tapered lever is the lever's own
  skin; at one tolerance the pass after it piled a 24 mm slab on the
  bend.

What this gave, measured offline with `preview_model.py` against the
same pre-feature model (`run/stages/stage-1-revolve.stl`) and the same
scan the corpus run used, the corpus features as the app built them
against the new fit (`--all-features`):

| | before | after |
|---|---|---|
| lever | oval tube 52 × 23 mm, 11-point spine | a 51 × 22 mm rounded rectangle bent 51° on a 26 mm radius, 211 mm long, named `lever` |
| overlap (IoU) | 94.8 % | 94.8 % |
| model → scan / scan → model (vertex means) | 3.83 / 1.65 mm | 4.08 / 1.54 mm |
| area-weighted model → scan / scan → model | 1.55 / 1.14 mm | 1.60 / 1.08 mm |
| largest missing patch (M1) | 6 517 mm², 196 × 106, the lever | 3 638 mm², 92 × 74, the lever's root |
| M2 | 3 181 mm² | 3 465 mm² |
| largest excess patch (E1) | 9 564 mm², the valve head's cap | 9 358 mm², the same cap |
| E2 (the lever) | 5 051 mm² | 7 250 mm² |
| missing / excess, five largest patches together | 15 275 / 25 712 mm² | 12 129 / 27 176 mm² |

Honestly: the lever alone (the corpus features with only the oval
swapped for the bent bar) scores 94.6 %, two tenths under the oval. The
lever assembly is not a constant-section bar — two strips, a gap, a
taper from 49 to 42 mm — and a rounded rectangle that is right at the
middle is 4 mm too wide at the free end, where the oval, inscribed in the
same box, happened to lie closer. What the bent bar wins is the half of
M1 that the oval's rounded faces left off the strips' flat faces and a
part that reads as what it is; what it loses is the taper. E1, the
9.4 k mm² cap on the valve head, is the revolve's own profile (the top
97 mm of the body is "not a ring"), not a feature, and is untouched by
this track; the horn's missing side (M3, 2 715 mm²) is the cone revolve's
profile, likewise. The beer mug and the valve are unchanged to the digit
(the mug's handle, at 1.6, stays an oval tube; the valve's one flat run
reads as a hexagon at its middle and is refused as a bar). None of this
has been built in the app yet: the sweep of a rectangle with 10 mm
corners along a ten-point polyline is the same call as the hose's, but
whether OCCT's pipe takes the 26 mm arcs with a 51 mm section is for the
next corpus run to say.

Tests (`PartsLibraryTests`): an L-shaped flat bar (legs 80 and 50 mm,
20 × 5 mm, 90°) is one sweep of a 20 × 5 rectangle with its bend within
5° (90.0° measured), the sketch one closed loop of 100 mm², the preview
one closed solid of 13 200 mm³, a `lever` when attached at one end, and
`tube_fit` reads it the same way; a straight 20 × 5 × 130 bar is refused
by the bent-bar fit and is one `bar` to `bar_fit`; the 6 mm tube along a
quarter circle is still one circle sweep and the bent-bar fit stands
down; `corner_spine` counts one, two and three legs on noisy samples and
refuses a semicircle.

## Gotchas

- A quarter circle reads as three gentle legs (2026-10-26): a 120 mm
  radius arc sampled as centreline points fits a three-leg spine of 32°
  bends to 1.4 mm RMS, within the 15 %-of-width allowance of any bar
  over 10 mm wide, so `corner_spine` alone cannot tell a wide curve from
  a Z; the bent-bar fit stands down on a round section (the tube's), and
  on a flat strap along a curve the bend radius (up to four sections)
  rounds the legs back toward the arc. A semicircle is refused.
- A bar's spine from bin means leans to the scanned face and, at a free
  end, to the inner edge: the geodesic's bins cut a flat bar's end at a
  slant (the outer edge is farther along the surface than the inner),
  so the last bins hold half a ring. Fit leg directions on slice box
  centres with partial slices left out, never on bin means or PCA of
  the raw points (79°, 98° and 90° for the same 90° L).
- A constant section must be read at a leg's middle, not from the hull
  of the leg: a tapered lever's hull is its fat end, and the tightest
  box round a trapezoid is tilted — the rectangle sat 3 mm off the bar.

- A dished wheel is tested for BEFORE the open end (2026-10-25): from the
  hub side a rim's dish reads as an open container (rays fall 260 mm into
  the dish and through the hub's bore), the "cavity" cut the rim away and
  the dished-section tracer never ran. The truck wheel had been saved
  from this only by a wrong ground trim that happened to clip the tyre's
  face (gone since the floor-is-not-a-sidewalk rule); with the dish test
  first it traces as a section again (body alone 7.7 mm mean, was 21).
  Test: `test_a_tyre_on_a_hub_is_dished_and_not_an_open_container`.
- Import names the format from the file name's extension: pass
  `fileName: "scan.glb"`, not a bare label.
- `view.fit` right after `view.<direction>` is fine over the bridge, but
  wait about a second before `screenshot`: standard views animate.
- A body imported from glTF is metres → mm (×1000); build in the file's
  world frame so `accuracy` compares in place.
- Compare against the cropped scan, never the raw one: with the sidewalk
  in the reference the top view overlapped 26 % and the "size difference"
  was 350 mm.
- Chains: they are in the scan and not in the model, and they pull the
  scan-to-model deviation up (12 mm mean on the hydrant against 8 mm the
  other way). Cropping them too would flatter the model; the overlays show
  them instead.
- Blender 5.x removed `Action.fcurves`; keyframe interpolation goes through
  the layered action's channel bag (`action_fcurves` in `blender_video.py`).
- Sketchfab's viewer files (`model_file.binz`) are obfuscated; the only
  route to a model is a signed-in download. The site's own download call
  (`/i/models/<uid>/download`) authorises a download and counts against
  the account's daily limit even when nothing is fetched — do not call it
  to look.
- A Sketchfab glTF may hold several meshes (a shadow plane, a second copy
  of the part lying down, the liquid in a mug): pick the part's mesh out
  first (`prep/scan.glb`), the analyzer concatenates everything it is given.
- ffmpeg 9's threaded pipeline deadlocked twice in ten films on the final
  mux: every thread waiting in `sch_wait` / `tq_receive` at 0 % CPU, the
  mp4 left without its index. The cause was a dozen caption pictures fed
  as endlessly looping inputs (`-loop 1 … -t`); each is now one frame, and
  `overlay` holds a picture's last frame for the rest of the film (its
  default `eof_action`). `ffmpeg_watched` still runs every mux under a
  watchdog with one retry, and `film_corpus.py` kills a part's whole
  process group on a timeout — a plain `subprocess.run(timeout=)` orphaned
  the ffmpeg, and it sat there for an hour.
- Gemini 3.8 TTS on the Developer API has a daily quota as well as a
  per-minute one: about ninety lines (the hydrant plus eight corpus films)
  spent it, and `narrate` then raises rather than mix a second voice into
  a film. Lines are cached per part under `demo/tts` by the hash of their
  text, so a recompose with unchanged lines costs no calls; a part whose
  numbers line is new waits for midnight Pacific.
- `compose` cuts from a constant-frame-rate copy of the take
  (`work/take-cfr.mp4`) and used to keep it for as long as it existed. A
  retake then went unnoticed: the truck wheel's film was cut from the take
  before its retake, with the hook showing the Accuracy Report sheet
  instead of the pair, and the tin barrel's quietly from its old take too.
  The copy is rebuilt whenever `take.mov` is the newer file; check
  `contact.png` after any retake all the same.
- The scripts' stdout is block-buffered into `take.log` / `compose.log`:
  a child killed on a timeout leaves an empty log. The error row in
  `films.json` / `results.json` says what stopped it.
- The app's accuracy numbers are not a verdict. A pail modelled as a solid
  drum overlapped 93 % from the front and 95 % from the right; only the
  model-to-scan direction and the depth map from above said "lid". Run
  `inspect_fit.py` and look at its sheet (see "Catching errors").
- `straighten()` ran before any curve could be seen, so a mug's belly
  (radii 67 → 98 → 58 mm over 200 mm) became a cylinder and two cones —
  the terraces the preview painted. Arcs are now looked for on the
  simplifier's polyline through the raw bands and spliced into the
  straightened profile; a candidate arc wider than the part is tall is a
  slight taper and stays lines (the hydrant's barrel read as an r 1085 mm
  arc otherwise).
- Open-container detection by rays from outside each end: a scan trimmed
  at the ground has a hole there too, and every corpus part read "open at
  the bottom" until a ray's hit was classed by its face — crossing a hole
  and hitting the inside of the part's own top is a back face (a solid
  with a hole), the floor seen from the rim is a front face (a container).
  A pail scanned on a table has no floor at all, so a lost ray counts as
  open and the wider open end is the rim. The mug reads closed: it has a
  lid. The container is then ONE revolve of a hollow half-section
  (`fit_primitives.hollow_section`: the outer profile, the rim, the inner
  profile a wall in — concentric arcs for a dome or a belly — and a floor
  at the closed end). The kernel's `feature.shell` through the open face
  worked on the pail but refused the ribbed barrel at 13.7, 6, 3 and
  1.5 mm ("the wall thickness is out of range for this shape"); the
  hollow sketch has no kernel offset to fail. Its own offset has rules of
  its own: each line moves along its inward normal (moving everything
  radially put a lip's inner face ON its underside — a zero-thick wall
  the kernel drew as a detached ring), neighbours are mitred, arcs are
  concentric; the wall is capped at six tenths of the profile's smallest
  run or arc (the barrel's "13.7 mm", read off its rolled rim, against
  4 mm steps); and when the offset still crosses itself
  (`loop_self_intersects`, the barrel's stepped cap and rolled rim) the
  outer polyline is simplified with a growing tolerance until the offset
  holds, and failing that the inner profile is the outer radius ERODED
  by the wall — the least radius within a wall above and below, less the
  wall, a function of height that can cross neither the outer profile
  nor itself — with the floor where the body first reaches its radius
  from the closed end (the barrel's narrow cap stays a solid plug under
  it). A self-crossing loop is not refused by the kernel — the profile
  detector quietly takes the one small region it can close (the barrel
  came back as an 8-face disc, then as a solid drum with a hole).
- A scan's holes are not the model's excess. The pail has no floor; the
  model's floor is then far from every scan surface, and the first sheet
  painted it orange. A model sample whose nearest scan point lies on an
  open edge of the scan is facing a hole and is left out of the judged
  area (the bucket: 20 % of the model); in the depth maps a model-only
  pixel far deeper than the scan around it is painted slate, not orange.
  A drum's lid sits at the rim's own depth and still counts.
- `trimesh`'s `contains` (a ray test) was killed for memory on the
  shelled bucket's 18k faces with 40k query points; the sign of a
  distance now comes from the face normal at the closest point. And
  `outline()` on a scan with thousands of pinholes ran for ten minutes —
  the open edges come straight from the edge table (`group_rows`,
  `require_count=1`).
- A merged reference built by concatenating every STL in a folder picked
  up its own previous output (the clamp's reference held every part
  twice). Exclude the output, or write it elsewhere.
- Point splats for depth maps need the nearest sample over a 3 × 3
  neighbourhood, not the pixel alone, and a sample count that follows the
  pixel size (see "Catching errors").
