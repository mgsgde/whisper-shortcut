# WhisperShortcut Privacy Policy

WhisperShortcut runs on your Mac. Your content never passes through a server of ours.

## What we collect

By default, nothing leaves your Mac for us. The app has no analytics SDKs and no third-party tracking.

**Anonymous usage statistics (optional, off by default).** If you turn on "Share anonymous usage statistics" (setup or Settings → Privacy & Permissions), the app sends a daily summary of counts to a small server we operate: how often features were used and whether they worked, failure classes such as "network", which built-in models were used (models you named yourself are sent as `custom`), which providers have a key (never the key), app and macOS version, and how many days since first launch. Never transcripts, prompts, replies, audio, clipboard, the apps you paste into, error messages, or any identifier. The server keeps summaries for 400 days, does not store IP addresses, and its code is public under `server/telemetry/`. "See exactly what is sent" shows the exact JSON; turning it off deletes anything not yet sent. Unavailable in Offline Mode; administrators can force it off with the `telemetryForceDisabled` preference.

The one thing that can reach us is the optional **Usage Report** in Settings → About, and only because you send it: the app composes it locally, shows you the complete text, and it travels only if you then press send in your own mail or WhatsApp app.

## Smart Improvement (optional, your choice)

When **Save usage data** is enabled, your interaction logs (dictation, Dictate Prompt, and chat) are stored locally and periodically sent to the AI provider you configured so the app can suggest better prompts. This goes only to your chosen provider — never to us or any third party. You can turn it off during setup or in Settings → General.

## What you send (controlled by you)

- **Audio** you record is sent to the AI provider you choose (Google Gemini, OpenAI, or xAI) for transcription. After the request completes we discard the audio.
- **Text** you type in chat or Dictate Prompt is sent to the provider you selected for that request.
- **Screenshots** you attach to chat messages are sent to the provider along with that message.
- **Usage report** (optional, to us): how many dictations, Dictate Prompt runs, and chat turns you made, which models you used, how often a dictation was delivered or had to be redone, and the apps text was pasted into most often. Counts and timings only — never transcripts, spoken instructions, model replies, or audio. You read the whole report before deciding to send it.

## Where it goes

- Requests go directly from your Mac to the provider you configured. We do not proxy traffic through any server.
- Each provider's own privacy policy governs how they handle the data you send them.

## How API keys are stored

- API keys are stored in the macOS Keychain. They never leave your machine except as part of authenticated HTTPS requests to the provider you configured.

## Permissions used

- **Microphone** — required to record audio for dictation.
- **Accessibility** — optional. Used to auto-paste transcribed text into other apps.
- **Screen Recording** — optional. Used only when you attach screenshots in chat.

You can review and revoke each permission at any time in macOS System Settings → Privacy & Security, or from the in-app Privacy & Permissions tab.

## Open source

The app is open source so you can audit how data is handled.

## Contact

Questions or concerns: mgsgde@gmail.com
