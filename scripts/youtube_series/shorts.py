#!/usr/bin/env python3
"""YouTube Shorts: "How do you model this?" — one part, built by real touches
on an upright iPhone, in under a minute.

    shorts.py spring|vase|donut|bowl|nut|loft|pipe|gem|frame|ring
        [--take-only | --compose-only]

The take runs on the `os3d-shorts` simulator (iPhone 17 Pro Max) through
ActionTakeUITests in portrait; the touch sequences are in shorts_actions.py,
the captions and narration in shorts_text.py. Compose makes a 1080 × 1920
video:

* the hook — the finished part turning (the take's last step, zoomed in)
  under "How do you model a …?";
* every step of the build, each played just fast enough to fit its
  narration (silent steps faster still), with the step's caption and a ring
  wherever a finger touched;
* the finished part again, and an end card.

Output: marketing/youtube/shorts/openshape3d-short-NN-<slug>.mp4 and
-metadata.md (title, description, tags).
"""
import os
os.environ.setdefault("OS3D_VIDEO_SIM", "os3d-shorts")
os.environ.setdefault("OS3D_VIDEO_POINTS", "440x956")
os.environ.setdefault("OS3D_VIDEO_ORIENTATION", "portrait")
os.environ.setdefault("OS3D_TUTORIAL_BRIDGE_PORT", "8933")
os.environ.setdefault("OS3D_TUTORIAL_CONTROL_PORT", "8932")
os.environ.setdefault("OS3D_VOICE_RATE", "+6%")

import argparse, json, math, subprocess, sys
from PIL import Image, ImageDraw
from common import S, OUT_DIR, run_take, synthesize, run, log, font, icon, music_bed
from shorts_text import SHORTS
from shorts_actions import BUILDERS, P

OUT = os.path.join(os.environ.get("OS3D_VIDEO_OUT", OUT_DIR), "shorts")
OW, OH, FPS = 1080, 1920, 30
CROP_T, CROP_B = 150, 110              # status bar / home indicator, source pixels
MAX_SPOKEN, MAX_SILENT = 3.0, 5.0      # fastest a step may play (×) …
TARGET = 57.0                          # … raised (to 6× / 12×) until the Short fits this
TOUCH_S = 0.5
WHITE, INK, ACCENT = (255, 255, 255, 255), (8, 10, 14, 255), (56, 142, 245, 255)


def segments(short):
    return [{"id": i, "cap": c, "say": s} for i, c, s in short["steps"]]


# ---- the take ---------------------------------------------------------------------------------

def make_take(key):
    def take(t):
        a = P(t)
        for sid in BUILDERS[key](a):
            if t.tl.cur:
                t.tl.hold(0.1)
            t.tl.begin(sid)
        t.tl.hold(0.3)
    return take


# ---- geometry of the frame ----------------------------------------------------------------------

class Frame:
    """Source (the phone recording) → output (1080 × 1920)."""

    def __init__(self, raw):
        out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                              "stream=width,height", "-of", "csv=p=0", raw], capture_output=True, text=True).stdout
        self.sw, self.sh = map(int, out.strip().split(",")[:2])
        self.ch = self.sh - CROP_T - CROP_B
        self.s = OH / self.ch
        self.fw = int(round(self.sw * self.s / 2) * 2)
        self.x0 = (OW - self.fw) // 2

    def out(self, nx, ny):
        return self.x0 + nx * self.sw * self.s, (ny * self.sh - CROP_T) * self.s

    def base_filter(self):
        return (f"split[a][b];[a]crop={self.sw}:{self.ch}:0:{CROP_T},scale={self.fw}:{OH}:flags=lanczos[fg];"
                f"[b]crop={self.sw}:{self.ch}:0:{CROP_T},scale={OW}:-2,crop={OW}:{OH},boxblur=28:2,"
                f"eq=brightness=-0.18:saturation=0.8[bg];[bg][fg]overlay={self.x0}:0")

    def zoom_filter(self, focus):
        fx0, fy0, fx1, fy1 = focus
        cx, cy = (fx0 + fx1) / 2 * self.sw, (fy0 + fy1) / 2 * self.sh
        w = max((fx1 - fx0) * self.sw * 1.5, (fy1 - fy0) * self.sh * 1.5 * OW / OH, self.sw * 0.55)
        w = min(w, self.sw)
        h = w * OH / OW
        if h > self.sh:
            h = self.sh; w = h * OW / OH
        x = min(max(cx - w / 2, 0), self.sw - w)
        y = min(max(cy - h / 2, 0), self.sh - h)
        return f"crop={int(w)}:{int(h)}:{int(x)}:{int(y)},scale={OW}:{OH}:flags=lanczos"


