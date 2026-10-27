# MCP: every setting configurable (slice 2)

Ordered by Magnus, 2026-10-26: "Ich will, dass die komplette Applikation über MCP konfigurierbar
wird", starting with the models. Builds on `mcp-config-access.md` (slice 1) and the hardening
branch (`fix/mcp-hardening`: stable tool list, annotations, proposal routing per access level).

## Correction to slice 1's premise

`mcp-config-access.md` says `saveSettings()` rewrites every slot from one snapshot. No longer true:
it writes only slots that differ from `persisted` (`SettingsViewModel.swift:380`,
`SettingsSlot.slotsToSave`), and the window reloads slots when it becomes key. Two holes remain:
shortcuts (whole `ShortcutConfig` compared and written, so a stale open window writes an old
binding back) and stale display. Both are fixed below.

## Tools

Two generic tools, one catalog. No tool per setting.

- `get_settings` (read, `readOnlyHint`). Optional `category` filter. Returns, per setting:
  `id`, `title`, `category`, `type` (`bool` | `enum` | `string` | `shortcut`), `value`, and for
  enums `options: [{value, label, available, reason?}]`. `reason` says why an option cannot be
  picked now ("needs an OpenAI API key in Settings → Accounts", "direct-download build only",
  "not downloaded"). Also `requires_approval: true` for the proposal-only entries below, and
  `note` where a setting only matters with another one (e.g. language is ignored by Gemini models).
- `update_settings` (write, `destructiveHint: true` — deliberate: a settings write can be hard to notice and the batch is all-or-nothing, so clients should treat it with the same caution as a delete). Input
  `changes: {id: value}` (max 20) plus the usual `rationale`. All-or-nothing: every change is
  validated first; one invalid change rejects the call with one line per problem and writes nothing.
  - Access level `read`: rejected like other write tools.
  - `propose`: one proposal holding all changes.
  - `apply`: applied at once, except entries marked proposal-only, which turn the whole call into a
    proposal (one review, not a split).
  - Every applied batch is one change-log entry with the previous values, so Undo restores all of it.
  - Result: `{"status": "applied" | "pending_review" | "no_change", "changed": [{id, from, to}]}`.

`get_configuration` keeps its `models` block but adds `"settings": "call get_settings"`. The tune
recipe gets one step: check that the models fit how the user dictates (e.g. a pure ASR model like
gpt-transcribe ignores the Dictation prompt) and propose a model change with the trade-off.

## The catalog

`MCPSettingsCatalog`: an array of `MCPSetting` values, the single place a setting is added.

```swift
struct MCPSetting {
  let id: String            // stable snake_case, "dictation.transcription_model"
  let title: String         // as in the Settings UI
  let category: String
  let type: Kind            // .bool, .enumeration(options: () -> [Option]), .string(maxLength:), .shortcut
  let proposalOnly: Bool
  let unavailableReason: () -> String?   // whole setting unavailable (build flavour, missing permission)
  let read: () -> Any
  let validate: (Any) -> String?         // nil = ok, else a message for the model
  let apply: (Any) throws -> Void        // runs on main, performs every side effect
}
```

Runs on main through `MCPMain.runBounded` like the other config tools.

### Entries (≈ 46)

Ids, keys and side effects come from the inventory of 2026-10-26. Side effects call the existing
helper where one exists, never a bare `UserDefaults` write when the UI does more.

**Models (credential check in `validate`; after the write call
`ModelSelectionReconciler.postSelectionsChanged()`; prompt and chat models also post
`.promptModelChanged`):**

| id | options source | extra |
|---|---|---|
| `dictation.transcription_model` | `TranscriptionModel.selectableForDictation` | posts `.modelChanged` (offline preload) |
| `meetings.transcription_model` | same | also accepts `null` = "same as dictation" |
| `dictate_prompt.model` | `PromptModel.dictatePromptCapableModels`, `hasRequiredCredentialForDictatePrompt` | |
| `chat.model` | `PromptModel.chatModels`, validator `ChatView.chatUnavailableReason(for:)` (static) | extract `switchToModel`'s write + `recordModelUse` into a static helper both use |
| `meetings.summary_model` | `PromptModel.textChatModels` | |
| `improvement.model` | `PromptModel.textChatModels` | |
| `read_aloud.model` | `TTSModel.readAloudModels`, `TTSModel.hasRequiredCredential` | |

Options are the picker's list after `ModelPickerCuration.visibleModels`, so the AI app sees what
the user sees. A model without a credential is listed with `available: false` and a reason, and
`update_settings` refuses it (the reconciler would silently revert it).

**Provider model ids (string):** `chat.openrouter_model_id` (`OpenRouterChatPreferences.setModelID`),
`chat.chatgpt_plan_model_id` (`ChatGPTPlanPreferences.setModelID`, direct build, needs sign-in),
`chat.custom_endpoint_model_id`, `dictation.openrouter_model_id`, `dictate_prompt.local_model_id`.

**Model parameters (enum):** `dictation.language`, `dictation.temperature`,
`dictation.thinking_effort`, `read_aloud.speed`, `read_aloud.voice.{gemini,openai,xai,system}`
(options `TTSProvider.voices`, `""` = provider default).

