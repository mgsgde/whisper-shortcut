# Data Directories

The app uses a **single canonical path** for all Application Support data, whether it runs **sandboxed** or not. That path is always the **container** path:

`~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/`

When the app is not sandboxed (e.g. run from Xcode with sandbox disabled), it still reads and writes this directory so that data stays in one place across both run contexts.

**Folder structure (under the path above):**

| Subfolder | Contents |
|-----------|----------|
| **UserContext/** | Interaction logs (`interactions-YYYY-MM-DD.jsonl`), `user-context.md`, suggested prompts, error logs (`errors-YYYY-MM-DD.log`, 30-day retention), and (when auto-improvement applies) system prompt history (`system-prompt-history-dictation.jsonl`, etc.) and user context history (`user-context-history.jsonl`) |
| **Meetings/** | Live meeting transcript files (`Meeting-YYYY-MM-DD-HHmmss.txt`) |
| **WhisperKit/** | Offline Whisper models (downloaded via the app) |

**Scripts** that reset or inspect app data (e.g. `reset-whisper-defaults.sh`) only need to consider this **one** path.

**UserDefaults** are separate: they live in `~/Library/Preferences/com.magnusgoedde.whispershortcut.plist` (or in the app’s container when sandboxed). The reset script `reset-whisper-defaults.sh` uses `defaults delete com.magnusgoedde.whispershortcut`, which applies to the active preference domain (sandbox vs normal depending on how the app was run).

**Error logs:** Errors are written to `UserContext/errors-YYYY-MM-DD.log` (one line per error with timestamp). Files older than 30 days are removed automatically. Errors are also available via the system log (`bash scripts/logs.sh` or `log stream`). Resetting UserContext (e.g. “Reset interaction data” in Settings) removes the entire UserContext folder, including error log files.

**Note:** Meeting transcripts were previously stored in `~/Documents/WhisperShortcut/`. They are now under the app data folder (`…/WhisperShortcut/Meetings/`). Existing files in the old location are not moved automatically.
