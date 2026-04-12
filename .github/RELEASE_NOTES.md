# WhisperShortcut 6.9

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

- **Chat — Grok (xAI) and multi-provider architecture**: The chat experience can use **Google Gemini** or **xAI Grok** (Grok 4, Grok 4 Reasoning, Grok 4 Fast). Grok uses the xAI API with optional **web** and **X (Twitter) search** for up-to-date answers. Add your xAI API key in Settings; use the `/model` command in chat for shortcuts like `grok`, `grok fast`, and `grok reason`. The in-chat model picker lists providers; other app areas that only support Gemini are unchanged.
- **Gemini Chat — composer paste**: Pasting from apps that supply rich text (for example browsers or Mail) no longer pulls in foreign fonts, colors, or link styling. Text is inserted as plain content with the usual typing appearance (system font at 16pt, label color), so the message field stays consistent no matter where the text came from.

## Full changelog

[Compare v6.8…v6.9](https://github.com/mgsgde/whisper-shortcut/compare/v6.8...v6.9)
