**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Dictation
- **Dictation templates.** A new Settings tab, **Templates**, holds formats your dictation is poured into, such as a letter or a report. Assign the new **Template** shortcut and dictate: with one template it is applied directly, with several a numbered picker appears on the recording card. A template can have its own shortcut. Press Tab to skip the format for one recording. Dictate Prompt and your system prompts are unchanged.

## Own server
- **Pasting the full endpoint URL works.** An OpenAI-compatible server address that already ends in `/audio/transcriptions` is no longer extended a second time.
- **Clearer errors.** A server without a speech-to-text endpoint now says so, and a rejected key shows as an invalid key instead of switching to another provider.
- **Offline Mode accepts more local servers**, including names like `server.lan`, `.home.arpa`, `.internal`, Tailscale addresses and local IPv6.
- **Long recordings no longer time out** on your own server: the wait grows with the recording length, up to 10 minutes.

## Errors and billing
- **"Out of Credit" for OpenAI.** When your OpenAI account has no credit left, the popup says so and offers a **Top up** button.
- **Billing links are visible.** In the "Billing Required" message the provider links now come first instead of being cut off.
- **Error popups show their heading once**, not as title and first line.

## Chat
- **The `/x @handle` command is gone**, along with the default handles in Settings → Chat. Grok still searches all of X.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.71...v8.72
