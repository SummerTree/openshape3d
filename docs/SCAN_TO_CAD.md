# From a 3D scan to a CAD model, over MCP — and graded by the app

A phone scan of a fire hydrant becomes a parametric OpenShape 3D model
without anyone touching the app: a script reads the scan, an MCP client
drives the app's one `os3d` tool call by call, and the app itself measures
how close the result is — orthographic silhouette overlays per view and the
distance from every sampled scan point to the model. The run writes a
transcript, pictures, an HTML report and a narrated video (Blender).

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
venv/bin/python make_video.py --run /tmp/hydrant/run --scan /tmp/hydrant/analysis/scan_cropped.glb --out /tmp/hydrant/video --preview
venv/bin/python make_video.py --run /tmp/hydrant/run --scan /tmp/hydrant/analysis/scan_cropped.glb --out /tmp/hydrant/video
```

`document.import` by path is a development-build op (it reads the host's
file system), so step 3 needs a DEBUG build; everything else the script
calls ships in the store app.

## How each piece works

### `analyze_scan.py` — what the scan is

1. **Axis.** The scan's frame is the phone's. The largest principal
   component of the vertices gives a first axis for a part taller than it is
   wide; it is refined by fitting a line through the centres of forty thin
   slices along it. Each slice centre is a RANSAC circle fit (three random
   points, count the points within 2.5 mm of that circle, keep the best,
   then an algebraic fit on the inliers) — a nozzle's points never lie on
   the barrel's circle, so they are ignored rather than pulling the centre
   toward the nozzle. The first version used the slice's bounding-box
   centre and sat 12 mm off toward the pumper nozzle; the top-view overlay
   showed it as a crescent.
2. **Up.** The wider end is the base. The scanner's ground — bottom bands
   whose radii spread over a wide range, where a band of the part is a thin
   ring — is trimmed, and the scan is written out again without it
   (`scan_cropped.glb`, metres, texture inside) so the comparison is hydrant
   against hydrant. The revolve starts where the scan has solid coverage,
   not in the sparse last bands above the sidewalk.
3. **Profile.** Vertices are binned in 4 mm height bands. The band's body
   radius is what most 10° sectors agree on — the 30th percentile of the
   per-sector median radii — which ignores the sectors a nozzle fills and
   the ones a scanner hole empties. Douglas–Peucker at 1.5 mm turns the
   band medians into the ~30 corners a revolve sketch wants.
4. **Bosses.** On the (band × sector) grid, cells whose maximum radius
   stands more than 6 mm proud of the band's body radius are grouped by a
   watershed from their peaks (regions merge only across a saddle at least
   60 % as high as the lower peak). Each region is judged on its core —
   cells at least half as proud as its peak, in bands at least three
   sectors wide — because a cap's chain hangs as far from the axis as the
   cap and would otherwise tie it to a flange ring below or drag its centre
   down. Rings (a flange step straddling two bands, broken into pieces by
   scanner holes) are dropped by angular extent. A boss then gets its
   direction from its cap's face (the farthest points), its centre height
   from its top edge minus its radius (nothing hangs above a nozzle), and a
   radius-along profile read in 8 mm slices as the horizontal half-extent
   (chains hang down, so the horizontal extent is clean) — the flared
   casting, the threads, the cap and the nut on its face come out as steps.
   `--debug` says why every candidate lump was dropped.

`profile.png` (radius by height, with the polyline) and `azimuth.png` (the
band × azimuth map: nozzles are blobs) are written for the report.

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
| The turned body | `sketch.create` on the fitted axis (`origin` = axis origin, `xAxis` = azimuth 0, `yAxis` = the axis), `sketch.addEntities` (the profile as a closed loop of lines, axis at u = 0), `feature.revolve` 360° about `[0,0]`,`[0,1]` |
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

### `report.py` and `make_video.py`

`report.py` inlines the app's overlay pictures, screenshots, the deviation
histograms (SVG), the size table, the recipe and the MCP transcript into
one HTML file. `make_video.py` narrates each segment (edge-tts; the system
voice offline), colours the scan by its distance to the model (trimesh →
`heatmap.ply`), and runs `blender_video.py` in Blender 5.2 (EEVEE, 1920 ×
1080, 30 fps): title, the scan turning, the analysis charts, the MCP calls
appearing one by one, the model taking shape over the ghosted scan, scan
and model in place, the heatmap, the app's overlays, the numbers, outro;
Blender writes JPEG frames (PNGs of a 100 s film ran to several gigabytes
of scratch and filled the disk once; this Blender build has no video
output), ffmpeg encodes them under the narration and writes a contact sheet
to review.

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
  route to a model is a signed-in download.
