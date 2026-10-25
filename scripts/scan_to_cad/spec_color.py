"""The colour a part's model is painted, resolved from its spec and its
analysis.

Standard library only, on purpose: `run_corpus.py` runs under whatever
`python3` is on the path and hands the venv interpreter to the scripts it
launches, so the resolver it shares with `build_hydrant.py` (which paints
the model) and `inspect_fit.py --model-color` (which paints the sheet)
must not drag numpy in with it.
"""

HYDRANT_RED = [0.86, 0.17, 0.12]


def model_color(spec, analysis):
    """The colour the model is painted, as [r, g, b] in 0…1: the spec's own
    list when it gives one; otherwise ("scan", or no `color` at all) the
    scan's dominant colour that `analyze_scan.py` recorded as `scanColor`,
    and the hydrant's red when the analysis has none. A red model beside a
    grey scan reads as a shape mismatch, so the scan's colour is the
    default."""
    chosen = (spec or {}).get("color", "scan")
    if isinstance(chosen, str):
        if chosen != "scan":
            raise ValueError("color must be 'scan' or [r, g, b], not %r" % chosen)
        found = (analysis or {}).get("scanColor") or {}
        return [float(c) for c in found["rgb"]] if found.get("rgb") else list(HYDRANT_RED)
    return [float(c) for c in chosen]


def color_option(values):
    """`--color scan` or `--color R G B` as a spec's `color` value; anything
    else — `scan` with numbers after it, two numbers, a word — is refused
    with the usage line rather than a bare float() error."""
    if values is None or list(values) == ["scan"]:
        return "scan"
    try:
        if len(values) != 3:
            raise ValueError
        return [float(v) for v in values]
    except (TypeError, ValueError):
        raise SystemExit("--color takes 'scan' or three numbers in 0…1, not %r" % (list(values),))
