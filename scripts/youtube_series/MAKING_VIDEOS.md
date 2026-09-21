# How to make tutorial videos and Shorts, and upload them

A playbook for doing this on another project. The worked example is
openshape3d (an iOS/iPadOS CAD app) — `scripts/youtube_series/` here is the
reference implementation — but the method transfers to any app you can drive
and record.

What it produces: narrated long-form tutorials (landscape, 2–5 min) and
vertical Shorts (under a minute), where **every step is a real action in the
real app**, filmed as it happens, with a marker wherever the user touched or
clicked.

---

## 1. The rules that make the videos good

1. **Every step is a real UI action.** Never build the demo through an API and
   film the result. Viewers spot it, and the video stops matching the app.
2. **The app's state is read ONLY to check.** After each step, ask the app what
   happened (did the tool arm, did the body appear, did the volume drop) — and
   never to shortcut a step.
3. **A step that does not land stops the take.** No fallbacks. A silent skip
   produces a video that teaches something impossible.
4. **Narration drives pacing.** Each step gets its own narration clip; the step
   holds until its line is done (long-form) or is sped up to fit it (Shorts).
5. **Review every take frame by frame before publishing.** A contact sheet (a
   frame every 1.5–2 s) catches the camera sitting too close, a caption over a
   dialog, a broken model — all of which happened here.
6. **Re-record rather than patch.** Takes are cheap (2–5 min); a bad step
   filmed once is wrong forever.

## 2. The five pieces

| Piece | Here | What it does |
|---|---|---|
| Action runner | `ActionTakeUITests.swift` | Performs UI actions on command AND reports each one before it lands |
| Session host | `common.py` (`Control`, `Recorder`, `Timeline`, `run_take`) | Starts the runner, starts the recording, sends the steps, records what happened when |
| Script | `action_text.py`, `shorts_text.py` | Per video: ordered steps of `(id, caption, narration)` |
| Builder | `actions.py`, `shorts_actions.py` | Per video: the actual sequence of actions, with a check after each |
| Compose | `action_compose.py`, `shorts.py` | ffmpeg: layout, captions, touch rings, speed, music, cards, metadata |

**The one idea worth copying:** the runner posts `vis:tap:x,y` (window-
normalised) *before* each action, the host timestamps it, and compose draws a
ring at exactly that place and time. That is what makes "every tap shown" true
rather than a claim.

### Adapting to another stack

- **iOS / iPadOS:** XCUITest driven over HTTP (what we do), `simctl io … recordVideo` for the picture.
- **Mac app:** the same XCUITest pattern, or accessibility APIs; `screencapture`/AVFoundation to record.
- **Web app:** Playwright or the Chrome tools — the browser already reports coordinates; record with Playwright video or a screen recorder.
- **Android:** Espresso/UIAutomator + `adb shell screenrecord`.

The only hard requirements: drive the UI programmatically, know where each
action landed on screen, record the screen, and (strongly preferred) read the
app's state to verify.

## 3. Setting up a new project

1. **Pick the subjects from what people search for.** We listed the most-viewed
   tutorials for the domain and covered the same ground. Ten is a good series.
2. **Give the videos their own device.** A dedicated simulator/profile/browser
   profile (`os3d-shorts`, `os3d-video`) with its own ports, so other work
   cannot steal it mid-take. Clean the status bar (`simctl status_bar override`
   for 9:41 and full battery).
3. **Add the verification channel** if the app has none: a read-only,
   debug-only endpoint for state, plus a world→screen projection if the app is
   graphical. This is what lets a builder say "tap the top face" instead of
   hard-coding pixels.
4. **Probe the UI by hand first.** `shorts_probe.py` starts the runner and
   serves a port: one action per `curl`, a screenshot whenever you want. An
   hour here saves a day of failed takes — it is how we learned which taps the
   phone's plane-picker steals.
5. **Write the script and the builder together**, sharing step ids. A mismatch
   desyncs narration from picture.
6. **Record, review the contact sheet, fix, re-record.** Expect roughly a third
   of first takes to fail on a missed tap.
7. **Compose, then check the output**: duration, that the audio track is as
   long as the picture, loudness near −14 LUFS, and the file under ~100 MB.

## 4. Long-form tutorials

- **Shape:** title card with the finished thing → chapters of steps → outro.
- **Layout:** the app on the left (1440 px of 1920), a panel on the right with
  the chapter's steps marked done / current / next, a caption pill over the app
  saying what to tap, and the touch rings.