# ---- the edit: which raw seconds play when, how fast ------------------------------------------------

def frames(t):
    return max(1, int(round(t * FPS)))


def plan(tl, clips_dur, short):
    segs = tl["segments"]
    rv = next(s for s in segs if s["id"] == "reveal")
    orbit = rv["marks"][0] if rv.get("marks") else rv["end"] - 4.0
    pieces = []
    hook_d = max(clips_dur.get("hook", 0) + 0.7, 2.4)
    pieces.append({"kind": "hook", "id": "hook", "r0": orbit, "r1": min(rv["end"], orbit + hook_d * 1.3),
                   "d": hook_d, "focus": rv.get("focus")})
    n = clips_dur.get("reveal", 0.0)
    fixed = hook_d + max(rv["end"] - rv["start"], n + 0.6 + 2.6)
    build = [s for s in segs if s["id"] != "reveal"]

    def lengths(sp, si):
        out = []
        for s in build:
            raw, n = s["end"] - s["start"], clips_dur.get(s["id"], 0.0)
            out.append(max(n + 0.1, raw / sp) if n else max(0.25, raw / si))
        return out
    sp, si = MAX_SPOKEN, MAX_SILENT
    while fixed + sum(lengths(sp, si)) > TARGET and (sp < 6 or si < 12):
        sp, si = min(6.0, sp * 1.1), min(12.0, si * 1.1)
    for s, d in zip(build, lengths(sp, si)):
        pieces.append({"kind": "main", "id": s["id"], "r0": s["start"], "r1": s["end"], "d": d})
    pieces.append({"kind": "main", "id": "reveal", "r0": rv["start"], "r1": rv["end"],
                   "d": fixed - hook_d})
    t = 0.0
    for p in pieces:
        p["n"] = frames(p["d"])
        p["d"] = p["n"] / FPS
        p["o0"] = t
        p["k"] = (p["r1"] - p["r0"]) / p["d"]
        t += p["d"]
    return pieces, t


def raw_to_out(pieces, t):
    for p in pieces:
        if p["kind"] == "main" and p["r0"] <= t < p["r1"]:
            return p, p["o0"] + (t - p["r0"]) / p["k"]
    return None, None


# ---- overlays -----------------------------------------------------------------------------------

def text_block(d, lines, f, cx, cy, fill=WHITE, stroke=8, lh=1.12):
    size = f.size
    total = len(lines) * size * lh
    y = cy - total / 2
    for line in lines:
        w = d.textlength(line, font=f)
        d.text((cx - w / 2, y), line, font=f, fill=fill, stroke_width=stroke, stroke_fill=INK)
        y += size * lh


def wrap(d, text, f, width):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if d.textlength(t, font=f) <= width or not cur:
            cur = t
        else:
            lines.append(cur); cur = w
    if cur:
        lines.append(cur)
    return lines


BANDS = (360, 1390)                    # caption centres: under the top bars, or below the part


def caption(d, fr, text, cy=BANDS[1]):
    f = font(70, True)
    left = fr.out(0.2, 0)[0]
    cx = (left + OW - 30) / 2
    text_block(d, wrap(d, text, f, OW - 30 - left - 20), f, cx, cy)


def caption_bands(base, build, fr, pieces, touches):
    """Per step, the caption band that covers the least of the app: the one
    with less edge detail in the frame (a sheet, a keypad, a flyout) and no
    touch in it."""
    from PIL import ImageFilter, ImageStat
    left = int(fr.out(0.2, 0)[0])
    out = {}
    for i, p in enumerate(pieces):
        if p["kind"] != "main":
            continue
        scores = [0.0] * len(BANDS)
        for u in (0.3, 0.7):
            t = p["o0"] + p["d"] * u
            png = os.path.join(build, f"probe-{i:03d}.png")
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", f"{t:.3f}", "-i", base, "-frames:v", "1", png],
                           check=True)
            edges = Image.open(png).convert("L").filter(ImageFilter.FIND_EDGES)
            for k, cy in enumerate(BANDS):
                scores[k] += ImageStat.Stat(edges.crop((left, cy - 95, OW - 30, cy + 95))).mean[0]
        for tc in touches:
            if tc["t"] < p["o0"] + p["d"] and tc["end"] > p["o0"]:
                for (nx, ny) in tc["pts"]:
                    y = fr.out(nx, ny)[1]
                    for k, cy in enumerate(BANDS):
                        if abs(y - cy) < 150:
                            scores[k] += 100
        out[p["id"]] = BANDS[min(range(len(BANDS)), key=lambda k: scores[k] - (1.5 if k == 1 else 0))]
    return out


