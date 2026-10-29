# Feature bets: every feature has to earn its place

Owner ruling 2026-10-29 (Magnus): "wenn ich zum Beispiel ein Feature implementiere, dann soll halt
irgendwie zwei, drei Wochen geschaut werden, ob ich oder irgendwer anders das tatsächlich nutzt.
Und wenn das halt überhaupt nicht genutzt wird, dann sollte zumindest eine Erwägung gezogen
werden, das wieder rauszunehmen." This is the same principle as sabaki.dance ("every feature is a
bet"), sized for a desktop app with very few opted-in installs.

## The rule

A change that adds a **user-facing feature** is finished only when it carries all three of these,
in the same PR:

1. a `TelemetryFeature` case (`WhisperShortcut/Telemetry/TelemetryModels.swift`) with its
   `TelemetryService.shared.used(.<case>)` call at the point where the user actually uses it
   (`TelemetryTests` fails if a case has no call site), plus the case in
   `server/telemetry/schema.json`;
2. its display name in `Settings/Components/FeatureUsageSection.swift` (en + de);
3. a row in the table below.

Not bets: bug fixes, refactors, model-ID bumps, copy changes, settings that only change how an
existing feature behaves. An extension that adds a new way to use a feature (a new command, a new
tool, a new provider) is a bet.

## How a bet is graded

`scripts/feature-bets.py` grades without a model. It reads this table, the local counts on
Magnus's Mac (`feature-usage.json` in the release container) and the opt-in telemetry (BigQuery
`features` rows).

- **Clock.** It starts on the publish date of the first release tag (`v*`) whose commit contains
  the commit that added the row. A row that is not in a release yet is `WAITING`. Built but not
  released is never graded (`AGENTS.md` → "Never grade a falsifier before the change is live").
- **Window.** 21 days by default (column `Window`).
- **Pass (`KEEP`).** Used on **≥ 3 distinct days** inside the window, either on Magnus's Mac or by
  other opted-in installs. "Others" is the telemetry daily total minus Magnus's local count for
  the same day, because pings carry no identifier. The report labels it as an estimate.
- **Fail (`REVIEW`).** Below that. **This is not a removal.** The weekly usage review
  (`scripts/usage-review-job.sh`) lists it in its mail and files one `ASK` row in
  `plans/implementer-queue.md` ("Remove <feature>? Used on N days in 21"). A feature only comes
  out on Magnus's word. If he keeps it, the row gets `Decision=keep (<date>, his reason)` and is
  never graded again.
- **Not measurable (`BLIND`).** A feature that cannot be counted where it is used (Offline Mode
  turns telemetry off, so only Magnus's own Mac counts for it) still grades from local counts. The
  report says that other users are invisible for it.

The thresholds are a gate. Per `AGENTS.md` → "No agent may weaken the gate it is judged by",
loosening the window or the day threshold is a human change in its own commit.

## Ledger

`Added` names the release the counting shipped in. `next` means the next release (the grader
resolves the date from git). Rows below the seed block are added by the PR that builds the feature.

| Feature (`TelemetryFeature`) | What the user does | Added | Window | Decision |
| --- | --- | --- | --- | --- |
| `dictation` | Dictate | next | 21d | |
| `dictatePrompt` | Dictate Prompt | next | 21d | |
| `chat` | Chat | next | 21d | |
| `readAloud` | Read Aloud | next | 21d | |
| `meeting` | Live Meeting | next | 21d | |
| `dictatePromptWithSelection` | Dictate Prompt on selected text | next | 21d | |
| `dictatePromptWithScreenshot` | Dictate Prompt with a screenshot attached | next | 21d | |
| `dictatePromptQuickPrompt` | Runs a quick prompt (Control-1…9) | next | 21d | |
| `dictatePromptTypedInstruction` | Types an instruction into the recording card | next | 21d | |
| `dictatePromptLookup` | Dictate Prompt looks things up (calendar, mail, Trello, files) | next | 21d | |
| `writingStyleApplied` | Writing Style profile shapes a Dictate Prompt | next | 21d | |
| `glossaryAddSelection` | Add Selection to Glossary | next | 21d | |
| `copyLastTranscription` | Copy Last Transcription | next | 21d | |
| `recentTranscriptionCopied` | Picks an entry from Recent Transcriptions | next | 21d | |
| `offlineMode` | Dictates with Offline Mode on | next | 21d | |
| `screenshotMenu` | Screenshot from the menu bar or its shortcut | next | 21d | |
| `readAloudSmartRewrite` | Smart Rewrite runs before Read Aloud | next | 21d | |
| `ownServer` | Request through their own OpenAI-compatible server | next | 21d | |
| `openRouter` | Request through OpenRouter | next | 21d | |
| `chatGPTPlan` | Chat on the ChatGPT plan | next | 21d | |
| `chatCommandNew` | `/new` | next | 21d | |
| `chatCommandScreenshot` | `/screenshot` | next | 21d | |
| `chatCommandAttach` | `/attach` | next | 21d | |
| `chatCommandFolder` | `/folder` | next | 21d | |
| `chatCommandWorkspace` | `/workspace` | next | 21d | |
| `chatCommandModelSwitch` | `/model` and the model aliases | next | 21d | |
| `chatCommandThink` | `/think` | next | 21d | |
| `chatCommandX` | `/x` | next | 21d | |
| `chatCommandSettings` | `/settings` | next | 21d | |
| `chatCommandPin` | `/pin`, `/unpin` | next | 21d | |
| `chatCommandMeeting` | `/meeting` | next | 21d | |
| `chatCommandCopy` | `/copy` | next | 21d | |
| `chatCommandFeedback` | `/feedback` | next | 21d | |
| `chatUserCommand` | Runs one of their own commands | next | 21d | |
| `chatImageAttachment` | Sends a chat message with an image or file | next | 21d | |
| `chatWebSearch` | Chat request with web search on | next | 21d | |
| `chatYouTube` | Chat watches a YouTube video | next | 21d | |
| `chatToolGoogle` | Chat uses Google Calendar, Tasks or Gmail | next | 21d | |
| `chatToolTrello` | Chat uses Trello | next | 21d | |
| `chatToolMail` | Chat uses an IMAP mailbox | next | 21d | |
| `chatToolFolderRead` | Chat reads a shared folder | next | 21d | |
| `chatToolFolderWrite` | Chat edits files in a shared folder | next | 21d | |
| `chatToolImageGeneration` | Chat generates an image | next | 21d | |
| `chatToolMemory` | Chat remembers or forgets a fact about them | next | 21d | |
| `chatToolMeeting` | Chat refines a meeting summary or transcript | next | 21d | |
| `meetingLiveNotes` | Live notes update during a meeting | next | 21d | |
| `meetingSummary` | Meeting summary is generated | next | 21d | |
| `meetingRetryTranscription` | Retry Meeting Transcription | next | 21d | |
| `mcpRead` | An AI app reads WhisperShortcut over MCP | next | 21d | |
| `mcpChange` | An AI app changes the setup over MCP | next | 21d | |
| `smartImprovementRun` | A Smart Improvement run | next | 21d | |
| `smartImprovementAccepted` | Accepts a Smart Improvement suggestion | next | 21d | |
| `sendFeedback` | Send Feedback | next | 21d | |
| `reportProblemLastDictation` | Report a Problem with Last Dictation | next | 21d | |
| `shareUsageReport` | Share Usage Report | next | 21d | |
| `welcomeTourReopened` | Reopens the Welcome Tour | next | 21d | |
| `checkForUpdatesManual` | Check for Updates by hand | next | 21d | |
