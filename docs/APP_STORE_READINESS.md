# App Store readiness audit

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
- **746 unit tests pass.**
