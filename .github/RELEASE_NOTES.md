**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Read Aloud
- **Player controls** — the pill at the bottom of the screen is now a full player: **✕** stop, **⏪ / ⏩** skip 10 seconds, **⏸ / ▶** pause and resume, a draggable progress bar with elapsed / total time, and the speed button. Seeking works anywhere in the text, including parts that are still being synthesized.
- **Faster start** — the first sentence or two is synthesized on its own before the rest, so playback begins after a few seconds instead of waiting for a whole paragraph. With an OpenAI voice, audio is now streamed into playback as it arrives — sound starts about a second after synthesis begins instead of six.
- **Smart Rewrite stays out of the way** — plain prose is read as-is even when Smart Rewrite is on; only code, logs, Markdown and URLs are rewritten. A rewrite that would make a long selection more than 30 % longer is discarded and the original text is read instead.

## Prompts
- Default prompts you never edited now follow the app's current wording after an update. Until now a changed default only reached new installs; sections you customised are left untouched.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.15...v8.16
