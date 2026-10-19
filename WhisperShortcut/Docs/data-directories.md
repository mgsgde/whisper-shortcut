# WhisperShortcut Data Directories

WhisperShortcut stores user data locally on your Mac. The app intentionally uses one canonical Application Support location so sandboxed and non-sandboxed builds can share the same settings, context files, meeting transcripts, and downloaded models.

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
- Chat/session data and other app support files.

## Why The Path Looks Sandboxed

App Store builds are sandboxed by macOS and naturally resolve Application Support inside the app container. Non-sandboxed development builds explicitly use the same container-style path so switching between build variants does not split user data across two locations.

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
