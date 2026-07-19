# WhisperShortcut 7.88

Hardening follow-ups from the 7.87 review: clearer OpenAI billing errors in Dictate Prompt, a safer Settings save path for Google keys, and help when Accessibility permission looks stuck after switching builds.

## Installation

Download the latest build from the [Releases page](https://github.com/mgsgde/whisper-shortcut/releases), move **WhisperShortcut.app** to your Applications folder, and launch it.

## What's New

### 💳 Dictate Prompt billing errors

- OpenAI's "no credit on the API account" error in **Dictate Prompt** is now shown as **Billing Required** (same as Dictate), instead of a generic rate-limit message.

### 🔑 Safer Google key saving

- The Settings Save button no longer writes an empty Google API key to the Keychain. Intentional clears still work via the key field itself; this closes a remaining wipe path after a failed Keychain read.

### ♿ Accessibility after App Store ↔ GitHub switch

- The Accessibility permission dialog now explains the stale-permission case when switching between App Store and GitHub builds (remove the entry with −, then re-add the app).
- A **Copy Reset Command** button puts `tccutil reset Accessibility com.magnusgoedde.whispershortcut` on the clipboard for Terminal if System Settings alone is not enough.

**Full Changelog**: https://github.com/mgsgde/whisper-shortcut/compare/v7.87...v7.88
