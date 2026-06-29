---
name: run-whisper-shortcut
description: Build, launch, drive, screenshot, and walk through the WhisperShortcut macOS menu-bar app from a user's perspective. Use when asked to run, start, launch, build, screenshot, test onboarding, cognitive walkthrough, first-run activation, or visually confirm UI changes in the real app (not just tests). Covers Welcome onboarding, status menu, Settings, and Chat.
---

# Run WhisperShortcut

WhisperShortcut is a macOS **menu-bar-only** app (`LSUIElement: true` — no Dock icon,
no main window). Every surface is reached through the status-item menu: Dictate,
Dictate Prompt, Screenshot, Read Aloud, **Chat**, **Configure** (Settings), Quit.

Because there's no window to "just open," you drive it through
[`driver.sh`](driver.sh) — a bash harness that opens the status menu and clicks items
via `osascript`/System Events, and saves PNGs via `screencapture`. **This is the
primary agent path.** Paths below are relative to the submodule root (`whisper-shortcut/`).
From the parent workspace, prefix with `cd whisper-shortcut &&`. This only works on
**macOS** with a logged-in GUI (Aqua) session — there is no Linux/headless path.

## Prerequisites

- **macOS + Xcode** (built here with Xcode 26.5). A signing identity is auto-detected;
  with none it falls back to ad-hoc signing (keychain re-prompts on rebuilds, but it runs).
- **Two TCC permissions granted to the terminal app that runs the driver** (Terminal,
  iTerm, VS Code, Cursor, …) — System Settings ▸ Privacy & Security:
  - **Accessibility** — so System Events can click the menu. Without it, clicks silently no-op.
  - **Screen Recording** — so `screencapture` can read the display. Without it,
    `screencapture` prints `could not create image from display`.
  These are one-time, per-terminal-app grants. You cannot set them from the CLI (the
  TCC DB is SIP-protected); the user grants them in System Settings, then re-run.

## Build & launch

```bash
# Rebuild and relaunch (builds AND restarts the running app). ~1–3 min cold.
bash scripts/rebuild-and-restart.sh
# or, via the driver (same thing):
bash .cursor/skills/run-whisper-shortcut/driver.sh build
```

The app bundle lands at `build/DerivedData/Build/Products/Debug/WhisperShortcut.app`.
If it's already built and you only need it running:

```bash
bash .cursor/skills/run-whisper-shortcut/driver.sh ensure   # launch if not already running
```

## Run (agent path) — the driver

```bash
D=.cursor/skills/run-whisper-shortcut/driver.sh

bash $D items                      # list status-menu item names (sanity check it's driveable)
bash $D shot Configure settings    # open Settings, screenshot its window → /tmp/ws-settings.png
bash $D close                      # close the front window
bash $D shot Chat chat             # open Chat, screenshot it → /tmp/ws-chat.png
bash $D close
bash $D menu menu                  # open the status menu itself, screenshot → /tmp/ws-menu.png
bash $D quit                       # quit the app
```

Other commands: `open <MenuItem>` (click an item, no screenshot), `ss [name]`
(screenshot the front window cropped, or full screen if none). Menu item names are
exactly: `Dictate`, `Dictate Prompt`, `Screenshot`, `Read Aloud`, `Chat`,
`Configure`, `Quit WhisperShortcut`. `Configure` opens the window titled **Settings**.

Screenshots go to `/tmp/ws-<name>.png` (override with `WS_SHOT_DIR`). `shot`/`ss`
**crop to the front WhisperShortcut window** (clean, window-only image); `menu` and a
windowless `ss` capture the full screen. **Always actually read the PNG** with the Read
tool — a blank or error frame means a permission is missing or the window didn't open in
time.

## Onboarding & first-run (user-perspective testing)

The Welcome window appears on launch when `hasCompletedOnboarding` is false
(`UserDefaultsKeys.hasCompletedOnboarding`, bundle `com.magnusgoedde.whispershortcut`).
Re-open it from Settings ▸ Privacy & Permissions ▸ "Show welcome tour again".

### Reset levels

| Goal | Command | What it keeps |
| --- | --- | --- |
| Re-show Welcome (safe) | `bash $D onboarding-reset` | Keychain API keys, app data, preferences |
| True first-run (destructive) | `bash $D onboarding-wipe` | Keychain only — deletes the app container |

Only use `onboarding-wipe` when you explicitly need a cold install. Warn the user first.

### Walk through Welcome

Welcome listens for **arrow keys** when no text field is focused: `123` = back, `124` =
forward. Footer **Continue** respects step gating (e.g. API key or offline Whisper before
permissions).

