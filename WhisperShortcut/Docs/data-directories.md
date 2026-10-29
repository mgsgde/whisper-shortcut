# WhisperShortcut Data Directories

WhisperShortcut stores user data locally on your Mac. The app intentionally uses one canonical Application Support location so the App Store build and the direct build share the same settings, context files, meeting transcripts, and downloaded models.

## Canonical Path

```text
~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/
```

This path is used for:

- `UserContext/`: interaction logs, user context, system prompts, prompt history, short-lived Smart Improvement audio verification samples in `UserContext/audio-samples/`, and the Writing Style profile and example messages in `UserContext/writing-style/` (`profile.md`, `samples.jsonl`).
- `Meetings/`: saved live meetings. Each one is up to three files sharing a stem: `<meeting>.txt` (the transcript), `<meeting>.notes.md` (the live notes taken during the meeting), and `<meeting>.summary.md` (the summary written when it ended).
- `MeetingAudio/<meeting>/`: audio of meeting parts that couldn't be transcribed yet (for example recorded offline), one `chunk-<start ms>.wav` per part. Deleted part by part once **Retry Meeting Transcription** gets it into the transcript, and with the meeting when it is discarded.
- `WhisperKit/`: downloaded local Whisper models.
- `telemetry-pending.json`: opt-in anonymous usage statistics not yet sent (counts only). Exists only while "Share anonymous usage statistics" is on; deleted when it is turned off. See `WhisperShortcut/Telemetry/TelemetryService.swift`.
- `feature-usage.json`: local per-feature counts and last-used dates. Never sent. Shown in Settings and reset there. See `WhisperShortcut/Telemetry/FeatureUsageStore.swift`.
- Chat/session data and other app support files.

## Debug build identity (local development only)

A locally built Debug app (`scripts/rebuild-and-restart.sh`) is **WhisperShortcut Dev**, bundle ID `com.magnusgoedde.whispershortcut.dev`, with an orange "DEV" tag next to the menu bar icon. Shipped builds (Developer ID and App Store, both Release) keep `com.magnusgoedde.whispershortcut`. The separate ID gives the dev app its own:

- **TCC entries** (Accessibility, Microphone, Screen Recording). Both apps can be granted at once; switching between them no longer leaves one of them "Denied" with the toggle on.
- **Keychain access group** `Z59J7V26UT.com.magnusgoedde.whispershortcut.dev` (from `$(PRODUCT_BUNDLE_IDENTIFIER)` in `WhisperShortcut.entitlements`). API keys are entered separately in each app.
- **Container** `~/Library/Containers/com.magnusgoedde.whispershortcut.dev/`. It starts empty. `bash scripts/copy-release-data-to-dev.sh` clones the release's settings, context files, history, meetings and models into it once (API keys excluded).

Both bind the same global hotkeys, so `rebuild-and-restart.sh` from the main checkout replaces the running instance. A build from a worktree instead launches as a sidecar (`--sidecar`, badge TEST, no hotkeys, Fn key, MCP server, Sparkle or daily auto-run; it shares the dev container and keychain) next to the user's instance and touches nothing else. `--replace` kills every dev instance. The installed `/Applications` release is never killed by any dev script (`kill_unprotected` in `scripts/lib/daily-app.sh` skips every process whose command line starts with `/Applications/`), and a Dev build started while the release runs makes itself a sidecar (also from Xcode Run, the driver or an in-app relaunch). `scripts/copy-release-data-to-dev.sh` is the one exception: it quits the release on purpose and relaunches it. Also, `scripts/ensure-app-running.sh` relaunches the app bundle recorded as the daily one in `~/Library/Caches/whispershortcut-dev/daily-app`. The direct target's Debug config signs Manually with the profile "WhisperShortcut Dev (Mac Development)", because Xcode has no account signed in and so Automatic signing cannot create a managed profile for the `.dev` App ID. The profile was made with the App Store Connect API and expires 2027-10-20. To renew it: `asc profiles create --name "WhisperShortcut Dev (Mac Development)" --profile-type MAC_APP_DEVELOPMENT --bundle 87DQBSK6QP --certificate <Apple Development cert id> --device <this Mac's device id>`, then save the decoded `profileContent` to `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<uuid>.provisionprofile`. Logging keeps the subsystem `com.magnusgoedde.whispershortcut` in both builds, so `scripts/logs.sh` sees either one.

## Why The Path Looks Sandboxed

Both shipped builds are sandboxed and share one container (see the next section), so this is simply where macOS puts their Application Support. The direct build's Sparkle updater runs in its sandboxed mode (the `-spks`/`-spki` mach-lookup exceptions, `SUEnableInstallerLauncherService`). If the binary is ever started without its sandbox entitlement, `AppSupportPaths` hard-codes the same container path so the data doesn't split.

### Moving the direct build out of the container (evaluated 2026-10-19, not done)

