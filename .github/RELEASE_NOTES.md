**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

**If you download WhisperShortcut here, this is the first build since 8.05.** Versions 8.06 through 8.11 were released, but never reached this page: the pipeline that builds and notarizes the DMG failed on every one of them, and it failed quietly. This release fixes that and carries all six. App Store users have had these changes all along — nothing was held back from them.

Two of them matter enough to lead with.

## If you dictate offline with a Glossary, please update

The Glossary was handed to the on-device Whisper model as raw conditioning text, annotations and all. Whisper treats that as a writing sample to continue rather than a list of rules, so it learned to emit quoted, parenthesised fragments and fall into repetition loops. On one 64-second recording it returned **51 characters instead of 975** — most of the dictation simply lost. Your terms now reach Whisper exactly as you wrote them; the `(not "…")` notes and quotation marks do not.

## If you record Meetings, please update

The app keeps a limited number of chat sessions on disk. Meetings and pinned chats are never deleted — but they still counted against that limit. Once enough meetings had piled up there was no room left for ordinary chats, so every save deleted them: pressing ⌘N created the new chat and silently threw away the one you had been reading. The limit now applies only to chats that may actually be deleted.

## Offline dictation got substantially faster

- **It transcribes while you speak.** Sections are transcribed at natural pauses, so pressing Stop usually leaves only the last one to process. On a 73-second dictation with pauses, the wait after Stop went from about 20 seconds to 4–6. A single unbroken stretch gains little — the final section still has to be transcribed.
- **No cold start before every dictation.** The model now loads while you speak instead of afterwards, and the model you dictate with stays loaded rather than being released after five idle minutes. On an M1 Pro with Whisper Large v3 Turbo, a 25-second dictation after a break went from about 13 seconds to about 4. It is still released when macOS is short on memory, and when you switch to a cloud model.
- A recording is no longer abandoned if macOS unloads the speech model mid-dictation — it is reloaded and the dictation continues.

## Point Chat and Dictate at your own Azure or Vertex tenant

The custom endpoint already spoke plain OpenAI, which covers a shared proxy like OpenRouter or LiteLLM — but not the deployments people with their own EU tenant and DPA actually run.

- **Azure OpenAI / Microsoft Foundry** and **Google Vertex AI**: enter the base URL, the model (on Azure, your *deployment* name) and a key in Settings → Chat. One-click presets fill in the URL shape for each.
- Azure is recognised from the URL and its key is sent the way Azure expects, a bare resource URL is expanded for you, and a missing `api-version` is filled in — the three things that otherwise fail as a confusing 404.
- Dictate reaches the same tenant through the self-hosted transcription endpoint.

Requests go straight from your Mac to that endpoint, under your own Microsoft or Google contract. A Vertex key is a short-lived `gcloud auth print-access-token` value, so it needs re-pasting about hourly; Azure keys do not expire.

## Offline Mode

- **Read Aloud works offline** using on-device macOS voices. Turning Offline Mode on selects that voice automatically.
- **The update check is covered too.** The direct-download build asks GitHub whether a newer release exists, and that one request went out through a connection Offline Mode did not guard — the only call in the app that could still reach the internet with the switch on. It now goes through the same guard as everything else.
- Onboarding picks the model it just downloaded, so the first dictation no longer fails with "model not downloaded".
- Offline-only setups are no longer forced into Settings on every launch.

## Dictate

- **Stop cancels the request** instead of leaving a transcription running in the background.
- **Retry works again.** After a failed dictation it re-runs the same audio and pastes the transcript instead of silently dropping it.
- A failed dictation no longer overwrites your clipboard with the error text. The popup still shows what went wrong.

## Chat

- **Grok 4.6 is the default Grok model**, and the two Grok entries describe what they actually are — 4.6 the flagship, 4.3 the cheaper option with a 1M-token context.
- **Claude (Anthropic)** is documented as a chat provider — Settings, `/claude` and the in-app Chat all agree.
- Repeated folder lookups stop costing a round trip: a repeat is answered from the first result, and a search whose words already came up empty is flagged even when the folder differs.
- Creating or deleting a calendar event, changing a Trello card, or opening a URL asks first.

## Fixes

- Fixed a crash: drawing a keyboard-shortcut label could abort the app outright, because macOS's keyboard-layout lookup traps when called off the main thread.
- Offline Read Aloud no longer hangs on empty text.
- Google sign-in refuses a broken login token instead of continuing with an all-zero state.
- The App Store review prompt uses the current StoreKit entry point; a prompt that cannot be shown stays pending instead of being silently spent.

## Installation

Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.05...v8.12
