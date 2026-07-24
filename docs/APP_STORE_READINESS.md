# App Store readiness audit

## 0. BLOCKER — no privacy manifest (`PrivacyInfo.xcprivacy`)

The app has **no privacy manifest**, but it uses `UserDefaults` (2 files) — a
"required reason" API. Since spring 2024 Apple requires apps using such APIs to
ship a `PrivacyInfo.xcprivacy` declaring them; uploads without one are flagged or
rejected at App Store Connect.

Minimal manifest to add to the app target:

```xml
<key>NSPrivacyAccessedAPITypes</key>
<array>
  <dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array><string>CA92.1</string></array>   <!-- app's own use -->
  </dict>
</array>
```

Also set `NSPrivacyTracking` = false, and empty `NSPrivacyCollectedDataTypes` /
`NSPrivacyTrackingDomains` (the app collects nothing). Checked and NOT needed:
file timestamps, system uptime, and free-disk-space APIs are unused.

## What has NOT been tested — read before submitting

Everything verified so far was on the **Simulator**. That leaves real gaps:

| Untested | Why it matters |
| --- | --- |
| **Any real device** | The app is a custom **Metal** renderer. Simulator Metal is a different implementation — shader behaviour, precision and performance differ. This is the single biggest untested risk. |
| **`xcodebuild archive` + export** | Archiving is a different path from `build`; it can fail (symbols, entitlements, bitcode settings) where a build succeeds. All builds here used `CODE_SIGNING_ALLOWED=NO`. |
| **Code signing / provisioning** | Never exercised with a distribution cert or profile. |
| **Import / Export** | Headline feature, real file I/O — a prime crash area. Only the menu was opened; no STEP/STL/OBJ/DXF was ever imported or exported. |
| **Apple Pencil** | Implemented but the Simulator cannot test it. |
| **AR Quick Look** | Needs a device. |
| **iOS 17 at runtime** | 17.0 is compile-verified only. An API that compiles but is unavailable at runtime would crash on a real 17.x device. |
| **Performance / memory on a heavy model** | Never profiled. A twist alone can reach ~11k triangles; real models go far beyond. |
| **Persistence across cold launch** | Testing mostly used `OS3D_FRESH`, which starts empty and bypasses existing stored projects and any SwiftData migration path. |


Findings from the pre-submission pass. Ordered by how much they matter for a
1.0 launch. Nothing here blocks the build — the Release/device build succeeds —
these are shipping-configuration issues.

## 1. Deployment target is iOS 26.2 — almost certainly wrong

`IPHONEOS_DEPLOYMENT_TARGET = 26.2`, and the shipped `Info.plist` carries
`MinimumOSVersion = 26.2`. That restricts the app to devices on the newest OS
and excludes essentially the entire installed base. It reads like an inherited
Xcode 26 default rather than a decision.

The realistic floor is set by what the code actually uses:

| Requirement | Minimum iOS |
| --- | --- |
| `@Observable` (Observation) | 17.0 |
| SwiftData (`ModelContainer`, `@Query`) | 17.0 |
| `PhotosPicker` | 16.0 |
| `Task.sleep(for:)` | 16.0 |

**Verified: the project compiles cleanly at both 18.0 and 17.0.** A full Release
build for device (`generic/platform=iOS`, arm64) at
`IPHONEOS_DEPLOYMENT_TARGET=17.0` produced zero errors. iOS 17.0 is the floor —
SwiftData and `@Observable` both require it.

So this is a **one-line change with a verified compile**:

```
IPHONEOS_DEPLOYMENT_TARGET = 17.0
```

Still worth a smoke test on a 17.x simulator before shipping (compiling is not
the same as running — an unavailable-API call guarded only at runtime would slip
through), but the expensive unknown is answered: nothing in the codebase needs
iOS 26. This is the single highest-value fix before launch.

## 2. `CFBundleDisplayName` is missing

The app installs as **"openshape3d"** — lowercase, no spaces. Set a display name
(e.g. "OpenShape 3D") so the home screen and App Store listing read properly.

## 3. No export-compliance declaration

`ITSAppUsesNonExemptEncryption` is absent, so App Store Connect asks the
encryption question on **every** upload. Adding it (almost certainly `false` —
the app ships no custom crypto) removes that friction permanently.

## 4. No document type declarations

The app has its own `.os3d` project format and imports STEP / STL / OBJ / DXF,
but declares no `CFBundleDocumentTypes` or `UTExportedTypeDeclarations`. Today a
user cannot open a `.os3d` file from Files or Mail into the app, and the type
isn't registered to it. Not a blocker; a real UX gap for a CAD app, and it makes
a good listing bullet ("open STEP/STL files straight from Files").

## 5. Debug hooks ship in the release binary

`OS3D_DEBUG_SEED`, `OS3D_DEBUG_SEED_CYLINDER/BOOLEAN/PRIMBOOL/IMAGE`,
`OS3D_FRESH`, `OS3D_AUTO_OPEN` are read via `ProcessInfo.environment` without an
`#if DEBUG` guard, so the seeding code is compiled into the shipping app.

Not exploitable — a user can't set environment variables for an App Store app,
and `OS3D_FRESH` only creates a new empty project (it does not delete data). This
is hygiene, not a security issue. Worth wrapping in `#if DEBUG` so the paths and
their seed assets don't ship.

## 1b. iPhone layout is broken — decide iPhone vs iPad-only

