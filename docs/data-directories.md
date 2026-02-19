# Data Directories: Sandbox vs Normal

WhisperShortcut can store app data in **two different locations** depending on how the app is run:

| Context | Application Support path |
|--------|---------------------------|
| **Sandbox (Container)** | `~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/` |
| **Normal (non-sandbox)** | `~/Library/Application Support/WhisperShortcut/` |

When the app is **sandboxed** (e.g. App Store build or run in a sandboxed context), macOS uses the **Containers** path. When run **without sandbox** (e.g. from Xcode with sandbox entitlement disabled), it uses the normal Application Support path.

**Affected data:**
- **UserContext/** – interaction logs (`interactions-YYYY-MM-DD.jsonl`), `user-context.md`, suggested prompts
- Scripts that reset or inspect this data (e.g. `reset-whisper-defaults.sh`, `check-interaction-count.sh`) should consider **both** locations, or document which one they target.

**UserDefaults** are separate: they live in `~/Library/Preferences/com.magnusgoedde.whispershortcut.plist` (or in the app’s container when sandboxed). The reset script `reset-whisper-defaults.sh` uses `defaults delete com.magnusgoedde.whispershortcut`, which applies to the active preference domain (sandbox vs normal depending on how the app was run).
