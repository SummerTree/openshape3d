#!/usr/bin/env python3
"""Run SOLIDWORKS practice problems against the live app.

    python3 scripts/swpp/run.py 1.1 1.9          # by number
    python3 scripts/swpp/run.py level:1          # every registered problem of a level
    python3 scripts/swpp/run.py all
    OS3D_KEEP_DOC=1 …                            # build into the open document

Problems register themselves in `levelN.py` modules via `PROBLEMS[pid] =
(meta, build)`; `meta` carries the sheet's volume and unit.
"""
import importlib, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kit  # noqa: E402

PROBLEMS = {}
for n in range(1, 19):
    try:
        mod = importlib.import_module(f"level{n}")
        PROBLEMS.update(mod.PROBLEMS)
    except ModuleNotFoundError:
        pass


def main():
    args = sys.argv[1:] or ["all"]
    selected = []
    for a in args:
        if a == "all":
            selected += sorted(PROBLEMS, key=lambda s: tuple(int(x) for x in s.split(".")))
        elif a.startswith("level:"):
            lv = int(a.split(":")[1])
            selected += sorted((p for p in PROBLEMS if int(p.split(".")[0]) == lv),
                               key=lambda s: tuple(int(x) for x in s.split(".")))
        else:
            selected.append(a)
    fresh = os.environ.get("OS3D_KEEP_DOC") != "1"
    rows = []
    for pid in selected:
        if pid not in PROBLEMS:
            print(f"[SKIP] {pid}: no recipe registered")
            continue
        meta, build = PROBLEMS[pid]
        rows.append(kit.run_problem(pid, meta, build, fresh=fresh))
    passed = sum(1 for r in rows if r["status"] == "pass")
    print(f"\n{passed}/{len(rows)} passed")


if __name__ == "__main__":
    main()
