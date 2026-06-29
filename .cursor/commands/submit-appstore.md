---
name: submit-appstore
description: Build the macOS App Store variant, export a signed .pkg, upload it to App Store Connect, attach it to the version, set What's New, and (after confirmation) submit for review — replacing the manual Xcode Archive → Distribute → Review clicks. Use when the user asks to submit, upload, or ship the app to the Mac App Store.
---

# Submit to App Store (macOS)

Automates the Mac App Store submission that is otherwise done by hand in Xcode
(**Product → Archive → Distribute → App Store Connect → Upload → Submit for Review**),
using the `asc` CLI. This is **separate** from `/release`, which only bumps the
version and tags a GitHub release (CI builds the notarized Developer-ID DMG, **not**
the App Store build).

**Order: `/release` first, then `/submit-appstore`.** A given version ships the *same
code* on both channels, so the GitHub release (version bump, tests, tag, notarized DMG)
must already exist before you submit that version to the App Store. This command does
**not** bump the version, run tests, or create a tag — it only ships the App-Store build
for a version that `/release` has already cut. If the matching tag is missing, it stops
and tells you to run `/release` first.

> **macOS, not iOS — do NOT use `asc publish appstore`.** That command's local-build
> mode assumes an **`.ipa`** and fails for this macOS app with
> `export did not produce an .ipa file` (and even forces `CURRENT_PROJECT_VERSION=1`).
> macOS App Store builds are **`.pkg`** packages. This command therefore exports the
> `.pkg` itself and uploads it with `asc builds upload --pkg`, then submits with
> `asc review submit`.

App constants (App Store Connect ID `6749648401`, bundle `com.magnusgoedde.whispershortcut`,
team `Z59J7V26UT`) and the full `asc` reference live in the parent `app-store-connect`
skill — read its "Submit a version for review" section first.

## Preconditions

1. `asc auth status` shows credentials (API key). If not, point the user to the
   `app-store-connect` skill Prerequisites.
2. Scheme **`WhisperShortcut-AppStore`** exists (Automatic signing, team `Z59J7V26UT`).
3. **Matching GitHub release exists.** The version being submitted must already have a git
   tag `v<X.XX>` and GitHub release, cut by `/release`. Run `/release` **first**; this
   command never bumps or tags.
4. **App Store ExportOptions.plist** at `.asc/export-options-app-store.plist` (the dir is
   gitignored). If missing, create it (Automatic signing auto-provisions the
   *3rd Party Mac Developer Installer* cert during export):
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PList 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>method</key><string>app-store-connect</string>
       <key>teamID</key><string>Z59J7V26UT</string>
       <key>signingStyle</key><string>automatic</string>
       <key>uploadSymbols</key><true/>
   </dict>
   </plist>
   ```

## Steps

1. **Resolve version + build number** from `WhisperShortcut/Info.plist`:
   ```bash
   VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' WhisperShortcut/Info.plist)
   BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' WhisperShortcut/Info.plist)
   ```
2. **Verify the matching GitHub release/tag exists** (`/release` must have already run):
   ```bash
   git fetch --tags --quiet && git tag --list "v$VERSION"
   ```
   If `v$VERSION` is **not** listed, **stop** and tell the user to run `/release` first.
3. **Archive** the App Store scheme (the project's `CFBundleVersion` is authoritative for
   the build number):
   ```bash
   xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut-AppStore \
     -configuration Release -destination 'generic/platform=macOS' -allowProvisioningUpdates \
     archive -archivePath ".asc/artifacts/WhisperShortcut-AppStore-$VERSION.xcarchive"
   ```
4. **Export a signed `.pkg`** from the archive:
   ```bash
   rm -rf .asc/artifacts/export-appstore
   xcodebuild -exportArchive \
     -archivePath ".asc/artifacts/WhisperShortcut-AppStore-$VERSION.xcarchive" \
     -exportPath .asc/artifacts/export-appstore \
     -exportOptionsPlist .asc/export-options-app-store.plist -allowProvisioningUpdates
   ```
   Confirm the chain shows `3rd Party Mac Developer Installer`:
   `pkgutil --check-signature .asc/artifacts/export-appstore/WhisperShortcut.pkg`.
   If export fails with a missing installer identity, do one manual
   **Distribute → App Store Connect** from Xcode once (installs the cert), then re-run.
5. **Upload + wait for processing** (`.pkg` needs explicit `--version`/`--build-number`):
   ```bash
   asc builds upload --app 6749648401 --pkg .asc/artifacts/export-appstore/WhisperShortcut.pkg \
     --version "$VERSION" --build-number "$BUILD" --wait
   ```
   Note the returned build ID and confirm `processingState` is `VALID`
   (`asc builds info --build-id "<BUILD_ID>"`).
6. **Create the App Store version + attach the build.** Copy metadata from the previous
   live version (ask the user which version is live if unsure — see `/release` baseline
   notes), then attach:
   ```bash
   asc versions create --app 6749648401 --platform MAC_OS --version "$VERSION" \
     --copy-metadata-from "<PREV_LIVE>" \
     --copy-fields "description,keywords,marketingUrl,promotionalText,supportUrl,whatsNew"
   asc versions attach-build --version-id "<VERSION_ID>" --build "<BUILD_ID>"
   ```
   (If the version already exists in an editable state, skip `create` and just attach.)
7. **Set What's New for every active localization** — copied metadata still has the *old*
   version's notes, so overwrite each locale (en-US, de-DE, it, es-ES, pt-BR, fr-FR, ru,
   zh-Hant, ja, ko) with the new release's localized notes:
   ```bash
   asc localizations update --version "<VERSION_ID>" --locale "de-DE" --whats-new "..."
   ```
8. **Validate readiness** (non-mutating; expect 0 blocking errors):
   ```bash
   asc validate --app 6749648401 --platform MAC_OS --version "$VERSION" --output table
   ```
   A non-blocking `privacy.publish_state.unverified` info is normal (the public API can't
   confirm App Privacy; it is already published).
9. **Submit for review** — only after the user explicitly confirms (export compliance is
   pre-declared via `ITSAppUsesNonExemptEncryption=false`):
   ```bash
   asc review submit --app 6749648401 --platform MAC_OS \
     --version-id "<VERSION_ID>" --build "<BUILD_ID>" --confirm
   ```
10. **Report**: version, build number, version state, and review state
    (`asc review status --app 6749648401`). Release is manual after approval (default).

## Signing notes

- Both targets use **Automatic** signing; `xcodebuild ... -allowProvisioningUpdates`
  fetches the App Store provisioning profile and, on first export, auto-provisions the
  **3rd Party Mac Developer Installer** cert needed to sign the `.pkg`. This cert is
  distinct from the Developer-ID cert CI uses for the notarized DMG.
- `security find-identity -v -p codesigning` lists the *Apple Distribution* code-signing
  cert; the installer cert is verified via `pkgutil --check-signature` on the exported
  `.pkg`, not via `find-identity`.

## Critical rules

- **Run `/release` first.** Requires an existing `v<X.XX>` tag/GitHub release; never bumps,
  tests, or tags.
- **macOS = `.pkg`.** Never use `asc publish appstore` for this app — it expects an `.ipa`.
  Use the `xcodebuild` export + `asc builds upload --pkg` + `asc review submit` path above.
- **Ask before `asc review submit --confirm`** — it sends the build to Apple review.
- Do not run this to ship a GitHub release — that is `/release`.