def hook_card(d, short):
    f = font(104, True)
    text_block(d, wrap(d, short["hook"], f, 900), f, OW / 2, 1240, stroke=10)
    tag = f"CAD TIP #{short['n']}"
    tf = font(40, True)
    w = d.textlength(tag, font=tf)
    d.rounded_rectangle([OW / 2 - w / 2 - 26, 214, OW / 2 + w / 2 + 26, 282], radius=34, fill=(14, 17, 22, 215))
    d.text((OW / 2 - w / 2, 226), tag, font=tf, fill=WHITE)


def end_card(im, d):
    x0, y0, x1, y1 = 90, 170, OW - 90, 640
    d.rounded_rectangle([x0, y0, x1, y1], radius=44, fill=(12, 15, 20, 228))
    ic = icon(150)
    im.alpha_composite(ic, (int(OW / 2 - 75), y0 + 42))
    for text, f, fill, y in (("OpenShape 3D", font(76, True), WHITE, y0 + 222),
                             ("Free on iPhone · iPad · Mac", font(46), (214, 220, 230, 255), y0 + 318),
                             ("Search it on the App Store", font(40, True), ACCENT, y0 + 384)):
        w = d.textlength(text, font=f)
        d.text((OW / 2 - w / 2, y), text, font=f, fill=fill)


def touches_out(tl, pieces):
    out = []
    for e in tl.get("touches", []):
        kind, arg = e["what"].split(":", 1)
        p, t = raw_to_out(pieces, e["t"] + 0.08)
        if p is None:
            continue
        if kind in ("tap", "double"):
            x, y = map(float, arg.split(","))
            out.append({"kind": kind, "t": t, "end": t + TOUCH_S + (0.18 if kind == "double" else 0), "pts": [(x, y)]})
        elif kind == "drag":
            a, b, hold = arg.split(";")
            p0, p1, hold = tuple(map(float, a.split(","))), tuple(map(float, b.split(","))), float(hold)
            life = (hold + 0.9 + 0.45) / p["k"]
            out.append({"kind": "drag", "t": t, "end": t + life, "pts": [p0, p1], "hold": hold, "k": p["k"]})
    return out


def draw_touch(d, fr, now, tc):
    age = now - tc["t"]
    def ring(x, y, a):
        grow = 26 + 38 * min(1.0, a / TOUCH_S)
        alpha = max(0, int(220 * (1 - a / TOUCH_S)))
        d.ellipse([x - grow, y - grow, x + grow, y + grow], outline=(255, 255, 255, alpha), width=5)
        dot = max(0, int(190 * (1 - max(0.0, a - 0.22) / (TOUCH_S - 0.22))))
        d.ellipse([x - 26, y - 26, x + 26, y + 26], fill=(255, 255, 255, dot), outline=(20, 90, 200, min(255, dot + 60)), width=4)
    if tc["kind"] in ("tap", "double"):
        x, y = fr.out(*tc["pts"][0])
        ring(x, y, age)
        if tc["kind"] == "double" and age > 0.18:
            ring(x, y, age - 0.18)
    else:
        raw_age = age * tc["k"]
        (x0, y0), (x1, y1) = fr.out(*tc["pts"][0]), fr.out(*tc["pts"][1])
        u = 0.0 if raw_age < tc["hold"] else min(1.0, (raw_age - tc["hold"]) / 0.9)
        u = u * u * (3 - 2 * u)
        x, y = x0 + (x1 - x0) * u, y0 + (y1 - y0) * u
        fade = 1.0 if raw_age < tc["hold"] + 0.9 else max(0.0, 1 - (raw_age - tc["hold"] - 0.9) / 0.45)
        d.line([x0, y0, x, y], fill=(255, 255, 255, int(160 * fade)), width=7)
        d.ellipse([x - 26, y - 26, x + 26, y + 26], fill=(255, 255, 255, int(190 * fade)),
                  outline=(20, 90, 200, int(230 * fade)), width=4)


