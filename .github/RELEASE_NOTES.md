## Dictate Live
- **No more glued words.** When you start a new Dictate Live session right after existing text, the first words now get a space in front of them.
- **Fillers are dropped.** "äh", "ähm", "hm", "mhm" and "Mm-hmm" no longer end up in your text.
- With Punctuation set to "Only when spoken": "drei Pünktchen" and "Auslassungspunkte" become "…", and "Schrägstrich" is also recognised when it is heard as "Schreckstrich" or "Schräg Strich".

## Dictation
- **Cancel really cancels.** Cancelling a long Dictate recording now stops the transcription that is still running.
- **Retry uses the right recording.** "Retry" on a Dictate Prompt now works with that recording's settings, not the most recent one.
- **No surprise job after a cancel.** If you press the cancel shortcut while the "long recording" dialog is open, clicking Process no longer starts a job.
- **Your clipboard is safe.** If you copy something while a dictation is still processing, restoring the clipboard after the paste no longer overwrites it.

## Clipboard after auto-paste
One choice instead of two switches: Settings → General → **After auto-paste: Leave dictation / Restore previous / Empty it**. Your current setting is kept.

## Fixes
- **Copy, paste, select all and undo work on non-English Macs.** ⌘C, ⌘V, ⌘A and ⌘Z failed in some WhisperShortcut windows when macOS ran in another language.
- Update notes are now shown in German on Macs set to German.

## Installation
Download the DMG from the [releases page](https://github.com/mgsgde/whisper-shortcut/releases), open it, and drag WhisperShortcut to your Applications folder.

**Full changelog:** https://github.com/mgsgde/whisper-shortcut/compare/v8.76...v8.77
