"""Compose a CAD-actions video: the take, a step panel, a caption per step,
and a ring wherever a finger touched.

A video's script (action_text.py) is chapters of steps; every step is one
timeline segment with its own narration clip. The panel lists the chapter's
steps (done ✓ / current / next), the caption pill under the app says what the
current step does, and every touch the test reported (`vis:tap`, `vis:double`,
`vis:drag`) is drawn where it landed — so a viewer can follow each tap.

All overlays are flattened into ONE image track (concat demuxer: a still per
interval, one per frame while a touch animates), then laid over the take.
"""
import json, math, os, subprocess
from PIL import Image, ImageDraw
from common import (W, H, VW, BG, PANEL, FG, MUTED, ACCENT, TITLE_S, OUTRO_S, S,
                    font, icon, wrap, card, music_bed, run, log)

FPS = 30
DONE, NEXT = (120, 200, 140), (95, 103, 118)
TOUCH_S = 0.55                         # a tap ring's life
DEVICES = "iPhone · iPad · Mac"


def steps_of(video):
    """Flatten chapters → [(chapter_index, step_index_in_chapter, step)]."""
    out = []
    for ci, ch in enumerate(video["chapters"]):
        for si, st in enumerate(ch["steps"]):
            out.append((ci, si, st))
    return out


def segments(video):
    """The narration segments (common.synthesize / write_metadata shape)."""
    segs = []
    for ci, si, st in steps_of(video):
        ch = video["chapters"][ci]
        segs.append({"id": st["id"], "say": st["say"], "chapter": ch["title"] if si == 0 else None})
    return segs


# ---- panel + caption -------------------------------------------------------------------

def panel(video, ci, si, path):
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    x0, pad = VW, 34
    cw = W - x0 - 2 * pad
    d.rectangle([x0, 0, W, H], fill=PANEL + (255,))
    d.rectangle([x0, 0, x0 + 2, H], fill=(40, 46, 56, 255))
    im.alpha_composite(icon(44), (x0 + pad, 36))
    d.text((x0 + pad + 58, 42), "OpenShape 3D", font=font(26, True), fill=FG)
    d.text((x0 + pad + 58, 72), video["series"], font=font(18), fill=MUTED)
    ch = video["chapters"][ci]
    y = 150
    d.text((x0 + pad, y), f"STEP {ci + 1} OF {len(video['chapters'])}", font=font(17, True), fill=ACCENT)
    y += 28
    for line in wrap(d, ch["title"], font(38, True), cw):
        d.text((x0 + pad, y), line, font=font(38, True), fill=FG); y += 46
    y += 18
    for k, st in enumerate(ch["steps"]):
        state = "done" if k < si else "now" if k == si else "next"
        colour = DONE if state == "done" else FG if state == "now" else NEXT
        f = font(24, state == "now")
        lines = wrap(d, st["do"], f, cw - 40)
        h = 31 * len(lines) + 14
        if state == "now":
            d.rounded_rectangle([x0 + pad - 12, y - 8, W - pad + 12, y + h - 6], radius=10,
                                fill=(36, 48, 70, 255), outline=ACCENT + (255,), width=2)
        mx, my = x0 + pad + 9, y + 14                 # marker centre, drawn (not a glyph)
        if state == "done":
            d.ellipse([mx - 10, my - 10, mx + 10, my + 10], fill=DONE + (255,))
            d.line([mx - 5, my, mx - 1, my + 4, mx + 6, my - 5], fill=(22, 26, 33, 255), width=3)
        elif state == "now":
            d.polygon([(mx - 6, my - 9), (mx + 8, my), (mx - 6, my + 9)], fill=ACCENT + (255,))
        else:
            d.ellipse([mx - 4, my - 4, mx + 4, my + 4], fill=NEXT + (255,))
        for line in lines:
            d.text((x0 + pad + 30, y), line, font=f, fill=colour); y += 31
        y += 14
        if y > H - 190:
            break
    # footer: devices badge + progress
    d.rounded_rectangle([x0 + pad, H - 150, x0 + pad + 250, H - 112], radius=19, fill=(36, 48, 70, 255))
    d.text((x0 + pad + 18, H - 144), DEVICES, font=font(20, True), fill=FG)
    n = len(video["chapters"])
    d.text((x0 + pad, H - 90), f"{ci + 1} / {n}", font=font(20), fill=MUTED)
    d.rectangle([x0 + pad, H - 56, x0 + pad + cw, H - 52], fill=(45, 51, 62, 255))
    d.rectangle([x0 + pad, H - 56, x0 + pad + int(cw * (ci + 1) / n), H - 52], fill=ACCENT + (255,))
    im.save(path)