```bash
bash $D onboarding-reset
bash $D activate
bash $D ss welcome-intro          # screenshot current front window
bash $D key 124                   # → Privacy
bash $D ss welcome-privacy
bash $D key 124                   # → API keys (scroll may hide offline card)
bash $D ss welcome-apikeys
# … repeat per step; use key 123 to go back
```

Scroll inside the Welcome panel: focus the window (`activate`), move the mouse over it,
then scroll — System Events scroll is flaky; prefer arrow keys for step navigation.

Re-show without relaunch: Settings ▸ Privacy ▸ "Show welcome tour again", or
`WelcomeWindowController.shared.show()` path via Configure menu.

### Cognitive walkthrough (activation audit)

After UI/onboarding changes, run this checklist and **read every screenshot**:

1. `onboarding-reset` (or `onboarding-wipe` for full cold start).
2. Count steps and seconds until first successful dictate (or first "ready" state).
3. Note every friction point (external tabs for API keys, mic permission, model download).
4. Log findings in plain English for the user.

Report template:

```markdown
## Walkthrough: [feature]
- Reset: onboarding-reset | onboarding-wipe
- Steps to first success: N / ~Xs
- Blockers: …
- Screenshots: /tmp/ws-….png
```

Qualitative walkthrough beats aggregate metrics at low download volume. Pair with skill
**view-logs-via-bash** (`ONBOARDING:` category) when debugging failures.

## Run (human path)

`open build/DerivedData/Build/Products/Debug/WhisperShortcut.app` — a menu-bar icon
appears (no window). Click it to use the menu manually. Useless for an agent: nothing
to observe programmatically without the driver.

## Test

`bash scripts/run-tests.sh` runs the `WhisperShortcut-AppStore` **Swift Testing** plan —
**live** LLM/transcription round-trips that read API keys from the gitignored `.env`
(providers without a key skip), not a hermetic unit suite. Because they use Swift Testing,
the `xcodebuild` summary prints a misleading `** TEST SUCCEEDED ** … Executed 0 tests` —
judge the run by the script's exit status and the `✔ Test run with N tests … passed` line,
not the XCTest count.

## Gotchas

- **No window exists until you open one.** `osascript ... count of windows` is 0 at
  launch. The status item lives in `menu bar 2` of the process (`menu bar 1` is the app
  menu). The driver clicks `menu bar item 1 of menu bar 2`.
- **Two separate permissions, two separate failure modes.** Accessibility missing →
  clicks no-op silently (menu never opens, no error). Screen Recording missing →
  `screencapture` errors loudly. Diagnose them independently.
- **AppleScript number→string concatenation inserts commas.** `(x as integer) & " "`
  yields `464,  , 233` (a coerced list), which breaks `screencapture -R`. Coerce each
  value `as text` first. The driver already does this; don't "simplify" it back.
- **`screencapture -R` uses screen *points*, not Retina pixels.** Window
  position/size from System Events are already in points, so they feed `-R` directly;
  the saved PNG comes out at 2× (e.g. an 800×684-pt window → 1600×1368 px).
- **A menu left open blocks the next click.** The driver dismisses with Escape
  (`key code 53`) after `items`/`menu`; if you script raw osascript, do the same or the
  next `click` lands on the open menu.
- **`rebuild-and-restart.sh` kills by exact process name** (`pgrep -x`), not
  `pkill -f WhisperShortcut` — the latter also matches the script's own path. Don't
  swap it back.
- **First launch may pop a Welcome window** (if onboarding isn't complete) or Settings
  (if no API key is set), instead of going straight to idle. `front_window_bounds`
  will then crop whatever window is frontmost. Use `onboarding-reset` + `ss` to test.
- **Onboarding close = completed.** Closing the Welcome window sets
  `hasCompletedOnboarding` (see `WelcomeWindowController.windowWillClose`). Use
  `onboarding-reset` to test again.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `screencapture: could not create image from display` | Grant **Screen Recording** to your terminal app, then re-run. |
| Menu never opens, `items` returns nothing / hangs | Grant **Accessibility** to your terminal app. |
| `screencapture: -R requires a valid rect` | Bounds came back malformed — ensure the window actually opened (raise the `sleep` after `open`), or the `as text` coercion was lost. |
| `❌ WhisperShortcut is not running` | `bash driver.sh build` (or `ensure` if already built). |
| Build fails on code signing | Expected without an Apple Development identity — it falls back to ad-hoc and still runs; re-run if the keychain prompt was dismissed. |
