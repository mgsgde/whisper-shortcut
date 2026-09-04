**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Your chats no longer disappear when you open a new one

**If you record Meetings, please update.** The app keeps a limited number of chat sessions on disk. Meetings and pinned chats are never deleted — but they still counted against that same limit. Once enough meetings had piled up, there was no room left for ordinary chats, so every save deleted them: pressing ⌘N created the new chat and silently threw away the one you had just been reading. The limit now applies only to the chats that may actually be deleted, so meetings can no longer crowd them out however many you have.

## Point Chat and Dictate at your own Azure or Vertex tenant

The custom endpoint already spoke plain OpenAI, which covers a shared proxy like OpenRouter or LiteLLM — but not the two deployments that people with their own EU tenant and DPA actually run. Both now work:

- **Azure OpenAI / Microsoft Foundry** and **Google Vertex AI**: enter the base URL, the model (on Azure, your *deployment* name) and a key in Settings → Chat. One-click presets fill in the URL shape for each.
- Azure is recognised from the URL and its key is sent the way Azure expects, a bare resource URL is expanded for you, and a missing `api-version` is filled in — the three things that otherwise fail as a confusing 404.
- Dictate reaches the same tenant through the self-hosted transcription endpoint, which now speaks Azure too.

Requests go straight from your Mac to that endpoint, under your own Microsoft or Google contract. Note that a Vertex key is a short-lived `gcloud auth print-access-token` value, so it needs re-pasting about hourly; Azure keys do not expire.

### Also in this release

- Fixed a crash: drawing a keyboard-shortcut label could abort the app outright, because macOS's keyboard-layout lookup traps when it is called off the main thread.

## Installation

Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.09...v8.10
