# Auto-update for the direct (GitHub) build — Sparkle 2

Status: in progress (2026-10-15), branch `feat/sparkle-auto-update`.

## Why

Martin (IT contractor for the osteopathy pilot practice, offline rollout from 2026-10-15) asked
for an auto-update: v8.35–v8.39 shipped in six days, and copying DMGs by hand to each Mac does not
scale. The 2026-10-09 decision ("Magnus installs tested batches by hand") stays true in spirit:
**nothing installs without a click**. Sparkle shows a notice with the release notes and an
"Install Update" button; the practice decides when.

## Decisions

| Question | Decision | Why |
|---|---|---|
| Updater | Sparkle 2 (SPM, `upToNextMajor` from 2.9.6), **direct target only** | The App Store target never links it; all code behind `#if !APP_STORE && canImport(Sparkle)`. |
| Silent install | Never. `SUAllowsAutomaticUpdates = NO` (hides Sparkle's "install automatically" box), `automaticallyDownloadsUpdates = false` | Practice must not change unannounced. |
| Automatic check default | On, daily (`SUEnableAutomaticChecks = YES`, `SUScheduledCheckInterval = 86400`) — toggle in Settings → About | A check only shows a notice; no first-launch permission prompt in the practice. |
| Feed URL | `https://github.com/mgsgde/whisper-shortcut/releases/latest/download/appcast.xml` | Stable URL that always points at the newest non-prerelease asset; no extra hosting. Single-item appcast. |
| Where the appcast is built and signed | `.github/workflows/release.yml` (via `scripts/make-appcast.py`), **not** `scripts/create-release.sh` | `create-release.sh` only pushes a tag; the DMG is built, notarised and published in CI, so the EdDSA signature has to be made there over the final stapled DMG. |
| Enclosure | The notarised, stapled DMG already published | Sparkle installs from DMGs; no second artefact. |
| Signing key | EdDSA, generated 2026-10-15 in Magnus's login keychain (account `whispershortcut`), backup at `~/.config/whispershortcut-sparkle/ed25519-private.key` (600). CI secret `SPARKLE_ED_PRIVATE_KEY`. Public key in build setting `SPARKLE_PUBLIC_ED_KEY` (direct target only) → `SUPublicEDKey`. | Losing the private key means existing installs can never update again — keep the backup. |
| Missing CI secret | Release still publishes, appcast step warns and skips | A missing secret must not block a release. |
| Offline Mode | Update check **allowed**, labelled in Settings → About and in the Offline Mode bullets | Sparkle uses its own `URLSession`, which never carries `OfflineModeURLProtocol`. It fetches one XML file from github.com and sends only the app name/version in the User-Agent; system profiling stays off. |
| Old About-tab GitHub API check (`WhatsNewSection.checkGitHubLatest`) | Removed for the direct build — Sparkle replaces it | It went through the guarded session, so it was silently blocked in Offline Mode; two update mechanisms would disagree. |
| Sandbox | `SUEnableInstallerLauncherService = YES`; mach-lookup exceptions `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` / `-spki` in `WhisperShortcut.entitlements` | Required for Sparkle 2 in a sandboxed app. Network client entitlement already present, so no downloader XPC. |
| Menu-bar (LSUIElement) app | `supportsGentleScheduledUpdateReminders = true`; Sparkle shows its own window, brought to front on scheduled finds | Without it Sparkle logs a warning and the alert can sit behind other apps. |

## Test (done = all true)

- `bash scripts/rebuild-and-restart.sh` and `bash scripts/rebuild-and-restart.sh --app-store` both exit 0.
- `nm`/`otool -L` of the App Store binary shows no Sparkle.
- Local appcast on `http://localhost` (DEBUG-only feed override `SparkleFeedURLOverride`)
  drives an update from build N-1 to build N: notice with notes → Install → relaunch on N.
- README `## Features` mentions update notices.

## Not in scope

Delta updates, beta channel, menu-bar "Check for Updates…" item.
