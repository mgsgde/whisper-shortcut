**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Dictate Prompt
- **Look things up.** With a connected integration (Google, Trello or shared folders), Dictate Prompt can read what it needs before answering — your calendar and tasks, a Gmail thread, a Trello card, a file in a shared folder. It only uses read-only tools and never writes, sends or opens anything. Works with Gemini, OpenAI GPT-Audio and local servers (Ollama / LM Studio); in Offline Mode only shared folders are offered. Turn it off in Settings → Dictate Prompt → Look things up.
- Quick actions now also work when your Dictate Prompt model is OpenAI GPT-Audio (they run on GPT-6 Luna, since GPT-Audio needs a recording).
- Only the final answer is pasted; lead-ins like "Let me check your calendar." no longer end up in your document.

## Chat
- **Edit and resend** your last message with the pencil, and **Regenerate** any reply.
- **Tool steps are visible.** What the assistant is doing shows live in the typing indicator and stays as a collapsible list above the reply; a failed step shows its error.
- **Approvals inline.** Tools that change something (calendar, email, memory, app instructions, files) now ask in a card inside the chat instead of a blocking alert, with a preview of what gets written. Opening a link always asks.
- **Source chips for Claude and GPT.** Claude chats get web search, and both Claude and GPT replies show their sources as chips under the paragraph they support. Claude web search can be turned off in Settings.
- **New models:** GPT-6 Sol and Luna (`/gpt` selects Sol), Grok 4.7 (`/grok`), Claude Sonnet 5.5 and Opus 5.5 (`/claude` selects Sonnet 5.5).
- **Grouped model picker** with one section per provider; models that still need an API key are marked, and switching to one tells you right away.
- Quieter errors (shown once, inline), older turns show their action buttons on hover, and "Model set to …" notices are no longer sent to the model.
- Earlier tool results stay available to follow-up questions, so the assistant no longer loses event, task or card IDs.

## Recording and Read Aloud
- The recording pill says what it is doing: Listening, Prompting or Feedback while recording; Transcribing, Thinking or Preparing while processing.
- Read Aloud uses Gemini 3.8 Flash-Lite TTS by default (faster first audio, lower cost); Gemini 3.8 Flash TTS is available as an option.

## Getting started
- Onboarding lets you try a dictation right after granting microphone access, before the optional setup.
- **New installs** get ⌃⌥1–⌃⌥7 and ⌃⌥0 as default shortcuts, because ⌘-digits switch tabs in browsers, Slack and editors. **Existing installs keep their shortcuts.**

## Fixes
- Error popups now appear even when popups are turned off (that switch hides result and info messages, not failures).
- Smart Improvement checks the key of the model it actually uses; a GPT or Claude pick no longer does nothing silently.
- An all-day calendar event stays all-day when the assistant edits it.
- A Claude "overloaded" error mid-reply is reported instead of ending as an empty reply.
- An OpenAI-compatible provider that is out of credit now shows the top-up link.
- A local model without tool support falls back to a plain request instead of failing.
- The local model warm-up now also covers the Dictate Prompt lookup path.

## Settings
- Rarely changed chat and meeting options moved into the collapsed Advanced section of the Chat tab. Values are unchanged.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.26...v8.27
