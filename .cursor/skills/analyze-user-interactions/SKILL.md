---
name: analyze-user-interactions
description: Mine the local user-interaction JSONL logs for systematic failures and propose improvements across system prompts, defaults, code logic, logging, and UI. Use when the user asks for improvements based on actual usage — e.g. "what's going wrong in Dictate Prompt?", "analyze my recent interactions", "find patterns in the logs", "what should we improve based on how I'm using the app?".
---

# Analyze User Interactions

## Rule

Improvements should be grounded in **what actually happened** on the user's machine, not in hypotheticals. This skill is the inspection procedure: read the local JSONL interaction logs, cross-reference the macOS unified log for model + timing + error info, cluster failures into patterns, and only then propose changes — at the right level (prompt, default, code, logging, or UI).

Never propose a code or prompt change from a single anecdote. A pattern needs **≥2 examples** (or n=1 + clearly severe) and a quoted snippet of the actual interaction.

---

## 1. Data sources

### Primary: JSONL interaction logs
Path:
```
~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext/interactions-YYYY-MM-DD.jsonl
```

Three modes, each with its own schema:

| Mode | Fields | Purpose |
|---|---|---|
| `transcription` | `result, transcriptionModel, model, audioRef, ts` | Dictate (speech-to-text) output |
| `prompt` | `userInstruction, selectedText, modelResponse, model, ts` | Dictate Prompt edits |
| `geminiChat` | `userInstruction, modelResponse, model, ts` | Chat replies |

**Important caveats** when reading these files:

- `model` is logged for all three modes (`logPrompt` in `ContextLogger.swift` for prompt). Older `prompt` records written before this was wired up may have `model: null` — fall back to the macOS log filter `PROMPT-MODE-GEMINI: Starting execution` for those (the `Using model` suffix is built at runtime via `logPrefix`, so a literal source grep won't find it).
- `selectedText` can accumulate paste-history if the user re-pastes results. Treat extremely long `selectedText` with repeated near-identical fragments as suspect input, not real user content.
- `result` for `transcription` is **post-glossary-correction**, not raw STT output.
- Files are append-only JSONL — one record per line.

### Secondary: macOS unified log (model + timing + errors)
Use `bash scripts/logs.sh` (never `log show` directly — it's slower and has different defaults):

```bash
bash scripts/logs.sh -t 7d -f 'PROMPT-MODE-GEMINI: Starting execution'    # which prompt call ran (model in the JSONL `model` field)
bash scripts/logs.sh -t 7d -f 'Round-trip'                          # latency
bash scripts/logs.sh -t 7d -f '❌'                                  # error markers
bash scripts/logs.sh -t 7d -f 'GEMINI-CHAT'                         # chat traffic
bash scripts/logs.sh -t 7d -f 'TRANSCRIPTION'                       # STT traffic
```

### Tertiary: errors log
```
~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application Support/WhisperShortcut/UserContext/errors-YYYY-MM-DD.log
```

---

## 2. Procedure

### Step 1 — Scope
Confirm with the user (or assume defaults):
- **Mode(s)** to analyze: `prompt`, `transcription`, `geminiChat`, or all.
- **Time window**: default last 7 days.
- **Filter by model**: if the user changed the default mid-window, filter to only interactions on the model they care about. Cross-reference the macOS log to attribute each record to a model.

State your scope assumptions out loud before analyzing.

### Step 2 — Extract structured data
Parse the JSONL via Python over Bash. Sample one-liner:

```bash
cat ~/Library/Containers/com.magnusgoedde.whispershortcut/Data/Library/Application\ Support/WhisperShortcut/UserContext/interactions-*.jsonl | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        d = json.loads(line)
        if d.get('mode') == 'prompt':
            print(d.get('ts'), '|', d.get('userInstruction', '')[:60])
            print('  IN :', (d.get('selectedText') or '')[:200])
            print('  OUT:', (d.get('modelResponse') or '')[:200])
    except: pass
"
```

### Step 3 — Classify each interaction

For each **`prompt`** record, judge against these checks:

| Check | Question |
|---|---|
| Instruction honored | Did "korrigiere" fix grammar (not translate, not rewrite)? Did "translate" actually translate? Did "fasse zusammen" produce a summary? |
| Minimal-edit | Is the output similar in length and structure to input, or was it rewritten? |
| Language preserved | Output in the same language as input, unless explicitly told otherwise? |
| Format preserved | Bullets stayed bullets? No spurious markers added when not asked? Removed when "as a full sentence" was requested? |
| No hallucinations | No invented greetings, sign-offs, or new facts. |
| Input integrity | Is `selectedText` plausibly what the user actually had selected, or does it look accumulated? |

For **`geminiChat`**: language match, conciseness, appropriate tool/search use, no over-explaining.

For **`transcription`**: glossary terms transcribed correctly, filler-word removal applied, repetitions preserved per the dictation system prompt.

### Step 4 — Cluster failures

Group failures with the same root cause. Threshold: **≥2 examples** before proposing a fix. Single anecdotes get listed as "observed, insufficient data" — not as recommendations.

### Step 5 — Map each cluster to the right improvement level

| Cluster pattern | Likely fix | Where (code locations) |
|---|---|---|
| Model misinterprets instruction (e.g. "korrigiere" → translate) | Sharpen system prompt **or** upgrade default model | `WhisperShortcut/AppConstants.swift` / `SettingsConfiguration.swift` |
| Over-editing on small-change instructions | Add/strengthen minimal-edit rule | `AppConstants.swift` (defaultPromptModeSystemPrompt) |
| Format markers leak (bullet stays when "full sentence" requested, etc.) | Add format-preservation rule | `AppConstants.swift` |
| `selectedText` looks accumulated / contains paste history | Clipboard accumulation bug | `SpeechService.swift`, clipboard handling |
| Chat ignores grounding / search | Tool-use prompt or routing logic | `defaultChatSystemPrompt` / `ChatTools.swift` |
| Repeated 429s / slow round-trips | Rate-limit handling / model choice | `RateLimitCoordinator.swift` / `SettingsDefaults` |
| Same instruction recurs verbatim across days (e.g. "korrigiere" → 12×) | Candidate for a one-tap UI preset | Menu / Settings UI |
| Field missing from logs (genuine gap, not "older records") | Logging gap | `ContextLogger.swift` |
| Glossary term consistently mis-transcribed | Add term to default glossary | `AppConstants.swift` (whisper glossary) or Smart Improvement run |

### Step 6 — Report

Produce a single structured report with:

1. **Scope** — window, modes, total records, distinct models actually used (per macOS log cross-reference).
2. **Top failure clusters** — each with ≥2 quoted examples (instruction / input excerpt / output excerpt).
3. **Proposed changes** — one per cluster, **explicitly tagged** with the level:
   - `[prompt]` — system-prompt edit
   - `[default]` — change a `SettingsDefaults` value
   - `[code]` — code logic fix
   - `[logging]` — `ContextLogger` / `DebugLogger` gap
   - `[ui]` — UI / preset / shortcut suggestion
4. **Gaps for confident analysis** — e.g. "older `prompt` records have `model: null`; attribution before commit 8c029f4 relies on the macOS log filter."

---

## 3. Anti-patterns

- ❌ Proposing prompt changes from one bad example — system prompts drift longer without evidence.
- ❌ Reading only the macOS log (no instruction/input/output content) **or** only the JSONL (no model / timing / errors). Always cross-reference.
- ❌ Treating an extremely long `selectedText` as real input without flagging accumulation risk.
- ❌ Comparing "Model A vs Model B" without first filtering interactions by which model was actually active at that time.
- ❌ Suggesting a code change when a prompt change would do, or vice versa — match the fix to the cluster.
- ❌ Proposing a UI change for a behavior the user is fine with. Recurring instructions are only preset-candidates if the user has expressed friction.

---

## 4. Linked skills

- **debugging-workflow** — when a cluster points to a code bug, switch to that skill to add `DebugLogger` instrumentation and run a manual repro.
- **gemini-system-prompt-best-practices** — when the fix is a system-prompt change, apply Google's official guidelines before editing.
- **llm-model-docs** — when proposing a default-model change, confirm the target model ID and GA/Preview status.
- **view-logs-via-bash** — for filtering the macOS unified log by category (`PROMPT-MODE`, `GEMINI-CHAT`, `TRANSCRIPTION`).
- After applying any code/prompt change from this analysis, rebuild via `bash scripts/rebuild-and-restart.sh` — see the always-applied rule in `.cursor/rules/index.mdc`.