def caption(d, text):
    """What the current step does, top-left under the back button — the app
    keeps its bars at the top centre and the bottom, and its palette at the
    left from a third of the way down."""
    f = font(28, True)
    lines = wrap(d, text, f, 560)
    w = max(d.textlength(l, font=f) for l in lines) + 48
    h = 40 * len(lines) + 18
    x, y = 96, 96
    d.rounded_rectangle([x, y, x + w, y + h], radius=h / 2 if len(lines) == 1 else 18, fill=(14, 17, 22, 220))
    d.rounded_rectangle([x + 14, y + h / 2 - 5, x + 24, y + h / 2 + 5], radius=5, fill=ACCENT + (255,))
    ty = y + 10
    for l in lines:
        d.text((x + 36, ty), l, font=f, fill=(255, 255, 255, 255)); ty += 40


# ---- touches ------------------------------------------------------------------------------

def parse_touches(tl):
    """→ [(start, end, kind, points, hold)] in take seconds, window-normalised points."""
    out = []
    for e in tl.get("touches", []):
        kind, arg = e["what"].split(":", 1)
        t = e["t"] + 0.08                               # the tap lands just after the report
        if kind == "tap":
            x, y = map(float, arg.split(","))
            out.append((t, t + TOUCH_S, "tap", [(x, y)], 0))
        elif kind == "double":
            x, y = map(float, arg.split(","))
            out.append((t, t + TOUCH_S + 0.18, "double", [(x, y)], 0))
        elif kind == "drag":
            a, b, hold = arg.split(";")
            p0, p1 = tuple(map(float, a.split(","))), tuple(map(float, b.split(",")))
            hold = float(hold)
            move = 0.9                                   # XCUI's .slow drag, about this long
            out.append((t, t + hold + move + 0.45, "drag", [p0, p1], hold))
    return out


def draw_touch(d, now, touch):
    start, end, kind, pts, hold = touch
    age = now - start
    def px(p):
        return p[0] * VW, p[1] * H
    def ring(x, y, a):
        # a filled finger dot, and a ring expanding and fading behind it
        r = 24
        grow = 24 + 40 * min(1.0, a / TOUCH_S)
        alpha = max(0, int(200 * (1 - a / TOUCH_S)))
        d.ellipse([x - grow, y - grow, x + grow, y + grow], outline=(255, 255, 255, alpha), width=4)
        dot = max(0, int(170 * (1 - max(0.0, a - 0.25) / (TOUCH_S - 0.25))))
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, dot), outline=(20, 90, 200, min(255, dot + 60)), width=3)
    if kind == "tap":
        ring(*px(pts[0]), age)
    elif kind == "double":
        ring(*px(pts[0]), age)
        if age > 0.18:
            ring(*px(pts[0]), age - 0.18)
    elif kind == "drag":
        (x0, y0), (x1, y1) = px(pts[0]), px(pts[1])
        move = 0.9
        u = 0.0 if age < hold else min(1.0, (age - hold) / move)
        u = u * u * (3 - 2 * u)
        x, y = x0 + (x1 - x0) * u, y0 + (y1 - y0) * u
        fade = 1.0 if age < hold + move else max(0.0, 1 - (age - hold - move) / 0.45)
        d.line([x0, y0, x, y], fill=(255, 255, 255, int(150 * fade)), width=6)
        r = 24
        d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, int(170 * fade)),
                  outline=(20, 90, 200, int(230 * fade)), width=3)


# ---- compose -------------------------------------------------------------------------------