- **Pacing:** each step holds until its narration finishes plus a beat.
- **Metadata:** title, description with chapter timestamps, tags, and a
  thumbnail rendered from the finished model. Write them from the same script,
  so they can never drift from the video. **Check the metadata file is not
  empty** — one of ours was, and that video went up untitled.

## 5. Shorts

- **Shape:** hook (the finished thing turning, under "How do you model
  this?") → every step → the thing again → end card. 30–60 s.
- **Vertical framing:** record the phone upright, crop the status bar and home
  indicator, fit the rest to 1920 high, and put the leftover width behind it as
  a blurred, darkened copy of itself.
- **Speed ramp instead of cuts:** each step plays at the speed that fits its
  narration (≤ 3×; silent steps up to ~5×), raising the caps until the whole
  Short fits the target length. Nothing is skipped — it just moves fast.
- **Captions:** big, white, heavy stroke. Place each one in whichever band (top
  or lower) has less UI under it in that shot and no touch in it. Keep them out
  of the bottom ~15 % and right ~12 %, where YouTube draws its own UI.
- **The hook is free:** film a slow orbit of the finished part at the end of
  the take, then reuse it, zoomed on the part, as the opening.
- Shorts get no custom thumbnail from Studio; YouTube picks a frame.

## 6. Narration

- Neural TTS (`edge-tts`, voice `en-US-AndrewMultilingualNeural`, −3 % for
  long-form, +6 % for Shorts), cached by text so re-composing is instant.
- **A pronunciation guide is essential.** The voice guesses at jargon; respell
  the terms just before synthesis (`pronunciation.py`: CAD is one syllable
  /kæd/, fillet is FILL-it). Write numbers and units as words.
- **Trim the silence.** edge-tts pads ~0.4 s at each end; untrimmed, a
  one-word step holds the picture for two seconds.
- Music: a quiet bed under everything, ~0.25–0.3 gain, fading out at the end.
  Normalise the final mix (−14 LUFS for Shorts).

## 7. Uploading (YouTube Studio, through the browser)

The full route, with the helper script, is in the "YouTube Studio upload"
memory note; the short version:

1. **Pick the browser deliberately.** Several Chrome extensions may be
   connected, and one may be on another computer. Send a Connect prompt and let
   the user choose.
2. **Chunk the file.** The upload tool caps at 10 MB per call: `split -b
   9000000`, push the chunks into an injected `<input type=file>` one per call,
   join them into a `File` in the page, check the SHA-256 against the local
   file, then set Studio's `input[name=Filedata]` and fire `change`.
3. **Open the dialog** from the header's **Create ▸ Upload videos**.
4. **Type the title and description with real keystrokes** — script-set text
   does not register. Click the box, confirm the caret, `cmd+a`, type.
5. **Verify before publishing**: title, description length, thumbnail present,
   tag count, the radio buttons (not made for kids, AI use "No").
6. **Publish**: three "Next" clicks, the Public radio, "Done", then read back
   the link.
7. **Limits:** roughly 9–10 uploads and ~8 custom thumbnails a day until the
   channel has YouTube's Advanced features (video/ID verification) — get that
   first if a series runs to more than a handful of videos. When the cap hits,
   the form silently refuses the title and description while tags still go in
   — always re-check. A capped attempt closes without leaving a draft.
8. **Let the content checks finish before publishing.** If they are still
   running, Studio warns that publishing now risks a strike; wait for "Checks
   complete. No issues found" (a few minutes) rather than "Publish anyway".
   Watch the real dialog too — a link in the page is not proof it published.
8. **Conventions worth keeping:** first line of every description is the app's
   store link; a consistent title pattern; the series number in the
   description; hashtags at the end.

## 8. Checklist per video

- [ ] Script and builder share the same step ids
- [ ] Take ran with no missed step
- [ ] Contact sheet reviewed: framing, captions, the model itself
- [ ] Duration sensible (Shorts < 60 s)
- [ ] Audio as long as the picture; loudness ≈ −14 LUFS
- [ ] Metadata file written and not empty; title, description, tags, thumbnail
- [ ] Published Public, link recorded

## 9. What it costs

A ten-video series is about a day: an hour of probing, an hour writing scripts
and builders, 3–5 min per take (plus re-records — budget 1.5 takes per video),
about a minute to compose each, and roughly 3 minutes per upload. The pipeline
is reusable afterwards: a new video in an existing series is a builder plus a
script entry.
