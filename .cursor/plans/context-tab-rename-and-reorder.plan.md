# Context tab: rename, reorder, and optional "Open user context file"

## Step 1: Rename to "Context" and reorder content

- **Tab name**: "Smart Improvement" → "Context" (sidebar; English only).
- **Content order** in the tab:
  1. **Context section** (top): Show user context first — read-only block with current `user-context.md` content (disclosure style), subtitle e.g. that it’s used by Dictate Prompt and Prompt & Read.
  2. **Smart Improvement section**: Existing settings (shortcut, interval, threshold, Run improvement now, Improve from my voice, model). Section header "Smart Improvement".
  3. **System prompts overview**: Only Dictation, Dictate Prompt, Prompt & Read (remove User Context row to avoid duplication).
  4. **Interaction data** and **Usage instructions**: Unchanged.
- **Files**: `SettingsConfiguration.swift` (tab raw value), `SettingsView.swift` (tab description), `SmartImprovementSettingsTab.swift` (reorder + new Context block, rename section headers). Docs: "Settings > Smart Improvement" → "Settings > Context" in README, privacy, ResetSection, etc. Notifications can keep title "Smart Improvement".

## Step 2 (optional): "Open user context file" button

- **Idea**: In the Context section, do *not* show the user context content inline. Instead add a button that opens `user-context.md` in the default app (e.g. TextEdit, VS Code) so users can edit the file outside the app.
- **Implementation**: Add e.g. `openUserContextFile()` in `SettingsViewModel` (URL = `UserContextLogger.shared.directoryURL.appendingPathComponent("user-context.md")`; create file/directory if needed; `NSWorkspace.shared.open(fileURL)`). In the Context section: remove the read-only content block from Step 1 and add a button "Open user context file" plus a short subtitle.
- **Note**: Whether to adopt this step is still open; evaluate after Step 1 or after trying the button in a build.