def compose(video, take_dir, out_path, clips):
    """take_dir/raw.mp4 + timeline.json + narration clips → out_path."""
    tl = json.load(open(os.path.join(take_dir, "timeline.json")))
    total = tl["total"]
    starts = {s["id"]: s for s in tl["segments"]}
    build = os.path.join(take_dir, "build")
    os.makedirs(build, exist_ok=True)
    flat = steps_of(video)
    # panel image per step
    panels = []
    for k, (ci, si, st) in enumerate(flat):
        p = os.path.join(build, f"panel-{k:03d}.png")
        panel(video, ci, si, p)
        seg = starts[st["id"]]
        end = starts[flat[k + 1][2]["id"]]["start"] if k + 1 < len(flat) else total
        panels.append((seg["start"], end, p, st["do"]))
    touches = parse_touches(tl)
    # cut times: every panel change, and every frame while a touch animates
    cuts = {0.0, total}
    for a, b, _, _ in panels:
        cuts |= {a, b}
    for start, end, *_ in touches:
        f0, f1 = int(start * FPS), int(math.ceil(end * FPS))
        cuts |= {f / FPS for f in range(f0, f1 + 1)}
    cuts = sorted(c for c in cuts if 0 <= c <= total)
    cache = {}
    listing = os.path.join(build, "overlay.txt")
    n = 0
    with open(listing, "w") as out:
        last = None
        for a, b in zip(cuts, cuts[1:]):
            if b - a < 1e-4:
                continue
            mid = (a + b) / 2
            cur = next((pp for pp in panels if pp[0] <= mid < pp[1]), panels[-1])
            live = [t for t in touches if t[0] <= mid < t[1]]
            key = (cur[2], tuple((t[0], round(mid - t[0], 3)) for t in live))
            if key not in cache:
                frame = Image.open(cur[2]).convert("RGBA")
                d = ImageDraw.Draw(frame, "RGBA")
                caption(d, cur[3])
                for t in live:
                    draw_touch(d, mid, t)
                path = os.path.join(build, f"ov-{n:05d}.png"); n += 1
                frame.save(path, compress_level=1)
                cache[key] = path
            last = cache[key]
            out.write(f"file '{last}'\nduration {b - a:.4f}\n")
        out.write(f"file '{last}'\n")
    log(f"overlay: {n} stills, {len(touches)} touches")
    raw = os.path.join(take_dir, "raw.mp4")
    fc = [f"[0:v]transpose=2,tpad=stop_mode=clone:stop_duration=30,fps={FPS},"
          f"scale={VW}:{H}:force_original_aspect_ratio=decrease:flags=lanczos,"
          f"pad={W}:{H}:0:(oh-ih)/2:color=0x{BG[0]:02x}{BG[1]:02x}{BG[2]:02x}[base]",
          f"[1:v]fps={FPS},format=rgba[ov]",
          "[base][ov]overlay=0:0:eof_action=repeat[o]",
          f"[o]format=yuv420p,fade=t=in:st=0:d=0.6,fade=t=out:st={total - 0.8:.2f}:d=0.8[v]"]
    main = os.path.join(build, "main.mp4")
    run(["ffmpeg", "-y", "-loglevel", "error", "-i", raw, "-f", "concat", "-safe", "0", "-i", listing,
         "-filter_complex", ";".join(fc), "-map", "[v]", "-t", f"{total:.2f}",
         "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-r", str(FPS), "-an", main])
    card(video["name"], f"OpenShape 3D · {DEVICES}", ["Every tap shown, step by step"],
         os.path.join(build, "title.png"), hero=video.get("hero"))
    card("Thanks for watching", "github.com/laanlabs/openshape3d",
         ["Free · open source · " + DEVICES, video.get("outro_foot", "More CAD basics on the channel")],
         os.path.join(build, "outro.png"), big=False)
    for name, dur in (("title", TITLE_S), ("outro", OUTRO_S)):
        run(["ffmpeg", "-y", "-loglevel", "error", "-loop", "1", "-i", os.path.join(build, name + ".png"),
             "-t", str(dur), "-vf", f"fps={FPS},format=yuv420p,fade=t=in:st=0:d=0.8,fade=t=out:st={dur - 0.8}:d=0.8",
             "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-r", str(FPS), "-an", os.path.join(build, name + ".mp4")])
    with open(os.path.join(build, "concat.txt"), "w") as f:
        for part in ("title", "main", "outro"):
            f.write(f"file '{os.path.join(build, part + '.mp4')}'\n")
    video_only = os.path.join(build, "video.mp4")
    run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", os.path.join(build, "concat.txt"),
         "-c", "copy", video_only])
    full = TITLE_S + total + OUTRO_S
    bed = music_bed(os.path.join(S, "music-bed.wav"))
    ins = ["ffmpeg", "-y", "-loglevel", "error", "-i", video_only, "-i", bed]
    af, mixes = [], []
    for k, (_, _, st) in enumerate(flat):
        ins += ["-i", clips[st["id"]]]
        off = int((TITLE_S + starts[st["id"]]["start"] + 0.35) * 1000)
        af.append(f"[{k + 2}:a]aformat=sample_rates=48000:channel_layouts=stereo,adelay={off}|{off}[n{k}]")
        mixes.append(f"[n{k}]")
    af.append(f"{''.join(mixes)}amix=inputs={len(mixes)}:normalize=0:dropout_transition=0,loudnorm=I=-16:TP=-1.5:LRA=11[voice]")
    af.append(f"[1:a]atrim=0:{full:.2f},volume='if(lt(t,{TITLE_S}),0.9,if(gt(t,{TITLE_S + total:.2f}),0.9,0.22))':eval=frame,"
              f"afade=t=in:st=0:d=1.5,afade=t=out:st={full - 3:.2f}:d=3[music]")
    af.append("[voice][music]amix=inputs=2:normalize=0:duration=longest,alimiter=limit=0.95[a]")
    ins += ["-filter_complex", ";".join(af), "-map", "0:v", "-map", "[a]", "-t", f"{full:.2f}",
            "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-movflags", "+faststart", out_path]
    run(ins)
    log(f"wrote {out_path} ({full:.0f} s)")
    return full
