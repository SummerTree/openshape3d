# YouTube video TODO — where we left off

Last updated: 2026-09-20 (after publishing the mirror tutorial and nine Shorts).
Channel: https://studio.youtube.com/channel/UCVXu7hwHDBfO_nC3YCT9eZA (hello@sagharborrum.com).
How the pipeline works: `README.md` in this folder. How uploading works: the
"YouTube Studio upload" memory note, plus **Upload route** below.

## Open items

1. **Upload Short #10, the ring.** Everything else is done; it was refused with
   "Daily upload limit reached" on the 11th upload of 2026-09-20. The cap
   resets 24 h later. Nothing was left behind in Drafts.
   - File: `marketing/youtube/shorts/openshape3d-short-10-ring.mp4` (46 s, 12 MB)
   - Text: `…-10-ring-metadata.md` (title, description, tags)
   - Title: `How do you model a ring? | CAD on iPhone #shorts`
2. **Delete the stray draft "openshape3d how to chamfer"** (Studio ▸ Content ▸
   Drafts). It is a twin of the published chamfer tutorial, left from a failed
   first upload. Jason has to delete it — Claude does not delete published or
   stored content.
3. **Optional: lift the daily caps.** Studio ▸ Settings ▸ Channel ▸ Feature
   eligibility ▸ Advanced features needs video verification, a valid ID, or
   channel history. Until then: ~9–10 uploads a day, ~8 custom thumbnails a
   day. Phone verification (done) only buys custom thumbnails.
4. **Branch `feat/youtube-shorts` is not pushed and has no PR.** It sits on top
   of `feat/youtube-cad-actions` (also unpushed, commit f7ad4fa). Both only add
   `scripts/youtube_series/*` and the take test; no app code. Ask before
   pushing.
5. **Shorts have no custom thumbnails.** Studio's upload dialog offers none for
   vertical videos; YouTube picks a frame. Setting one needs the mobile app.

## What is published

- **Ten "CAD basics — every tap shown" tutorials** (2–4 min, landscape iPad):
  fillet, chamfer, extrude & cut, revolve, sweep, loft, twist, shell, pattern,
  mirror. All Public with descriptions, chapters, tags and custom thumbnails.
  Mirror went up 2026-09-20: https://youtu.be/iTM-gmAoxrg
- **Nine of ten "How do you model this?" Shorts** (33–57 s, upright iPhone):
  1 spring VQgb-9BGZQ0 · 2 twisted vase eN47Sfq4z8A · 3 donut h2S-oBk-HQk ·
  4 bowl r4rD59uk3Nw · 5 hex nut zEhpWnHFIYw · 6 square-to-round h-7_fKS_9rk ·
  7 bent pipe I8v6Yw6ukH4 · 8 gem FRZQn6MRxUA · 9 cube frame fP8600CmvsA
  (all `https://youtube.com/shorts/<id>`). **#10 ring is the one still to go.**
- Earlier: three tutorials (sketching, shapes, materials), ten project
  tutorials (mug, chess, LEGO brick, keychain, vase, bolt & nut, gear, fidget
  spinner, ice cube tray, hinged box), the AI/flowerpot video.

## Where things are

| What | Where |
|---|---|
| Finished videos + metadata | main checkout `marketing/youtube/` and `…/shorts/` (gitignored) |
| Raw takes (raw.mp4, timeline.json) | `scripts/youtube_series/take-*/` (gitignored) |
| Narration cache | `scripts/youtube_series/tts/` (gitignored) |
| Pipeline code | `scripts/youtube_series/` — `shorts.py`, `shorts_actions.py`, `shorts_text.py`, `action_tutorial.py`, `actions.py`, `action_text.py`, `common.py` |
| Simulators | `os3d-shorts` (iPhone 17 Pro Max, bridge 8933 / control 8932), `os3d-video` (iPad, 8931 / 8930) |

## Redo or extend

```bash
cd scripts/youtube_series
python3 shorts.py ring                 # re-record + compose one Short
python3 shorts.py ring --compose-only  # re-cut from the existing take
./batch_shorts.sh gem frame            # several in a row (all ten by default)
python3 shorts_contact.py VIDEO.mp4 sheet.png 1.5   # ALWAYS review before publishing
python3 action_tutorial.py mirror --compose-only    # the long-form tutorials
```

A new Short = a builder in `shorts_actions.py` + an entry in `shorts_text.py`
(same step ids in both) + `BUILDERS`/`SHORTS`. Read "Shorts" in `README.md`
first — it lists the phone-tap traps (plane-picker tiles winning taps near the
origin, taps within ~18 pt of a sketch curve picking the curve, thin regions
needing a pinch-zoom).

## Upload route (short version)

Claude in Chrome, on the browser Jason names — several are connected and one is
on another computer, so call `switch_browser` and let him pick ("mac studio").
`file_upload` caps at 10 MB, so split the mp4 (`split -b 9000000`), push the
chunks into an injected file input, join them in the page, check the SHA-256,
then set Studio's `input[name=Filedata]`. Open the dialog with the header's
**Create ▸ Upload videos** (there is no `#upload-icon` any more). Titles and
descriptions need real keystrokes; verify with `__os3dCheck()` — when the daily
cap is hit the form silently refuses them while tags still go in. Publish with
three `#next-button` clicks, the PUBLIC radio, `#done-button`. Full walkthrough
and the helper script: the "YouTube Studio upload" memory note.

## Ideas, not started

- A second batch of Shorts (thread, knurl, gear, hinge, phone stand, dice).
- Cut 15–30 s teasers of the long tutorials as Shorts pointing at the full video.
- A playlist per series, and channel sections for Tutorials vs Shorts.
- Pinned comment with the App Store link on each video.
