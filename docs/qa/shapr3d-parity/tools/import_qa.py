#!/usr/bin/env python3
"""Import QA: run the CAD test pack through the app over MCP and report.

    python3 docs/qa/shapr3d-parity/tools/import_qa.py                 # every fixture
    python3 docs/qa/shapr3d-parity/tools/import_qa.py --only M01,M02  # a few
    python3 docs/qa/shapr3d-parity/tools/import_qa.py --extra /path/to/steps  # a folder of other CAD models

For each fixture the runner, through scripts/mcp_openshape3d.py (the same
server Claude Desktop uses — nothing here talks to the app directly):

  1. os3d_exec document.import — the file, as the Import menu would open it
  2. os3d_state / os3d_check / os3d_faces — solids, exact volume, bounds,
     validity, tolerance, face classes, analytic-or-mesh
  3. os3d_export step — the app's STEP round trip, written beside the report
  4. occt_inspect (tools/inspect_step.cpp) on that export against the
     reference: centroid, boolean symmetric difference, sampled surface
     distance — the deviation metrics TEST_PLAN.md §3 asks for
  5. edit.undo — so the next fixture starts from an empty design

and holds the numbers to the plan's numeric gates. A negative fixture must be
REFUSED (an error reply), leave the design untouched, and leave the app
answering /v1/health. A folder of other CAD models (--extra) has no manifest:
the reference is what OCCT itself reads from the file, so the gate is
"the app imports what the kernel reads".

Outputs, under docs/qa/shapr3d-parity/runs/<run-id>/:
  results.json   one record per case (results_template.json shape + metrics)
  REPORT.md      the table, the failures with reproduction, the timing
  exports/       the app's STEP export per case
  inspect/       occt_inspect JSON per case
  mcp_calls.jsonl  every MCP call (OS3D_MCP_LOG)

Needs: the app launched with OS3D_AGENT=1 (and OS3D_FRESH=1 for an empty
design), build/qa/occt_inspect compiled (tools/README.md). Python 3.9.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PACK = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(os.path.dirname(PACK)))
FIXTURES = os.path.join(PACK, "fixtures")
MANIFEST = os.path.join(PACK, "fixture_manifest.json")
SERVER = os.path.join(REPO, "scripts", "mcp_openshape3d.py")
INSPECT = os.path.join(REPO, "build", "qa", "occt_inspect")

# TEST_PLAN.md §3 numeric gates.
def volume_gate(reference):
    return max(0.001, 0.00001 * abs(reference))
BOUNDS_GATE = 0.01          # mm, each coordinate
CENTROID_GATE = 0.01        # mm, each coordinate
MESH_VOLUME_GATE = 0.001    # 0.1 %
MESH_BOUNDS_GATE = 0.05     # mm
SYMMETRIC_GATE = 0.00001    # (V(ref−act)+V(act−ref)) / max(V)
DISTANCE_GATE = 0.01        # mm, sampled estimate


# --------------------------------------------------------------------------
# MCP client — JSON-RPC over the server's stdio, the way Claude Desktop does it
# --------------------------------------------------------------------------

class MCP:
    def __init__(self, port, log_path):
        env = dict(os.environ, OS3D_AGENT_PORT=str(port), OS3D_MCP_LOG=log_path)
        self.p = subprocess.Popen([sys.executable, SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  env=env, text=True)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                "clientInfo": {"name": "import_qa", "version": "1.0"}})
        self.notify("notifications/initialized")

    def rpc(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("MCP server closed its stdout")
            reply = json.loads(line)
            if reply.get("id") == self.n:
                return reply

    def notify(self, method, params=None):
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method, "params": params or {}}) + "\n")
        self.p.stdin.flush()

    def tool(self, name, arguments=None):
        """Returns (is_error, parsed_or_text)."""
        reply = self.rpc("tools/call", {"name": name, "arguments": arguments or {}})
        if "error" in reply:
            return True, reply["error"]
        result = reply["result"]
        text = "".join(c.get("text", "") for c in result.get("content", []))
        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = text
        return bool(result.get("isError")), parsed

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def inspect(path, ref=None, out_path=None):
    if not os.path.exists(INSPECT):
        return {"readOK": False, "error": "occt_inspect not built (tools/README.md)"}
    args = [INSPECT, path]
    if ref:
        args += ["--ref", ref]
    try:
        raw = subprocess.run(args, capture_output=True, text=True, timeout=600).stdout
        data = json.loads(raw.strip().splitlines()[-1]) if raw.strip() else {"readOK": False, "error": "no output"}
    except subprocess.TimeoutExpired:
        data = {"readOK": False, "error": "occt_inspect timed out"}
    except ValueError:
        data = {"readOK": False, "error": "occt_inspect wrote no JSON", "raw": raw[-500:]}
    if out_path:
        with open(out_path, "w") as f:
            json.dump(data, f, indent=1)
    return data

def rss_mb(pid):
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return round(int(out) / 1024, 1) if out else None
    except Exception:
        return None

def fmt(v, digits=4):
    if v is None:
        return "—"
    if isinstance(v, float):
        return ("%." + str(digits) + "f") % v
    return str(v)

def vec_err(a, b):
    if a is None or b is None:
        return None
    return max(abs(float(x) - float(y)) for x, y in zip(a, b))

def union_bounds(bounds_list):
    mins = [min(b[0][i] for b in bounds_list) for i in range(3)]
    maxs = [max(b[1][i] for b in bounds_list) for i in range(3)]
    return mins, maxs


# --------------------------------------------------------------------------
# the run
# --------------------------------------------------------------------------

class Runner:
    def __init__(self, args):
        self.args = args
        self.run_id = args.run_id or time.strftime("%Y%m%d-%H%M%S")
        self.dir = os.path.join(PACK, "runs", self.run_id)
        for sub in ("", "exports", "inspect"):
            os.makedirs(os.path.join(self.dir, sub), exist_ok=True)
        self.mcp = MCP(args.port, os.path.join(self.dir, "mcp_calls.jsonl"))
        self.records = []
        self.commit = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()

    # -- app plumbing -------------------------------------------------------

    def health(self):
        err, h = self.mcp.tool("os3d_health")
        if err or not isinstance(h, dict) or not h.get("ok"):
            raise SystemExit("App not reachable over MCP on port %s: %s\nLaunch it with OS3D_AGENT=1 OS3D_FRESH=1 (docs/AGENT_CONTROL.md)." % (self.args.port, h))
        if not h.get("hasDocument"):
            raise SystemExit("The gallery is on screen — relaunch with OS3D_FRESH=1 so a design is open.")
        return h

    def state(self):
        err, s = self.mcp.tool("os3d_state")
        if err:
            raise RuntimeError("os3d_state failed: %s" % s)
        return s

    def undo_all(self, steps, baseline_ids):
        for _ in range(max(1, steps)):
            self.mcp.tool("os3d_run_command", {"id": "edit.undo"})
        now = {b["id"] for b in self.state().get("bodies", [])}
        return now == baseline_ids

    # -- one case -----------------------------------------------------------

    def run_case(self, case_id, path, expect, baseline_ids, pid):
        name = os.path.basename(path)
        ext = os.path.splitext(name)[1].lower().lstrip(".")
        rec = {
            "run_id": self.run_id, "case_id": case_id, "file": name, "path": path,
            "format": ext, "sha256": sha256(path), "source_commit": self.commit,
            "status": "NOT RUN", "checks": [], "metrics": {}, "expected": expect, "timing_s": {},
            "repro": {"tool": "os3d_exec", "arguments": {"op": "document.import",
                      "args": {"path": path, **({"units": "mm"} if ext == "stl" else {})}}},
        }
        negative = not expect.get("valid_reference", True)
        rss_before = rss_mb(pid)

        t0 = time.time()
        err, reply = self.mcp.tool("os3d_exec", rec["repro"]["arguments"])
        rec["timing_s"]["import"] = round(time.time() - t0, 3)
        rec["import_reply"] = reply if isinstance(reply, dict) else {"text": str(reply)[:500]}

        # The app must still be alive whatever the file did.
        err_h, h = self.mcp.tool("os3d_health")
        alive = (not err_h) and isinstance(h, dict) and h.get("ok")
        self.check(rec, "app alive after import", alive, "health: %s" % (h if not alive else "ok"))
        if not alive:
            rec["status"] = "FAIL"
            return rec

        if negative:
            refused = err or (isinstance(reply, dict) and (reply.get("error") or reply.get("failed")))
            noticed = isinstance(reply, dict) and bool(reply.get("notice"))
            self.check(rec, "refused, or imported with an explicit notice (no silent success)", bool(refused or noticed),
                       "reply: %s" % json.dumps(reply)[:300])
            if noticed and not refused:
                rec["metrics"]["notice"] = reply["notice"]
            now_ids = {b["id"] for b in self.state().get("bodies", [])}
            if refused:
                self.check(rec, "design untouched", now_ids == baseline_ids, "bodies now %d" % len(now_ids))
            else:
                clean = self.undo_all(int(reply.get("undoSteps") or 1), baseline_ids)
                self.check(rec, "undo returns to an empty design", clean, "")
            rec["metrics"]["rss_mb_after"] = rss_mb(pid)
            rec["status"] = "PASS" if all(c["ok"] for c in rec["checks"]) else "FAIL"
            return rec

        if err or not isinstance(reply, dict) or reply.get("error"):
            self.check(rec, "import accepted", False, "reply: %s" % json.dumps(reply)[:400])
            rec["status"] = "FAIL"
            return rec

        undo_steps = int(reply.get("undoSteps") or 1)
        try:
            if ext == "dxf":
                self.measure_dxf(rec, reply, expect)
            else:
                self.measure_bodies(rec, reply, expect, case_id, path)
        finally:
            t1 = time.time()
            clean = self.undo_all(undo_steps, baseline_ids)
            rec["timing_s"]["undo"] = round(time.time() - t1, 3)
            self.check(rec, "undo returns to an empty design", clean, "undo steps %d" % undo_steps)
            rec["metrics"]["rss_mb_before"] = rss_before
            rec["metrics"]["rss_mb_after"] = rss_mb(pid)
        rec["status"] = "PASS" if all(c["ok"] for c in rec["checks"] if not c.get("advisory")) else "FAIL"
        return rec

    def check(self, rec, label, ok, detail="", advisory=False):
        rec["checks"].append({"check": label, "ok": bool(ok), "detail": detail, "advisory": advisory})

    # -- bodies: STEP and meshes ---------------------------------------------

    def measure_bodies(self, rec, reply, expect, case_id, path):
        ids = reply.get("bodyIDs") or []
        state = self.state()
        bodies = [b for b in state.get("bodies", []) if b["id"] in ids]
        m = rec["metrics"]
        is_mesh_format = rec["format"] in ("stl", "obj", "glb", "gltf", "usdz", "3mf")

        # Health first: it also says which bodies are solids and which are
        # sheets (an open shell kept at import, counts.solids == 0).
        t0 = time.time()
        err, check = self.mcp.tool("os3d_check", {"bop": True})
        rec["timing_s"]["check"] = round(time.time() - t0, 3)
        health, health_by_id = [], {}
        if not err and isinstance(check, dict):
            for row in check.get("bodies", []):
                if row.get("id") in ids:
                    # A mesh body carries `meshOnly` on the row, not a health dict.
                    h = dict(row.get("health") or {})
                    if row.get("meshOnly"):
                        h["meshOnly"] = True
                    health.append(h)
                    health_by_id[row["id"]] = h
        m["health"] = health
        def is_solid(b):
            h = health_by_id.get(b["id"], {})
            if h.get("meshOnly"):
                return is_mesh_format
            return int((h.get("counts") or {}).get("solids") or 0) > 0
        solid_bodies = [b for b in bodies if is_solid(b)]
        sheet_bodies = [b for b in bodies if not is_solid(b)]

        m["body_count"] = len(bodies)
        m["solid_count"] = len(solid_bodies)
        m["sheet_count"] = len(sheet_bodies)
        m["analytic_bodies"] = sum(1 for b in bodies if b.get("brep"))
        m["volume_mm3"] = sum(float(b.get("volumeMM3") or 0) for b in solid_bodies)
        if bodies and all(b.get("bounds") for b in bodies):
            lo, hi = union_bounds([b["bounds"] for b in bodies])
            m["bounds_min_mm"], m["bounds_max_mm"] = lo, hi
        m["names"] = [b.get("name") for b in bodies]
        if reply.get("notice"):
            m["notice"] = reply["notice"]
        if reply.get("step"):
            m["step"] = reply["step"]
            ref_sew = expect.get("sewing")
            if ref_sew:
                keys = ("sewnSolids", "openShells", "dropped")
                same = all(int(reply["step"].get(k) or 0) == int(ref_sew.get(k) or 0) for k in keys)
                self.check(rec, "read ledger matches oracle sewing (sewn/open/dropped)", same,
                           "app %s, oracle %s" % ({k: reply["step"].get(k) for k in keys},
                                                  {k: ref_sew.get(k) for k in keys}), advisory=True)

        expected_count = expect.get("solid_count")
        expected_sheets = int(expect.get("sheet_bodies") or 0)
        expected_volume = expect.get("expected_aggregate_volume_mm3")
        exp_min, exp_max = expect.get("bounds_min_mm"), expect.get("bounds_max_mm")

        if expected_count is not None:
            self.check(rec, "solid count", len(solid_bodies) == expected_count,
                       "expected %s, got %d solid bodies (%d sheet)" % (expected_count, len(solid_bodies), len(sheet_bodies)))
            self.check(rec, "sheet bodies", len(sheet_bodies) == expected_sheets,
                       "expected %d, got %d" % (expected_sheets, len(sheet_bodies)))
        else:
            self.check(rec, "at least one body", len(bodies) > 0, "got %d" % len(bodies))
        if expect.get("expect_notice"):
            self.check(rec, "import says what it did (notice)", bool(reply.get("notice")), reply.get("notice") or "no notice")
        elif reply.get("notice") and not expect.get("external"):
            self.check(rec, "no partial-import notice", False, reply["notice"])

        if not is_mesh_format:
            self.check(rec, "every body analytic (brep)", m["analytic_bodies"] == len(bodies) and bodies,
                       "%d of %d carry a B-rep" % (m["analytic_bodies"], len(bodies)))
            for b in sheet_bodies:
                self.check(rec, "sheet body reads 0 mm3", float(b.get("volumeMM3") or 0) == 0,
                           "%s reads %s" % (b.get("name"), b.get("volumeMM3")))
        else:
            self.check(rec, "mesh body (no brep expected)", m["analytic_bodies"] == 0, "", advisory=True)

        if expected_volume is not None:
            gate = volume_gate(expected_volume) if not is_mesh_format else MESH_VOLUME_GATE * abs(expected_volume)
            diff = abs(m["volume_mm3"] - expected_volume)
            m["volume_error_mm3"] = diff
            self.check(rec, "volume", diff <= gate,
                       "expected %.6f, got %.6f, |err| %.6g, gate %.6g" % (expected_volume, m["volume_mm3"], diff, gate))
        if exp_min and exp_max and "bounds_min_mm" in m:
            gate = BOUNDS_GATE if not is_mesh_format else MESH_BOUNDS_GATE
            e = max(vec_err(m["bounds_min_mm"], exp_min), vec_err(m["bounds_max_mm"], exp_max))
            m["bounds_error_mm"] = e
            self.check(rec, "bounds", e <= gate, "max coordinate error %.6g mm, gate %.3g" % (e, gate))

        if not is_mesh_format:
            invalid = [h for h in health if not h.get("valid", False) and not h.get("meshOnly")]
            self.check(rec, "valid B-rep (BRepCheck)", bool(health) and not invalid,
                       "; ".join("%s" % (h.get("findings") or h) for h in invalid)[:300] if invalid else "all valid")
            bop = [f for h in health for f in (h.get("bopFindings") or [])]
            self.check(rec, "no self-intersections (BOP)", not bop, str(bop)[:200], advisory=True)
            open_wires = sum(int(h.get("openFreeWires") or 0) for h in health)
            self.check(rec, "no open free wires", open_wires == 0, "%d" % open_wires, advisory=bool(sheet_bodies))

        # Face classes straight from the kernel, compared with the file's own.
        if not is_mesh_format:
            planar = cyl = other = 0
            for b in bodies:
                err, faces = self.mcp.tool("os3d_faces", {"body": b["id"]})
                if err or not isinstance(faces, dict):
                    continue
                for f in faces.get("faces", []):
                    kind = str(f.get("kind", ""))
                    if kind == "planar":
                        planar += 1
                    elif kind.startswith("cylind"):
                        cyl += 1
                    else:
                        other += 1
            m["faces"] = {"planar": planar, "cylindrical": cyl, "other": other}
            rt = expect.get("occt_roundtrip") or {}
            if rt:
                self.check(rec, "face classes match reference (diagnostic)",
                           planar == rt.get("planar_faces") and cyl == rt.get("cylindrical_faces"),
                           "app planar/cyl/other %d/%d/%d, reference %s/%s/%s" % (
                               planar, cyl, other, rt.get("planar_faces"), rt.get("cylindrical_faces"), rt.get("other_faces")),
                           advisory=True)

        # STEP round trip through the app's own exporter, then the oracle.
        if not is_mesh_format and solid_bodies:
            export_path = os.path.join(self.dir, "exports", "%s.step" % case_id)
            t0 = time.time()
            err, ex = self.mcp.tool("os3d_export", {"format": "step", "path": export_path})
            rec["timing_s"]["export"] = round(time.time() - t0, 3)
            ok_export = (not err) and isinstance(ex, dict) and ex.get("ok")
            self.check(rec, "STEP export", bool(ok_export), str(ex)[:200])
            if ok_export:
                t0 = time.time()
                report = inspect(export_path, ref=path, out_path=os.path.join(self.dir, "inspect", "%s.json" % case_id))
                rec["timing_s"]["inspect"] = round(time.time() - t0, 3)
                self.measure_roundtrip(rec, report, expect)
        elif is_mesh_format and bodies:
            report = inspect(path, out_path=os.path.join(self.dir, "inspect", "%s.json" % case_id))
            if report.get("readOK"):
                m["reference_centroid_mm"] = report["metrics"]["centroid"]

    def measure_roundtrip(self, rec, report, expect):
        m = rec["metrics"]
        if not report.get("readOK"):
            self.check(rec, "exported STEP readable by OCCT", False, report.get("error", ""))
            return
        self.check(rec, "exported STEP readable by OCCT", True)
        em, dev = report["metrics"], report.get("deviation") or {}
        ref = (report.get("reference") or {}).get("metrics") or {}
        m["export"] = {"solids": em["solids"], "volume_mm3": em["volume"], "centroid_mm": em["centroid"],
                       "bounds": em["bounds"], "valid": em["valid"], "faces": em["faces"], "tolerance": em["tolerance"]}
        if ref:
            m["reference"] = {"solids": ref["solids"], "volume_mm3": ref["volume"], "centroid_mm": ref["centroid"],
                              "bounds": ref["bounds"], "valid": ref["valid"], "faces": ref["faces"]}
            m["centroid_error_mm"] = max(abs(x) for x in dev.get("centroidError", [0, 0, 0]))
            self.check(rec, "round-trip solid count", em["solids"] == ref["solids"],
                       "export %d, reference %d" % (em["solids"], ref["solids"]))
            self.check(rec, "round-trip volume", abs(dev.get("volumeError", 0)) <= volume_gate(ref["volume"]),
                       "error %.6g mm3, gate %.6g" % (dev.get("volumeError", 0), volume_gate(ref["volume"])))
            self.check(rec, "round-trip centroid", m["centroid_error_mm"] <= CENTROID_GATE,
                       "max coordinate error %.6g mm" % m["centroid_error_mm"])
            self.check(rec, "round-trip bounds", dev.get("boundsMaxError", 0) <= BOUNDS_GATE,
                       "max error %.6g mm" % dev.get("boundsMaxError", 0))
            self.check(rec, "exported STEP valid (BRepCheck)", em["valid"], "")
            if "symmetricRatio" in dev:
                m["residual_volume_mm3"] = dev["refMinusActual"] + dev["actualMinusRef"]
                m["symmetric_ratio"] = dev["symmetricRatio"]
                self.check(rec, "symmetric-difference volume", dev["symmetricRatio"] <= SYMMETRIC_GATE,
                           "ref−act %.6g + act−ref %.6g mm3, ratio %.3g" % (dev["refMinusActual"], dev["actualMinusRef"], dev["symmetricRatio"]))
            elif dev.get("booleanOK") is False:
                self.check(rec, "symmetric-difference volume", False, "boolean failed — inconclusive, not zero")
            sd = dev.get("surfaceDistance")
            if sd:
                m["surface_distance_mm"] = sd["max"]
                m["surface_distance_is_estimate"] = True
                self.check(rec, "surface distance (sampled estimate)", sd["max"] <= DISTANCE_GATE,
                           "max %.6g mm over %s samples at %.3g deflection" % (sd["max"], sd["samples"], sd["deflection"]))

    # -- DXF ------------------------------------------------------------------

    def measure_dxf(self, rec, reply, expect):
        m = rec["metrics"]
        grown = reply.get("sketches") or []
        m["sketches_grown"] = grown
        added = sum(int(s.get("entitiesAdded") or 0) for s in grown)
        err, sk = self.mcp.tool("os3d_sketches")
        entities = []
        if not err and isinstance(sk, dict):
            wanted = {s.get("sketchID") for s in grown}
            for sketch in sk.get("sketches", []):
                if not wanted or sketch.get("id") in wanted or sketch.get("sketchID") in wanted:
                    entities.extend(sketch.get("entities", []))
        kinds = {}
        for e in entities:
            kinds[e.get("kind", "?")] = kinds.get(e.get("kind", "?"), 0) + 1
        m["entities_added"], m["entity_kinds"] = added, kinds
        m["entities"] = entities
        self.check(rec, "DXF added entities", added > 0, "%d added: %s" % (added, kinds))
        expected = expect.get("expected_entities") or {}
        if not expected:
            return

        def near(a, b, tol=0.01):
            return vec_err(a, b) is not None and vec_err(a, b) <= tol
        by_kind = lambda k: [e for e in entities if e.get("kind") == k]

        # Schema A (M02): counts and summary geometry.
        if "lines" in expected or "circles" in expected:
            if "lines" in expected:
                self.check(rec, "DXF line count", len(by_kind("line")) == expected["lines"],
                           "expected %s, got %d" % (expected["lines"], len(by_kind("line"))))
            if "circles" in expected:
                self.check(rec, "DXF circle count", len(by_kind("circle")) == expected["circles"],
                           "expected %s, got %d" % (expected["circles"], len(by_kind("circle"))))
            if "outline_mm" in expected and by_kind("line"):
                xs = [float(p[0]) for e in by_kind("line") for p in (e["a"], e["b"])]
                ys = [float(p[1]) for e in by_kind("line") for p in (e["a"], e["b"])]
                got = [max(xs) - min(xs), max(ys) - min(ys)]
                self.check(rec, "DXF outline", near(got, expected["outline_mm"]), "%s vs %s" % (got, expected["outline_mm"]))
            if "circle_radius_mm" in expected and by_kind("circle"):
                radii = [float(e["radius"]) for e in by_kind("circle")]
                self.check(rec, "DXF circle radius", all(abs(r - expected["circle_radius_mm"]) <= 0.01 for r in radii),
                           "%s vs %s" % (radii, expected["circle_radius_mm"]))
            if "centers_mm" in expected and by_kind("circle"):
                got = sorted(tuple(round(float(v), 3) for v in e["center"]) for e in by_kind("circle"))
                want = sorted(tuple(float(v) for v in c) for c in expected["centers_mm"])
                self.check(rec, "DXF circle centres", got == want, "%s vs %s" % (got, want))
            return

        # Schema B (M15): one expected entity per kind with its geometry.
        for kind, spec in expected.items():
            present = by_kind(kind)
            self.check(rec, "DXF %s imported" % kind, bool(present), "expected %s; kinds present %s" % (json.dumps(spec)[:120], kinds))
            if not present or not isinstance(spec, dict):
                continue
            e = present[0]
            if "center" in spec and "center" in e:
                self.check(rec, "DXF %s centre" % kind, near(e["center"], spec["center"]), "%s vs %s" % (e["center"], spec["center"]))
            if "radius" in spec and "radius" in e:
                self.check(rec, "DXF %s radius" % kind, abs(float(e["radius"]) - spec["radius"]) <= 0.01, "%s vs %s" % (e["radius"], spec["radius"]))
            if "semiaxes" in spec and "radiusX" in e:
                got = sorted([float(e["radiusX"]), float(e["radiusY"])], reverse=True)
                want = sorted([float(v) for v in spec["semiaxes"]], reverse=True)
                self.check(rec, "DXF ellipse semi-axes", near(got, want), "%s vs %s" % (got, want))
            if "start_deg" in spec and "startAngle" in e:
                import math
                got = [math.degrees(float(e["startAngle"])) % 360, math.degrees(float(e["endAngle"])) % 360]
                want = [spec["start_deg"] % 360, spec["end_deg"] % 360]
                self.check(rec, "DXF arc angles", near(got, want, 0.01), "%s vs %s" % (got, want))
            if "start" in spec and "a" in e:
                pts = sorted(tuple(round(float(v), 3) for v in p) for p in (e["a"], e["b"]))
                want = sorted(tuple(float(v) for v in p) for p in (spec["start"], spec["end"]))
                self.check(rec, "DXF line endpoints", pts == want, "%s vs %s" % (pts, want))

    # -- the loop -------------------------------------------------------------

    def run(self):
        h = self.health()
        pid = h.get("pid")
        base = self.state()
        baseline_ids = {b["id"] for b in base.get("bodies", [])}
        if baseline_ids:
            print("note: %d bodies already in the design; they are left alone" % len(baseline_ids))
        manifest = json.load(open(MANIFEST))
        files = manifest["files"]
        if isinstance(files, dict):
            cases = [(k, v) for k, v in files.items()]
        else:
            cases = [(f["file"], f) for f in files]
        only = set(self.args.only.split(",")) if self.args.only else None
        selected = []
        for fname, spec in cases:
            case_id = os.path.splitext(fname)[0]
            if self.args.no_fixtures:
                break
            if only and not any(case_id.startswith(o) for o in only):
                continue
            if self.args.skip_mesh and fname.lower().endswith(".stl"):
                continue
            selected.append((case_id, os.path.join(FIXTURES, fname), spec))
        for extra in self.args.extra or []:
            paths = [extra] if os.path.isfile(extra) else sorted(
                os.path.join(root, n) for root, _, names in os.walk(extra) for n in names)
            for path in paths:
                n = os.path.basename(path)
                if n.lower().endswith((".step", ".stp")) and (not only or any(n.startswith(o) for o in only)):
                    selected.append(("EXT_" + os.path.splitext(n)[0], path, {"external": True}))
        print("run %s: %d cases on %s (pid %s, %s)" % (self.run_id, len(selected), h.get("platform"), pid, self.commit))
        for case_id, path, spec in selected:
            expect = dict(spec)
            if expect.get("external"):
                # No manifest: the kernel's own reading of the file is the reference.
                ref = inspect(path, out_path=os.path.join(self.dir, "inspect", "%s.reference.json" % case_id))
                if ref.get("readOK"):
                    rm = ref["metrics"]
                    sew = ref.get("sewing") or {}
                    expect.update({"solid_count": rm["solids"], "sheet_bodies": int(sew.get("openShells") or 0),
                                   "sewing": sew,
                                   "expect_notice": bool(sew.get("sewnSolids") or sew.get("openShells") or sew.get("dropped")),
                                   "expected_aggregate_volume_mm3": rm["volume"],
                                   "bounds_min_mm": rm["bounds"]["min"], "bounds_max_mm": rm["bounds"]["max"],
                                   "valid_reference": True, "units": "mm",
                                   "occt_roundtrip": {"planar_faces": rm["faces"]["planar"], "cylindrical_faces": rm["faces"]["cylindrical"],
                                                      "other_faces": rm["faces"]["total"] - rm["faces"]["planar"] - rm["faces"]["cylindrical"]}})
                else:
                    expect.update({"valid_reference": False, "expected": "OCCT itself cannot read this file: %s" % ref.get("error")})
            t0 = time.time()
            rec = self.run_case(case_id, path, expect, baseline_ids, pid)
            rec["timing_s"]["total"] = round(time.time() - t0, 3)
            self.records.append(rec)
            failed = [c for c in rec["checks"] if not c["ok"] and not c.get("advisory")]
            print("  %-28s %-5s %5.1fs  %s" % (case_id, rec["status"], rec["timing_s"]["total"],
                                             "; ".join(c["check"] for c in failed)[:90]))
            self.write()
        self.mcp.close()
        self.write()
        print("report: %s" % os.path.join(self.dir, "REPORT.md"))

    # -- output ---------------------------------------------------------------

    def write(self):
        with open(os.path.join(self.dir, "results.json"), "w") as f:
            json.dump({"run_id": self.run_id, "source_commit": self.commit, "units": "mm",
                       "gates": {"volume": "max(0.001, 1e-5·V) mm3", "bounds_mm": BOUNDS_GATE, "centroid_mm": CENTROID_GATE,
                                 "mesh_volume": MESH_VOLUME_GATE, "mesh_bounds_mm": MESH_BOUNDS_GATE,
                                 "symmetric_ratio": SYMMETRIC_GATE, "surface_distance_mm": DISTANCE_GATE},
                       "cases": self.records}, f, indent=1)
        lines = ["# Import QA run %s" % self.run_id, "",
                 "Commit `%s` · %d cases · %d PASS · %d FAIL · gates from TEST_PLAN.md §3 (volume ≤ max(0.001, 1e-5·V) mm³, bounds and centroid ≤ %.2f mm, symmetric difference ≤ %g, surface distance ≤ %.2f mm sampled)." % (
                     self.commit, len(self.records), sum(r["status"] == "PASS" for r in self.records),
                     sum(r["status"] == "FAIL" for r in self.records), BOUNDS_GATE, SYMMETRIC_GATE, DISTANCE_GATE), "",
                 "| Case | Status | Solids exp/act | Volume expected | Volume app | |err| mm³ | Bounds err mm | Centroid err mm | Sym. diff ratio | Surface dist mm | Analytic | Valid | Import s |",
                 "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for r in self.records:
            m, e = r["metrics"], r["expected"]
            health = m.get("health") or []
            valid = "—" if not health else ("yes" if all(h.get("valid") for h in health) else ("mesh" if all(h.get("meshOnly") for h in health) else "NO"))
            lines.append("| %s | %s | %s/%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                r["case_id"], r["status"], fmt(e.get("solid_count")), fmt(m.get("solid_count")),
                fmt(e.get("expected_aggregate_volume_mm3")), fmt(m.get("volume_mm3")), fmt(m.get("volume_error_mm3"), 6),
                fmt(m.get("bounds_error_mm"), 5), fmt(m.get("centroid_error_mm"), 5), fmt(m.get("symmetric_ratio"), 7),
                fmt(m.get("surface_distance_mm"), 5),
                "%s/%s" % (m.get("analytic_bodies", "—"), m.get("solid_count", "—")) if m else "—",
                valid, fmt(r["timing_s"].get("import"), 2)))
        failures = [r for r in self.records if r["status"] != "PASS"]
        if failures:
            lines += ["", "## Failures", ""]
            for r in failures:
                lines.append("### %s — %s" % (r["case_id"], r["file"]))
                for c in r["checks"]:
                    if not c["ok"]:
                        lines.append("- %s**%s**: %s" % ("(advisory) " if c.get("advisory") else "", c["check"], c["detail"]))
                if r.get("import_reply", {}).get("message"):
                    lines.append("- app said: %s" % r["import_reply"]["message"])
                lines.append("- repro: `os3d_exec` %s" % json.dumps(r["repro"]["arguments"]))
                lines.append("")
        advisories = [(r, c) for r in self.records for c in r["checks"] if c.get("advisory") and not c["ok"]]
        if advisories:
            lines += ["", "## Advisory findings (not gates)", ""]
            for r, c in advisories:
                lines.append("- %s: %s — %s" % (r["case_id"], c["check"], c["detail"]))
        lines += ["", "## Timing and memory", "", "| Case | Import s | Check s | Export s | Inspect s | RSS before MB | RSS after MB |", "|---|---|---|---|---|---|---|"]
        for r in self.records:
            t, m = r["timing_s"], r["metrics"]
            lines.append("| %s | %s | %s | %s | %s | %s | %s |" % (r["case_id"], fmt(t.get("import"), 2), fmt(t.get("check"), 2),
                                                                 fmt(t.get("export"), 2), fmt(t.get("inspect"), 2), fmt(m.get("rss_mb_before")), fmt(m.get("rss_mb_after"))))
        with open(os.path.join(self.dir, "REPORT.md"), "w") as f:
            f.write("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default=os.environ.get("OS3D_AGENT_PORT", "8787,8899"))
    ap.add_argument("--run-id")
    ap.add_argument("--only", help="comma-separated case id prefixes, e.g. M01,M02,NEGATIVE")
    ap.add_argument("--extra", action="append", help="a STEP file or folder of them to import against the kernel's own reading (repeatable)")
    ap.add_argument("--no-fixtures", action="store_true", help="skip the test pack; only --extra")
    ap.add_argument("--skip-mesh", action="store_true")
    Runner(ap.parse_args()).run()


if __name__ == "__main__":
    main()
