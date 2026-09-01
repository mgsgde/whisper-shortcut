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
   the build number). `-skipPackagePluginValidation` is required since MLX joined the graph:
   `mlx-swift` ships a Linux-only CudaBuild plugin that no-ops on macOS, and Xcode refuses an
   unvalidated plugin rather than ignoring it. `rebuild-and-restart.sh`, `run-tests.sh` and
   `release.yml` all pass the same flag — this command must not be the one that forgets it:
   ```bash
   xcodebuild -project WhisperShortcut.xcodeproj -scheme WhisperShortcut-AppStore \
     -configuration Release -destination 'generic/platform=macOS' -allowProvisioningUpdates \
     -skipPackagePluginValidation \
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
6. **Create the App Store version + attach the build.** Resolve `<PREV_LIVE>` by following
   **Resolve the live App Store baseline** in the `app-store-connect` skill — query it, do not
   ask the user. Then copy that version's metadata forward and attach the build:
   ```bash
   asc versions create --app 6749648401 --platform MAC_OS --version "$VERSION" \
     --copy-metadata-from "<PREV_LIVE>" \
     --copy-fields "description,keywords,marketingUrl,promotionalText,supportUrl,whatsNew"
   asc versions attach-build --version-id "<VERSION_ID>" --build "<BUILD_ID>"
   ```
   (If the version already exists in an editable state, skip `create` and just attach.)
7. **Set What's New for every active localization.** Copied metadata still carries the *old*
   version's notes, so every configured locale needs the new text or App Store Connect blocks
   the submission with "This field is required".

   **Query the locale set — never assume it.** It is 10 today, but that is a fact about the
   store, not about this document:
   ```bash
   asc localizations list --version "<VERSION_ID>" --output table
   ```

   The working artifact is a directory of `.strings` files, one per locale — the format
   `asc localizations download` / `upload` speak. Previous releases are kept alongside at
   `.asc/whatsnew-<version>/` (gitignored); read one for tone and length before writing new ones.

   ```bash
   DIR=".asc/whatsnew-$VERSION"
   asc localizations download --version "<VERSION_ID>" --path "$DIR"        # current state
   cp -R "$DIR" "$DIR.orig"                                                 # pristine reference
   # …edit only the whatsNew value in each .strings file…
   diff -r "$DIR.orig" "$DIR"                                               # THE guard — see below
   asc localizations upload --version "<VERSION_ID>" --path "$DIR" --dry-run
   asc localizations upload --version "<VERSION_ID>" --path "$DIR"
   ```

   > **`upload` pushes every field in the file, not just `whatsNew`.** A `.strings` file also
   > carries `description`, `keywords`, `marketingUrl`, `promotionalText` and `supportUrl`, and
   > `upload` rewrites all six for every locale in the directory. Always `download` first and
   > change *only* the `whatsNew` line.
   >
   > **`--dry-run` is not a diff.** Verified against the live API: it reports which localizations
   > would be written (`"action":"update"` for every locale in the directory) and returns the
   > *same* output whether you edited a field or not. It proves the files parse and the locale
   > set is right — nothing more. The `diff -r` against the pristine copy is what actually tells
   > you which fields you are about to change, so do not skip it.

   For a single locale, `asc localizations update --version "<VERSION_ID>" --locale "de-DE"
   --whats-new "..."` still works and touches nothing else.

   **While the directory is in hand, check the carried-over fields agree across locales.** Step 6
   copies them forward from the previous live version, so any inconsistency is inherited silently
   and then **freezes** — once the version is `READY_FOR_SALE` Apple rejects edits to these fields
   with `Attribute 'supportUrl' cannot be edited at this time`. An editable version is the *only*
   chance to fix them:
   ```bash
   for f in "$DIR"/*.strings; do
     printf '%-10s %s\n' "$(basename "$f" .strings)" "$(grep -o '"supportUrl" = "[^"]*"' "$f")"
   done   # repeat for marketingUrl; all locales should match unless a locale-specific URL is intended
   ```
   History: 7.99 shipped with `supportUrl` set to `https://whispershortcut.com/support` for **en-US
   only** — the other nine carried `https://github.com/mgsgde/whisper-shortcut/issues`, and by the
   time it was noticed 7.99 was live and frozen. Corrected on the 8.00 version (all ten locales
   agree); it reaches users when 8.00 ships. `marketingUrl` was already consistent.

   **Where the localized text comes from:** `/release` produces the App Store "What's New" in
   **English only**. Translating it into the remaining locales is part of *this* command — keep
   each translation as short as the English, and do not translate feature names that ship in
   English in the UI (Dictate Prompt, Read Aloud, Live Meeting, Smart Improvement).
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
    (`asc review status --app 6749648401`). Do **not** claim from memory whether release is
    manual or automatic — read the version's `releaseType` from `asc versions list`.
    This app has historically used `AFTER_APPROVAL` (goes live automatically once Apple
    approves, no manual step); `MANUAL` would mean the user must release it.

## Signing notes

This command is the **single owner** of the packaging and signing rules below. `/release` and the
`app-store-connect` skill link here rather than restating them — keep it that way.

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
- **macOS = `.pkg`, never `asc publish appstore`** — see the note under the title for why, and
  Steps 4–5 for the `xcodebuild` export + `asc builds upload --pkg` path that replaces it.
- **Ask before `asc review submit --confirm`** — it sends the build to Apple review.
- Do not run this to ship a GitHub release — that is `/release`.