def overlay_track(build, fr, short, pieces, total, touches, bands):
    caps = {s["id"]: s["cap"] for s in segments(short)}
    last = pieces[-1]
    end_at = total - 2.6
    cuts = {0.0, total, end_at}
    for p in pieces:
        cuts |= {p["o0"], p["o0"] + p["d"]}
    for tc in touches:
        f0, f1 = int(tc["t"] * FPS), int(math.ceil(tc["end"] * FPS))
        cuts |= {f / FPS for f in range(f0, f1 + 1)}
    cuts = sorted(c for c in cuts if 0 <= c <= total)
    cache, n, listing = {}, 0, os.path.join(build, "overlay.txt")
    with open(listing, "w") as out:
        path = None
        for a, b in zip(cuts, cuts[1:]):
            if b - a < 1e-4:
                continue
            mid = (a + b) / 2
            p = next((q for q in pieces if q["o0"] <= mid < q["o0"] + q["d"]), last)
            live = [tc for tc in touches if tc["t"] <= mid < tc["end"]]
            ending = p is last and mid >= end_at
            key = (p["id"], ending, tuple((tc["t"], round(mid - tc["t"], 3)) for tc in live))
            if key not in cache:
                im = Image.new("RGBA", (OW, OH), (0, 0, 0, 0))
                d = ImageDraw.Draw(im, "RGBA")
                if p["kind"] == "hook":
                    hook_card(d, short)
                elif ending:
                    end_card(im, d)
                elif caps.get(p["id"]):
                    caption(d, fr, caps[p["id"]], bands.get(p["id"], BANDS[1]))
                for tc in live:
                    draw_touch(d, fr, mid, tc)
                path = os.path.join(build, f"ov-{n:05d}.png"); n += 1
                im.save(path, compress_level=1)
                cache[key] = path
            path = cache[key]
            out.write(f"file '{path}'\nduration {b - a:.4f}\n")
        out.write(f"file '{path}'\n")
    log(f"overlay: {n} stills, {len(touches)} touches")
    return listing


# ---- compose ----------------------------------------------------------------------------------------