The app declares iPhone support (`UIDeviceFamily = [1, 2]`) but the bottom bars
are unusable at iPhone width. On an iPhone 17 Pro Max:

- **Primitive-dimension bar**: labels truncate to single characters ("E", "c",
  "x"), the bar clips vertically, and the Copy button overlaps it.
  → `marketing/bugs/iphone-primitive-bar-truncated.png`
- **Extrude bar** (much worse): "Extrude", "Offset Plane" and "Cancel" each wrap
  **vertically, one letter per line**; the Extrude button renders as an
  unlabeled blue pill; the bar eats ~40% of the screen; and the tool palette is
  cut off so Material / Select / Delete are unreachable.
  → `marketing/bugs/iphone-extrude-bar-broken.png`

Likely cause: the bars lay out as a single fixed `HStack` sized for iPad width,
so at iPhone width SwiftUI compresses each label to its minimum and wraps
per-character.

Two paths — this is a product decision:

- **(A) Make the bars adaptive** — compact size class gets a scrollable/2-row
  layout, icons instead of words, `lineLimit(1)` + `minimumScaleFactor`, and a
  scrollable tool palette.
- **(B) Ship iPad-only for 1.0** — `TARGETED_DEVICE_FAMILY = 2`. Common for CAD
  apps, removes the entire problem class, and means only iPad screenshots are
  needed.

Reviewers do exercise iPhone layout when an app declares iPhone support, so
shipping as-is on both families invites a rejection.

## 2b. Fillet tears curved solids

Filleting edges of a **twisted** solid produces torn, self-intersecting geometry
rather than a blend or a clean refusal.
→ `marketing/bugs/fillet-on-twisted-solid-broken.png`

Fillet is correct on prismatic edges (verified on a plain box — clean rounded
corner). A twisted solid's corner rails are helical, outside the documented
mesh-fillet v1 envelope; the problem is that it fails **destructively** instead
of detecting the unsupported input and refusing.

## Verified good

- **Release build for device (arm64) succeeds.** Only warning is `sprintf`
  deprecation from OpenCASCADE's own headers (third-party, harmless).
- **OCCT.xcframework has both slices** — `ios-arm64` and `ios-arm64-simulator`
  — so the device archive links.
- **App icon set is complete**, including the 1024×1024 marketing icon.
- **`UIDeviceFamily = [1, 2]`** (iPhone + iPad). The `7` in
  `TARGETED_DEVICE_FAMILY` only applies to a visionOS destination and does not
  leak into the iOS build.
- **No privacy usage strings needed.** `PhotosPicker` and `QLPreviewController`
  (AR Quick Look) both run out-of-process, so neither requires
  `NSPhotoLibraryUsageDescription` nor `NSCameraUsageDescription`.
- **Orientations**: all four on iPad, three on iPhone.
- **746 unit tests pass** (0 failures).

## Automated suite results

| Suite | Result |
| --- | --- |
| `openshape3dTests` (unit) | **746 passed, 0 failed** |
| `openshape3dUITests` | **85 tests / 43 suites, 3 failed** (39 min) |

The three UI failures, each re-run in isolation:

| Test | Isolation | Verdict |
| --- | --- | --- |
| `ItemsUITests.testItemsPanelVisibilityRenameAndDelete` | **passes** | long-run flake |
| `SymbolUITests.testMakeSymbolInsertTwiceAndRenameInItems` | **passes** | long-run flake |
| `FaceFlowUITests.testTypeNegativeIntoArrowPill` | **still fails** | real — see below |

The two flakes share a signature — both assert *"Submitting the field should
rename…"* and both drive a rename text field. That points at keyboard/focus
state leaking between tests in a long run rather than an app defect, but it is
worth stabilising so the suite is trustworthy as a release gate.

`testTypeNegativeIntoArrowPill` is **not** a flake: it fails in the full run AND
in isolation on **iPad Air 13-inch (M3)**, while passing repeatedly on **iPad Pro
13-inch (M5)**. Device-dependent, so either the test hardcodes coordinates that
don't map on the Air, or typing a negative into the pill genuinely fails to
commit an inward push at that geometry. Needs a look before relying on the
suite as a gate — and if it is the latter, it is a user-facing bug.

## Feature walkthrough on iPad — all worked

Driven by hand on an iPad Air 13". Everything below produced correct geometry
and correct measurements:

| Flow | Result |
| --- | --- |
| Sketch on the ground plane (Rect) | ✓ |
| Extrude to a solid, live preview + numeric distance | ✓ Volume 0.93 mm³ |
| Face select → Transform ▸ Rotate → **twist** | ✓ smooth screw walls, top face area preserved |
| Modify ▸ Fillet on a plain box | ✓ clean rounded edge |
| **Sketch on a face** of a filleted solid | ✓ strokes clearly visible, stayed on the face |
| **Pass-through cut** (sketch on face → extrude −5.5 mm, Auto → subtract) | ✓ real opening, interior walls visible |
| X-Ray display mode | ✓ shows the cut passing clean through |
| Display modes menu (Shaded / No Edges / Wireframe / X-Ray / Hidden Edges) | ✓ |
| Parametric History panel | ✓ Extrude node with editable value |

Note: the History panel is **empty for debug-seeded bodies** — the seed adds a
body directly and bypasses the feature graph. That is expected, not a bug; a
real sketch→extrude records a feature node as it should.
