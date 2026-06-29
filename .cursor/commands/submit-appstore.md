---
name: submit-appstore
description: Build the App Store variant, upload to App Store Connect, attach the build to the version, and (after confirmation) submit for review — replacing the manual Xcode Archive → Distribute → Review clicks. Use when the user asks to submit, upload, or ship the app to the Mac App Store.
---

# Submit to App Store

Automates the Mac App Store submission that is otherwise done by hand in Xcode
(**Product → Archive → Distribute → App Store Connect → Upload → Submit for Review**),
using the `asc` CLI. This is **separate** from `/release`, which only bumps the
version and tags a GitHub release (CI builds the notarized Developer-ID DMG, **not**
the App Store build).

App constants (App Store Connect ID `6749648401`, bundle `com.magnusgoedde.whispershortcut`,
team `Z59J7V26UT`) and the full `asc` submission reference live in the parent
`app-store-connect` skill — read its "Submit a version for review" section first.

## Preconditions

1. `asc auth status` shows credentials (API key). If not, point the user to the
   `app-store-connect` skill Prerequisites.
2. Scheme **`WhisperShortcut-AppStore`** exists (Automatic signing, team `Z59J7V26UT`).
3. **What's New is set for every active localization** on the target version — App Store
   Connect blocks submission otherwise. Verify with
   `asc localizations list --version "VERSION_UUID"`; fill gaps with
   `asc localizations update --version "VERSION_UUID" --locale "<loc>" --whats-new "..."`.

## Steps

1. **Resolve version**: read `CFBundleShortVersionString` from `WhisperShortcut/Info.plist`.
   Confirm it matches the App Store version the user intends to submit.
2. **Validate readiness** (non-mutating):
   ```bash
   asc validate --app 6749648401 --platform MAC_OS
   ```
   Fix any blockers it reports (missing What's New, screenshots, age rating, encryption)
   before continuing.
3. **Dry run** — preview the build + upload + submit plan without mutating anything:
   ```bash
   asc publish appstore --app 6749648401 --platform MAC_OS \
     --workspace WhisperShortcut.xcodeproj --scheme WhisperShortcut-AppStore \
     --version "X.XX" --submit --dry-run
   ```
4. **Upload + attach** (no review submission yet). `asc` archives the App Store scheme,
   exports it, uploads, waits for Apple to finish processing, then attaches the build to
   the version:
   ```bash
   asc publish appstore --app 6749648401 --platform MAC_OS \
     --workspace WhisperShortcut.xcodeproj --scheme WhisperShortcut-AppStore \
     --version "X.XX" --wait
   ```
5. **Submit for review** — only after the user explicitly confirms (export compliance,
   final check):
   ```bash
   asc publish appstore --app 6749648401 --platform MAC_OS --version "X.XX" --submit --confirm
   ```
6. **Report**: version, build number, processing/attach result, and submission state
   (`asc status --app 6749648401` for the pipeline dashboard).

## Signing notes

- Both targets use **Automatic** signing; `asc` runs `xcodebuild` with provisioning
  updates allowed, so the App Store provisioning profile is fetched on demand.
- App Store upload needs a **Mac Installer Distribution** identity to sign the `.pkg`.
  If it is absent from the Keychain, Automatic signing usually provisions it on the
  first archive — but if export fails with a missing installer identity, the one-time fix
  is to run a single **Distribute → App Store Connect** from Xcode (which installs the
  cert), then re-run this command. This cert is distinct from the Developer-ID cert CI
  uses for the notarized DMG.

## Critical rules

- **Ask before `--submit --confirm`** — it sends the build to Apple review.
- Do not run this to ship a GitHub release — that is `/release`.