Proposal: point the direct build at `~/Library/Application Support/WhisperShortcut/` so it no longer depends on App Data protection. Rejected as specified, because changing the non-sandboxed branch of `AppSupportPaths` would not affect any shipped build. A sandboxed app cannot keep its data outside its container. Actually moving the data would mean two things:

1. **Taking the sandbox off the direct build.** That needs its own entitlements file, Sparkle's non-sandboxed setup and a hardened-runtime review. The direct build would also lose the sandbox as a safety boundary.
2. **Splitting data.** A Mac with both builds would keep two copies of meetings, prompts, chats and models (about 10 GB with MLX + WhisperKit models), and they would drift apart. UserDefaults would most likely split too: macOS stores preferences inside the container only while the app is sandboxed.

That change needs a product decision (Magnus) before any code is written. Until then, a launch-time check covers the actual failure, an existing but unreadable container (`EPERM`). PR #146 does this for `system-prompts.md`, and the same check can be extended to the container root.

## macOS App Data Protection (Sonoma and later)

Since macOS 14, `~/Library/Containers/<bundle id>/Data` carries a `com.apple.macl` attribute that names the code allowed into it. That is the bundle that owns the container, plus apps signed with the same Team ID. Any other process is either shown the "would like to access data from other apps" prompt or, once that prompt has been denied, gets `EPERM` ("Operation not permitted") on `stat`/`open`. FileManager's `fileExists` then just returns `false`. Checked on macOS 26.6: the container's `Data` folder has `com.apple.macl`, and `.com.apple.containermanagerd.metadata.plist` cannot be read from a Terminal shell.

What that means for the two builds:

Both shipped builds are sandboxed. `WhisperShortcut.entitlements` (direct/GitHub, Developer ID) and `WhisperShortcut-AppStore.entitlements` both set `com.apple.security.app-sandbox`. Both builds use the bundle ID `com.magnusgoedde.whispershortcut` and Team ID `Z59J7V26UT`, so they share one containermanagerd container. The non-sandboxed branch of `AppSupportPaths` does not run in any shipped build.

- **Same team, any channel:** the App Store build and the direct build both pass the MACL check. Installing a newer `.dmg` over an older one with the same signing changes nothing.
- **Signature change between installs:** the container is bound to the code identity of the build that created it. Suppose it was created by a build that was not signed by Team `Z59J7V26UT`, such as an ad-hoc ("Sign to Run Locally") branch build, a re-signed copy, or another team. A later Developer ID build then counts as "another app" to macOS. It gets the "would like to access data from other apps" prompt once. If that prompt was denied or never seen, it gets a silent `EPERM`, even though `system-prompts.md` is still on disk. The reverse case, a team build first and an ad-hoc build afterwards, is blocked the same way.
- **Denied prompt:** the denial is stored in TCC (`kTCCServiceSystemPolicyAppData`), and every later read fails with `EPERM` and no prompt. `tccutil reset SystemPolicyAppData com.magnusgoedde.whispershortcut` followed by a relaunch brings the prompt back; answer Allow. Full Disk Access is the in-app suggestion, but it is not verified to lift an App Data denial for a sandboxed app. If it does not help, use the `tccutil` reset.

Before 2026-10-19 the app treated that `EPERM` as "file missing". It tried to write defaults, `loadSection` returned nil, and dictation ran on the default prompts with nothing on screen to say why. Now `SystemPromptsStore` uses `stat` and tells `ENOENT` (create defaults) apart from every other errno (unreadable). For an unreadable file it:

- logs `SYSTEM-PROMPTS: … exists but cannot be read: EPERM (Operation not permitted)`;
- refuses every write, so the file is never replaced;
- shows an alert at launch and a banner in the prompt editors that point to Full Disk Access.

Creating the file uses `O_EXCL` (`.withoutOverwriting`), so even a misdetected "missing" cannot replace an existing file.

### Prompt backups and launch log

- `UserContext/system-prompts.md.bak`: before any write that changes a section you customized (one that is not a default the app ever shipped), the previous file is copied here. There is one rolling copy. Reverting a mistake: quit the app, copy `.bak` over `system-prompts.md`, and reopen.
- Every launch logs one line per section, `SYSTEM-PROMPTS: section promptMode = custom (1234 chars)`, plus a line for the file itself. The log never contains prompt text. Read it with `bash scripts/logs.sh -t 10m | grep SYSTEM-PROMPTS`.

## Cleaning Or Resetting Data

Prefer the reset and delete actions in Settings when available. For manual cleanup:

1. Quit WhisperShortcut.
2. In Finder, choose Go > Go to Folder.
3. Paste the canonical path above.
4. Delete only the folder you intend to reset, such as `UserContext/` or `Meetings/`.

API keys, Google OAuth refresh tokens, and Trello tokens are stored in macOS Keychain, not in this directory.

Smart Improvement audio samples are only created when **Save usage data** is enabled. They are capped, used as verifier evidence for dictation-related suggestions, and deleted at the start of the next Smart Improvement run or when interaction data is deleted.
