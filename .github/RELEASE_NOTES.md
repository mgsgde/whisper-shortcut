# Release v6.4.0

## Installation

Download the latest release from [GitHub Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

### New Features

- **Gemini Chat window**: New dedicated chat window with a global shortcut (default: Cmd+7). Persistent session, multi-session support, and configurable window behavior (fullscreen, position, frame autosave).
- **Slash commands**: Command suggestions and autocomplete. Use Tab to execute commands. Supported: `/new`, `/back`, `/screenshot`, `/stop`, and others. Shift+Enter inserts a newline; Enter sends the message.
- **Grounding sources**: Inline display of grounding sources and citations in chat responses; FlowLayout for improved source display in message bubbles.
- **Screenshot in chat**: Capture screenshot from within Gemini Chat for context.

### Improvements

- **Gemini Chat**: Configurable system prompt for chat. Refined Markdown parsing and response formatting. Improved input height and scrolling; fixed text disappearing on resize or arrange. Window appears on current screen; cascading prevented.
- **Settings**: Shortcut configuration and command handling for chat. Renamed "Prompt Voice Mode" to "Prompt Read Mode" across the app.
- **API & privacy**: Enhanced Gemini API client and chat functionality; privacy documentation and logging improvements. Window title and GeminiAPIClient refactors.

### Fixes

- Chat window text no longer disappears on resize or arrange.
- Slash commands execute on Tab for all commands, not only `/screenshot`.

## Full Changelog

For a complete list of changes, see the [full changelog](https://github.com/mgsgde/whisper-shortcut/compare/v6.3.0...v6.4.0).
