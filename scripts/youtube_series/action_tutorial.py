#!/usr/bin/env python3
"""Record, compose and write metadata for one CAD-action tutorial — every
step a real, visible touch (ActionTakeUITests), narrated one step at a time.

    action_tutorial.py fillet|chamfer|extrude|revolve|sweep|loft|twist|shell|pattern|mirror
        [--take-only | --compose-only | --thumb-only]

Scripts (chapters of steps) are in action_text.py, the touch sequences in
actions.py. Output: marketing/youtube/openshape3d-how-to-<slug>.mp4 with its
-metadata.md and -thumbnail.png.
"""
import argparse, os, sys, urllib.request
from common import *
import action_compose
from action_text import VIDEOS
from actions import BUILDERS, A
from project_tutorial import thumbnail

OUT = os.environ.get("OS3D_VIDEO_OUT", OUT_DIR)


def hero_shot(path, w=1600, h=1200):
    urllib.request.urlretrieve(f"{BASE}/v1/screenshot?w={w}&h={h}&format=png", path)


def make_take(name, take_dir):
    def take(t):
        tl = t.tl
        a = A(t)
        for sid in BUILDERS[name](a):
            if tl.cur:
                tl.hold(0.25)
            tl.begin(sid)
        tl.hold(0.8)
        hero_shot(os.path.join(take_dir, "hero.png"))
    return take


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("video", choices=list(VIDEOS))
    ap.add_argument("--compose-only", action="store_true")
    ap.add_argument("--take-only", action="store_true")
    ap.add_argument("--thumb-only", action="store_true")
    a = ap.parse_args()
    v = VIDEOS[a.video]
    take_dir = os.path.join(S, "take-action-" + a.video)
    os.makedirs(take_dir, exist_ok=True)
    segs = action_compose.segments(v)
    stem = os.path.join(OUT, f"openshape3d-how-to-{v['slug']}")
    if a.thumb_only:
        thumbnail(v, os.path.join(take_dir, "hero.png"), stem + "-thumbnail.png")
        sys.exit(0)
    if not a.compose_only:
        run_take("action-" + a.video, segs, make_take(a.video, take_dir), take_dir, test="ActionTakeUITests")
    if not a.take_only:
        synthesize("action-" + a.video, segs)
        clips = {s["id"]: s["_clip"] for s in segs}
        os.makedirs(OUT, exist_ok=True)
        hero = os.path.join(take_dir, "hero.png")
        v = dict(v, hero=hero if os.path.exists(hero) else None)
        action_compose.compose(v, take_dir, stem + ".mp4", clips)
        write_metadata(stem + "-metadata.md", v, segs, take_dir)
        if v.get("hero"):
            thumbnail(v, v["hero"], stem + "-thumbnail.png")
