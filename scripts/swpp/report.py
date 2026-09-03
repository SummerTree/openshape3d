#!/usr/bin/env python3
"""Summarise scripts/swpp/results.jsonl against the problem index.

    python3 scripts/swpp/report.py            # markdown to stdout
    python3 scripts/swpp/report.py --json     # machine-readable summary

The latest row per problem wins (re-runs supersede). `notes.json` adds a
one-line reason per problem for anything that is not a clean pass.
"""
import json, os, sys, collections

HERE = os.path.dirname(os.path.abspath(__file__))
LEDGER = os.path.join(HERE, "results.jsonl")
NOTES = os.path.join(HERE, "notes.json")
INDEX = os.environ.get("SWPP_INDEX", "/private/tmp/claude-501/-Users-thelodgestudio-projects-openshape3d/"
                       "dc9b4b67-6478-4caa-9786-2ae7de0be4aa/scratchpad/swpp/problems.json")

LEVELS = {
    1: "Basic Sketch & Extrusion", 2: "Sketch Tools & End Conditions",
    3: "Global Variables & Sketch Patterns", 4: "Extrude Cut & Fillet/Chamfer",
    5: "Reference Geometry", 6: "Revolve Boss/Cut", 7: "Feature Patterning",
    8: "Sweep Boss/Cut", 9: "Assemblies and Mates", 10: "CSWA Exam Level",
    11: "Hole Wizard", 12: "Draft", 13: "Shell", 14: "Rib",
    15: "Configurations, Design Tables, Suppress", 16: "Global Variables, Equations, Link Values",
    17: "Move, Rotate, Collision & Interference", 18: "CSWP Exam Level",
}
COUNTS = {1: 20, 2: 20, 3: 8, 4: 70, 5: 15, 6: 20, 7: 48, 8: 14, 9: 16, 10: 19,
          11: 12, 12: 9, 13: 13, 14: 9, 15: 16, 16: 7, 17: 14, 18: 35}


def load():
    latest = {}
    if os.path.exists(LEDGER):
        for line in open(LEDGER):
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            latest[row["problem"]] = row
    notes = json.load(open(NOTES)) if os.path.exists(NOTES) else {}
    index = {}
    if os.path.exists(INDEX):
        for p in json.load(open(INDEX))["data"]["problems"]:
            index[p["problemTitle"].split()[-1]] = p
    return latest, notes, index


def level_of(pid):
    return int(pid.split(".")[0])


def summarise(latest, notes, index):
    per = collections.defaultdict(lambda: {"pass": 0, "fail": 0, "error": 0, "rows": []})
    for pid, row in latest.items():
        lv = level_of(pid)
        per[lv][row["status"]] += 1
        per[lv]["rows"].append(row)
    out = []
    for lv in sorted(LEVELS):
        d = per.get(lv)
        out.append({"level": lv, "title": LEVELS[lv], "total": COUNTS[lv],
                    "attempted": (d["pass"] + d["fail"] + d["error"]) if d else 0,
                    "pass": d["pass"] if d else 0, "fail": d["fail"] if d else 0,
                    "error": d["error"] if d else 0,
                    "rows": sorted(d["rows"], key=lambda r: tuple(int(x) if x.isdigit() else 0 for x in r["problem"].split("."))) if d else []})
    return out


def main():
    latest, notes, index = load()
    levels = summarise(latest, notes, index)
    if "--json" in sys.argv:
        print(json.dumps({"levels": levels, "notes": notes}, indent=1))
        return
    tot_att = sum(l["attempted"] for l in levels)
    tot_pass = sum(l["pass"] for l in levels)
    print(f"# SOLIDWORKS practice problems in openshape3d — {tot_pass}/{tot_att} attempted pass (365 in the database)\n")
    print("| Level | Title | Problems | Attempted | Pass | Fail | Error |")
    print("|---|---|---|---|---|---|---|")
    for l in levels:
        print(f"| {l['level']} | {l['title']} | {l['total']} | {l['attempted']} | {l['pass']} | {l['fail']} | {l['error']} |")
    print()
    for l in levels:
        if not l["rows"]:
            continue
        print(f"## Level {l['level']}: {l['title']}\n")
        print("| Problem | Features | Sheet | Got | Error | Status | Note |")
        print("|---|---|---|---|---|---|---|")
        for r in l["rows"]:
            feats = ", ".join(r.get("features", []))
            unit = "in³" if r.get("unit") == "in" else "mm³"
            got = f"{r['got']:,} {unit}" if "got" in r else "—"
            err = f"{r['errorPct']:+.2f} %" if "errorPct" in r else "—"
            note = notes.get(r["problem"], r.get("note", r.get("message", "")))
            if r.get("configs"):
                note = (note + " " if note else "") + "Configurations: " + "; ".join(
                    f"{c['label']} {c['got']:,} vs {c['expected']:,} ({c['errorPct']:+.2f} %)" for c in r["configs"])
            mode = " (by touch)" if r.get("mode") == "touch" else ""
            print(f"| {r['problem']}{mode} | {feats} | {r['expected']:,} {unit} | {got} | {err} | {r['status']} | {note} |")
        print()
    deferred_path = os.path.join(HERE, "deferred.json")
    if os.path.exists(deferred_path):
        deferred = json.load(open(deferred_path))
        def key(pid):
            a, b = pid.split("."); return (int(a), int("".join(ch for ch in b if ch.isdigit())), b)
        print(f"## Read but not attempted ({len(deferred)} sheets)\n")
        print("Sheets read from their drawings and set aside: the drawing does not fix")
        print("the geometry, or the printed volume contradicts every reading tried. None")
        print("is an app limitation.\n")
        print("| Problem | Why it was set aside |")
        print("|---|---|")
        for pid in sorted(deferred, key=key):
            print(f"| {pid} | {deferred[pid]} |")
        print()


if __name__ == "__main__":
    main()
