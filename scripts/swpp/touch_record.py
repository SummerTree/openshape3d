#!/usr/bin/env python3
"""Record a problem built BY TOUCH on the simulator into the ledger.

    python3 scripts/swpp/touch_record.py 1.1 72593 --features "Extrude Boss" --note "…"
    python3 scripts/swpp/touch_record.py 1.4 0.146 --unit in

The build itself happened through the app's own palette (the fingers), so
there is no recipe to replay: this reads the finished document back over the
bridge exactly as `kit.run_problem` does — every visible body's B-rep volume,
/v1/check on each, the feature count and eval errors — scores it against the
sheet's printed volume to 0.5 %, and appends a row with `mode: "touch"` so
`report.py` marks it "(by touch)".
"""
import argparse, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kit  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("problem")
    ap.add_argument("volume", type=float, help="the sheet's printed volume")
    ap.add_argument("--unit", default="mm", choices=["mm", "in"])
    ap.add_argument("--features", default="")
    ap.add_argument("--note", default="")
    ap.add_argument("--bodies", default="", help="comma-separated body ids (default: every visible body)")
    a = ap.parse_args()

    st = kit.state()
    ids = [b for b in a.bodies.split(",") if b] or [b["id"] for b in st["bodies"] if not b.get("hidden")]
    got_mm3 = sum(kit.vol(b) for b in ids)
    got = got_mm3 / kit.IN3 if a.unit == "in" else got_mm3
    err = (got - a.volume) / a.volume
    healthy = all(kit.check(b) for b in ids)
    row = {"problem": a.problem, "doc": st["document"], "unit": a.unit, "expected": a.volume,
           "features": [f.strip() for f in a.features.split(",") if f.strip()],
           "ts": time.strftime("%Y-%m-%d %H:%M"), "mode": "touch",
           "got": round(got, 3), "errorPct": round(err * 100, 3), "healthy": healthy,
           "features_recorded": st["featureCount"], "evalErrors": st.get("evalErrors") or [],
           "bodies": ids,
           "status": "pass" if abs(err) <= 0.005 and healthy and not st.get("evalErrors") else "fail"}
    if a.note:
        row["note"] = a.note
    kit.ledger(row)
    print(f"[{row['status'].upper()}] {a.problem} by touch: {row['got']} vs {a.volume} "
          f"({row['errorPct']:+.3f} %), healthy={healthy}, features={st['featureCount']}")


if __name__ == "__main__":
    main()
