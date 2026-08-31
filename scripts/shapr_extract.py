#!/usr/bin/env python3
"""Extract a readable parametric recipe from a Shapr3D .shapr file.

WHAT A .shapr ACTUALLY IS: a ZIP holding one SQLite database named `workspace`.

The solids are out of reach and always will be — `Shapes.ShapeData` is
Parasolid XT (header `PS...TRANSMIT FILE created by modeller version …`), and
OCCT cannot read Parasolid at any price. So there is no importing a .shapr body
into openshape3d.

The DESIGN INTENT, though, is sitting there in the clear, and for rebuilding a
model that is the more useful half:

  SketchControllers    plane origin / normal / U-dir as plain DOUBLE columns
  SketchCurves.Data    plain JSON per curve. type 0=line (start/end),
                       1=arc (center/start/end), 2=circle (center/radius),
                       3=spline (controlPoints[]). Coordinates in METRES.
  HistoryTreeNodes     type 2 is the feature graph:
                       {"functionName":"Extrude","stepName":"Extrusion 01",
                        "parameters":[node ids…]}
                       type 3 is a literal those ids point at:
                       {"literalValue":"<base64>"} -> <uint32 tag><payload>,
                       where tag 3 + 8 bytes is a little-endian IEEE754 double
                       in metres, and tag 4 + 4 bytes is an int32.

CAVEAT WORTH KNOWING: the literal VALUES decode exactly, but which parameter
slot means what is inferred, not documented. A revolve's "angle" arrives as a
raw double that happens to be 6.2831853 (radians), while a distance arrives in
metres — so `mm` and `inch` below are only meaningful for slots that really are
lengths. Read them as candidates, not as labelled fields.

Usage:  python3 scripts/shapr_extract.py "Some Model.shapr" > recipe.json

The eight models from the Shapr3D "Introducing Shapr3D basics" tutorial are
hosted on Google Drive (NOT as Zendesk attachments — the article's attachments
are only preview PNGs). Fetch one with:

    curl -sL "https://drive.google.com/uc?export=download&id=<ID>" -o out.shapr

    Motorcycle          1_D30X1OSFBwVXgdg_M4SjpmKkefNhfQj   (Parasolid TEXT .x_t, not a .shapr)
    Motorcycle cover    1GY3uDbKNFsluzQlxE-qH379GsP84tTTN
    Piston              1I5Y_6_v2c0Lgrunfbc0_AUrUsuJQPsMq
    Piston rod          12GyGRtQkd1dUhOnoNW0jTvrK9_cRi0D6
    Rod clamp           10r6W6bMMiy7D90zH7NXtkGLML3FtQO-e
    4 motorcycle wheel  1ug44QSQt-OKzQU_hD22QWsTy7HZbIKj-
    Frame               1nrQdhIynlqh6NaMCxsqkNvG1d6Zh3GAg
    Block casting       1cjMQ77eywQU0xY8jWV26So89MXdJAzAG

Only four carry sketches and history at all (Frame, Block casting, Motorcycle
cover, 4 motorcycle wheel). Rod clamp / Piston / Piston rod are frozen imported
solids — one body, zero sketches, no history to replay.
"""

import base64, json, sqlite3, struct, sys, zipfile, tempfile, os

CURVE = {0: "line", 1: "arc", 2: "circle"}

def literal(b64):
    raw = base64.b64decode(b64)
    if len(raw) < 4:
        return {"raw": raw.hex()}
    tag = struct.unpack_from("<I", raw, 0)[0]
    body = raw[4:]
    if tag == 3 and len(body) == 8:                    # IEEE754 double, metres
        v = struct.unpack("<d", body)[0]
        return {"double_m": v, "mm": round(v * 1000, 4), "inch": round(v / 0.0254, 4)}
    if tag == 4 and len(body) == 4:
        return {"int32": struct.unpack("<i", body)[0]}
    return {"tag": tag, "hex": body.hex()}

def extract(path):
    with zipfile.ZipFile(path) as z:
        data = z.read("workspace")
    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".db")
    tmp.write(data); tmp.close()
    c = sqlite3.connect(tmp.name)
    out = {"model": os.path.basename(path), "sketches": [], "features": [], "bodies": []}

    for sid, name, cx, cy, cz, nx, ny, nz, ux, uy, uz in c.execute(
        "SELECT SketchID, CAST(Name AS TEXT), PlaneCenterX,PlaneCenterY,PlaneCenterZ,"
        "PlaneNormX,PlaneNormY,PlaneNormZ,PlaneUDirX,PlaneUDirY,PlaneUDirZ FROM SketchControllers"):
        curves = []
        for (d,) in c.execute("SELECT CAST(Data AS TEXT) FROM SketchCurves WHERE SketchID=?", (sid,)):
            try: j = json.loads(d)
            except Exception: continue
            j["kind"] = CURVE.get(j.get("type"), f"type{j.get('type')}")
            curves.append(j)
        out["sketches"].append({"name": name, "origin": [cx,cy,cz],
                                "normal": [nx,ny,nz], "udir": [ux,uy,uz], "curves": curves})

    nodes = {}
    for nid, t, p in c.execute(
        "SELECT HistoryTreeNodeID,HistoryTreeNodeType,CAST(Properties AS TEXT) FROM HistoryTreeNodes"):
        try: nodes[nid] = (t, json.loads(p))
        except Exception: nodes[nid] = (t, {})
    for nid, (t, pr) in sorted(nodes.items()):
        if "functionName" not in pr: continue
        params = []
        for pid in pr.get("parameters", []):
            _, pp = nodes.get(pid, (None, {}))
            lv = pp.get("literalValue")
            params.append(literal(lv) if lv else {"ref": pid})
        out["features"].append({"id": nid, "op": pr["functionName"],
                                "step": pr.get("stepName"), "params": params})

    for (nm, ln) in c.execute("SELECT CAST(ShapeName AS TEXT), length(ShapeData) FROM Shapes"):
        out["bodies"].append({"name": nm, "parasolid_bytes": ln})
    os.unlink(tmp.name)
    return out

if __name__ == "__main__":
    print(json.dumps(extract(sys.argv[1]), indent=1))