**Shortcuts (7):** `shortcuts.{dictate,dictate_prompt,screenshot,read_aloud,add_to_glossary,open_chat,open_settings}`.
Value `{"key": "1", "modifiers": ["control","option"]}` or `null` = disabled. Validation reuses the
recorder rules (non-F keys need ⌘/⌥/⌃, Shift alone is not enough, F-keys may be bare) and the
conflict check, both extracted from `SettingsViewModel`/`ShortcutRecorderRow` into a static
`ShortcutValidation`. Apply: load the current config, replace the one slot,
`ShortcutConfigManager.shared.saveConfiguration` (re-registers hotkeys, rebuilds the menu).
`read_aloud` and `add_to_glossary` are direct build only.

**Behaviour (bool/enum):** `notifications.enabled`, `notifications.position`,
`notifications.duration`, `clipboard.auto_paste`, `clipboard.restore_after_paste`,
`dictation.fn_key`, `window.settings_close_on_focus_loss`, `chat.close_on_focus_loss`,
`recording.confirm_above_duration`, `meetings.chunk_interval`, `meetings.safeguard_duration`,
`read_aloud.smart_rewrite`, `dictate_prompt.screenshot_context`, `screenshot.save_enabled`
(refused if no folder is chosen), `chat.x_search_handles` (via the `XSearchHandles` setter),
`improvement.auto_run_interval` (apply also calls `checkAndRunIfDue()`, like the view).

**Permission-gated:** `clipboard.auto_paste` and `dictation.fn_key` need Accessibility,
`dictate_prompt.screenshot_context` needs Screen Recording. Turning them on without the
permission is refused with "grant it in Settings → Permissions first". MCP never triggers a
system permission prompt.

**Proposal-only at every level** (cost, network or privacy): `writing_style.enabled` (starts a
Gmail import), `dictate_prompt.tools_enabled` (sends calendar/mail lookups to the model),
`chat.claude_web_search` (paid), `general.launch_at_login` (SMAppService; extract
`setLaunchAtLogin` into a static helper).

### Never exposed

Secrets of every kind (API keys, OAuth, ChatGPT plan, Google account, Trello, mail accounts,
custom endpoint key, self-hosted token and headers, MCP tokens); telemetry consent and override;
the MCP server toggle, port, access level and "share recent dictations" (no self-escalation);
Offline Mode (switches the server off); "Save usage data" (`contextLoggingEnabled`, widens what
AI apps read); workspace folders and workspace write access; the three endpoint URLs (custom chat,
self-hosted transcription, local LLM: rerouting audio or chat to a server the AI app picked is
exfiltration); Sparkle auto-update; permissions; destructive actions (reset, delete data, model
downloads); `saveRawAssistantResponses`, `errorNotificationDuration` (no UI); UI state and
migration flags.

## Keeping an open Settings window consistent

1. `Notification.Name.settingsChangedExternally`, posted on main by the catalog after each apply
   and after an Undo of a settings change. Not `UserDefaults.didChangeNotification` (fires for
   every write, including the window's own).
2. `SettingsViewModel` observes it: `reloadFromDisk()`, and also reloads the shortcut half of
   `data` and `persisted` unless a shortcut recorder is active (`.shortcutRecordingStarted/Stopped`).
3. Shortcut save becomes per-slot: load the on-disk config and override only slots whose `data`
   differs from `persisted`. Closes the clobber even without step 2.
4. The three `onChange` handlers that prompt for permissions (auto-paste, Fn key, screenshot
   context) move into the Toggle's binding setter, so a programmatic reload never prompts.
5. `@State` text sections (X handles, OpenRouter slug, ChatGPT plan slug, custom endpoint model,
   local model id) re-read on the notification.

## Proposals, change log, UI

- `MCPProposal.Kind.settings` with `settingsChanges: [{id, from, to}]`; `MCPChange.Kind.settings`
  with the same payload, previous values restored by Undo through the catalog's `apply` (so side
  effects run on Undo too). Restore skips values that are no longer valid and says so.
- Proposal window for settings (written by Opus): one row per change, "Title: old → new" with
  human labels (model display names, "⌃⌥1"), the rationale above, Accept / Decline. No editing.
- "Changes by AI apps" list in Settings shows settings entries with the same one-line summary.

## Out of scope

`run_smart_improvement` (separate), chat memory and workspace map (content, not settings), meeting
write tools, `.mcpb`.

## Also fix

`ImprovementSettingsTab.swift:101` says Save usage data is "On by default"; the default is off
(`FullApp.swift:155`).

## Tests

- Catalog: every id unique; every entry reads without crashing; every enum's current value is in
  its options; no excluded key appears (assert against a deny-list of `UserDefaultsKeys`).
- `update_settings`: all-or-nothing on one invalid change; keyless model refused; permission-gated
  refused without permission (injected check); proposal-only turns an apply call into a proposal;
  `propose` level makes one proposal; Undo restores every value of a batch.
- Shortcuts: modifier rules, conflict, `null` disables; per-slot save keeps an on-disk change made
  while the view model held a stale config.
- Side effects: model write posts `.modelSelectionsReconciled` and `.modelChanged` (notification
  expectation); `settingsChangedExternally` posted once per batch.

## Docs

`README.md` feature list: AI apps can read and change WhisperShortcut's settings (models,
shortcuts, behaviour) over MCP, within the access level. `plans/active/mcp-config-access.md`:
mark slice 2 as superseded by this file.
