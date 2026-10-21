**[Get WhisperShortcut on the Mac App Store](https://whispershortcut.com/go/appstore?src=github-release)** — automatic updates, one-time purchase.

## Claude & other AI apps can now tune your setup
Claude Code, Claude Desktop and other MCP apps on this Mac could already read your meetings. Now, if you allow it, they can also improve your setup from what they know about you:
- add names and terms to your glossary
- rewrite your Dictate Prompt instructions and your writing style profile
- create or edit commands
- with "Save usage data" on and a second switch, look at your recent dictations to find out why one went wrong

In Settings → Meetings, the section is now called **Claude & Other AI Apps**. Choose how much an AI app may do:
- **Only read**
- **Suggest changes for me to approve** (default): each change opens in a review window that does not steal focus. Return never accepts it.
- **Make changes directly**: every change is listed under "Changed by AI apps", with Undo.

Dictation and Chat instructions always wait for your approval. New glossary terms apply directly, because they only add. Pending changes show in the menu bar as "Review N Changes from AI Apps…".

In Claude Code, `/whisper-shortcut:tune_whisper_shortcut` runs the built-in "tune my setup" recipe.

Existing connections keep reading and change nothing until you copy the new setup, which carries a separate key for changes. Everything stays local to this Mac and is switched off while Offline Mode is on.

## Also
- The Smart Improvement review collapses unchanged passages, so the actual change is easier to spot.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.56...v8.57
