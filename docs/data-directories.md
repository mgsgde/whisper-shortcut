# Data Directories

App data (UserContext, interaction logs, etc.) is stored in the **Application Support** directory. Only the **sandbox (container)** location is used and supported:

| Context | Application Support path |
|--------|---------------------------|
| **Sandbox (Container)** | `~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/` |

When the app is sandboxed (e.g. App Store build), this is the container path above. The non-sandbox path (`~/Library/Application Support/WhisperShortcut/`) is no longer used for loading or storing this data.

**Affected data:**
- **UserContext/** – interaction logs (`interactions-YYYY-MM-DD.jsonl`), `user-context.md`, suggested prompts, and (when auto-improvement applies system prompts) system prompt history (`system-prompt-history-prompt-mode.jsonl`, `system-prompt-history-prompt-and-read.jsonl`)
- Scripts that reset or inspect this data (e.g. `reset-whisper-defaults.sh`, `check-interaction-count.sh`) should consider **both** locations, or document which one they target.

**UserDefaults** are separate: they live in `~/Library/Preferences/com.magnusgoedde.whispershortcut.plist` (or in the app’s container when sandboxed). The reset script `reset-whisper-defaults.sh` uses `defaults delete com.magnusgoedde.whispershortcut`, which applies to the active preference domain (sandbox vs normal depending on how the app was run).
