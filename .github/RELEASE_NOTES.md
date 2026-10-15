**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Update notices
- **The GitHub build now tells you when a new version is out.** Once a day it checks for an update and shows a notice with the release notes and an **Install Update** button. Nothing is downloaded or installed until you click it. Updates are signed and verified before they install. Settings → About → Updates has **Check for Updates…** and a switch to turn the daily check off.
- The check also works in Offline Mode. It is the only request that leaves the Mac and sends only the app's name and version.
- Versions before 8.40 cannot do this, so install 8.40 once by hand. Later versions arrive as a notice.

## Dictate Prompt
- **Offline Mode: "Not in your dictation" warning.** On-device models now answer deterministically (no random sampling), and the app compares the result with what you said. Words that appear in the result but not in your dictation or selection trigger a ⚠️ warning, even with popups turned off. The pasted text itself is never changed.
- **↑/↓ and Return work on quick actions again.** The arrow keys move the highlight, and Return runs the highlighted action.

## Settings
- Section headers no longer slide under the toolbar while scrolling.
- Small text fix in Chat settings ("Custom endpoint").

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.39...v8.40