def compose(key, take_dir, out_path):
    short = SHORTS[key]
    segs = segments(short)
    synthesize("short-" + key, segs)
    build = os.path.join(take_dir, "short")
    os.makedirs(build, exist_ok=True)
    # edge-tts pads each clip with ~0.4 s of silence at both ends: trim it,
    # or a one-word step ("New design.") holds the picture for two seconds
    clips, dur = {}, {}
    for seg in segs:
        if not seg.get("_clip"):
            continue
        trimmed = os.path.join(build, f"voice-{seg['id']}.wav")
        silence = "silenceremove=start_periods=1:start_threshold=-48dB:start_silence=0.04"
        run(["ffmpeg", "-y", "-loglevel", "error", "-i", seg["_clip"], "-af",
             f"{silence},areverse,{silence},areverse,apad=pad_dur=0.06", "-ar", "48000", trimmed])
        clips[seg["id"]] = trimmed
        dur[seg["id"]] = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of",
                                               "csv=p=0", trimmed], capture_output=True, text=True).stdout.strip())
    tl = json.load(open(os.path.join(take_dir, "timeline.json")))
    raw = os.path.join(take_dir, "raw.mp4")
    fr = Frame(raw)
    pieces, total = plan(tl, dur, short)
    log(f"{key}: {len(pieces)} pieces, {total:.1f} s (take {tl['total']:.0f} s)")
    # 1. every piece at its speed, laid out on the 1080 × 1920 frame
    parts = []
    for i, p in enumerate(pieces):
        part = os.path.join(build, f"piece-{i:03d}.mp4")
        span = p["r1"] - p["r0"]
        body = fr.zoom_filter(p["focus"]) if p["kind"] == "hook" and p.get("focus") else fr.base_filter()
        vf = (f"setpts=(PTS-STARTPTS)/{p['k']:.5f},fps={FPS},tpad=stop_mode=clone:stop_duration=6,"
              f"{body},format=yuv420p")
        run(["ffmpeg", "-y", "-loglevel", "error", "-ss", f"{max(0.0, p['r0']):.3f}", "-t", f"{span + 0.2:.3f}",
             "-i", raw, "-filter_complex", vf, "-frames:v", str(p["n"]), "-r", str(FPS),
             "-c:v", "libx264", "-preset", "fast", "-crf", "17", "-an", part])
        parts.append(part)
    with open(os.path.join(build, "parts.txt"), "w") as f:
        for part in parts:
            f.write(f"file '{part}'\n")
    base = os.path.join(build, "base.mp4")
    run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", os.path.join(build, "parts.txt"),
         "-c", "copy", base])
    # 2. captions, touch rings, the hook and the end card
    touches = touches_out(tl, pieces)
    listing = overlay_track(build, fr, short, pieces, total, touches, caption_bands(base, build, fr, pieces, touches))
    video = os.path.join(build, "video.mp4")
    run(["ffmpeg", "-y", "-loglevel", "error", "-i", base, "-f", "concat", "-safe", "0", "-i", listing,
         "-filter_complex", f"[1:v]fps={FPS},format=rgba[ov];[0:v][ov]overlay=0:0:eof_action=repeat,"
                            f"fade=t=out:st={total - 0.35:.2f}:d=0.35,format=yuv420p[v]",
         "-map", "[v]", "-t", f"{total:.3f}", "-c:v", "libx264", "-preset", "medium", "-crf", "18",
         "-r", str(FPS), "-an", video])
    # 3. narration on each piece, over a music bed
    bed = music_bed(os.path.join(S, "music-bed.wav"))
    ins = ["ffmpeg", "-y", "-loglevel", "error", "-i", video, "-i", bed]
    af, mix = [], []
    at = {p["id"]: p["o0"] for p in pieces}
    for sid in [s for s in clips if s not in at]:
        log(f"WARNING: no step {sid!r} in the take; its narration is dropped")
        clips.pop(sid)
    for k, (sid, c) in enumerate(clips.items()):
        ins += ["-i", c]
        off = int((at[sid] + (0.12 if sid == "hook" else 0.3 if sid == "reveal" else 0.04)) * 1000)
        af.append(f"[{k + 2}:a]aformat=sample_rates=48000:channel_layouts=stereo,adelay={off}|{off}[n{k}]")
        mix.append(f"[n{k}]")
    af.append(f"{''.join(mix)}amix=inputs={len(mix)}:normalize=0:dropout_transition=0,"
              f"loudnorm=I=-14:TP=-1.5:LRA=11[voice]")
    af.append(f"[1:a]atrim=0:{total:.2f},volume=0.3,afade=t=in:st=0:d=0.4,afade=t=out:st={total - 1.2:.2f}:d=1.2[music]")
    # music first: amix's duration=first then runs to the end of the picture
    af.append("[music][voice]amix=inputs=2:normalize=0:duration=first,loudnorm=I=-14:TP=-1.5:LRA=11[a]")
    ins += ["-filter_complex", ";".join(af), "-map", "0:v", "-map", "[a]", "-t", f"{total:.3f}",
            "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart", out_path]
    run(ins)
    log(f"wrote {out_path} ({total:.1f} s)")
    return total


def write_metadata(path, short, seconds):
    with open(path, "w") as f:
        f.write(f"# {short['title']}\n\n")
        f.write(f"**Title ({len(short['title'])} chars):** {short['title']}\n\n")
        f.write(f"**Length:** {seconds:.1f} s (vertical 1080 × 1920)\n\n")
        f.write("## Description\n\n```\n" + short["description"] + "\n```\n\n")
        f.write("## Tags\n\n```\n" + ", ".join(short["tags"]) + "\n```\n")
    log(f"wrote {path}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("short", choices=list(SHORTS))
    ap.add_argument("--take-only", action="store_true")
    ap.add_argument("--compose-only", action="store_true")
    a = ap.parse_args()
    short = SHORTS[a.short]
    take_dir = os.path.join(S, "take-short-" + a.short)
    if not a.compose_only:
        run_take("short-" + a.short, segments(short), make_take(a.short), take_dir, test="ActionTakeUITests")
    if not a.take_only:
        os.makedirs(OUT, exist_ok=True)
        stem = os.path.join(OUT, f"openshape3d-short-{short['n']:02d}-{short['slug']}")
        secs = compose(a.short, take_dir, stem + ".mp4")
        write_metadata(stem + "-metadata.md", short, secs)
