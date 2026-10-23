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
   it when the three tie (a pipe valve with a handwheel: the pipe's axis
   and the stem's score the same). `--units <mm per file unit>` overrides
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
2. **Up.** The wider end is the base — `--flip` says otherwise (an
   extinguisher scanned with its hose up is wider at the top). The body
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
  polyline that stops under the apex is carried to it.

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

    python3 fit_features.py --scan run/scan.stl --model run/part-cad.stl --tolerance 2 --out features/
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

## Gotchas

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
