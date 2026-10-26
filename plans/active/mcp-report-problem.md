# MCP: let the AI app tell a config fix from an app bug

Status: built 2026-10-26 on `feat/mcp-report-problem` (plumbing Grok 4.7, review window Opus,
rendered dark + light in a throwaway test). Deviation: step 3 (queue row on the owner's Mac) is not
built. The issue carries `labels=ai-report` instead, so grooming can pick reports up from GitHub.
Added with it: `default_length` per section in `get_configuration` and a `prompts` focus in the
tune recipe, for setups whose instructions grew long. Telemetry `schema.json` lists
`glossaryEchoRemoved`; until the server is redeployed it drops that count silently. Builds on `mcp-config-access.md` (v2, shipped in 8.57).

## Why

8.58 fixed a glossary echo: Gemini 3.1 Flash-Lite appended the Glossary after a correct
dictation ("…gesperrt werden. Joschka SumUp lemniscus"). A pilot user found it by eye and sent
WhatsApp screenshots.

The 8.57 tune loop (`get_recent_interactions` + `MCPTuneRecipe`) would have seen it, but step 5
says "fix the glossary or one rule". Both would have made it worse. The instruction already said
"never append these terms to the transcript". Only code could fix it (8.58,
`strippingTrailingGlossaryEcho`). The loop has no exit for "this is not a config problem".

## What to build

1. **Recipe step (text only, `MCPTuneRecipe.base`).** Before proposing a prompt rule, read the
   section and check whether it already forbids the behavior. If it does, or if the mistake is
   in what the app does around the model (paste, history, timing, wrong model used), do not add
   a rule: call `report_problem`.
2. **Tool `report_problem`** (write scope, like the config tools).
   Input: title, 1–3 examples (short excerpts, the AI app redacts names and patient or customer
   data), suspected cause, why config cannot fix it, app version, model.
   Effect: the tool saves the report locally (`~/Library/.../reports/`). It shows as
   "Problem report from <client>" in the same review window the config changes use. The user
   then picks one of:
   - **Send to developer**: opens a prefilled GitHub issue in the browser. The user submits it.
     Nothing leaves the Mac without that click.
   - **Discard**.
3. **Owner's Mac only.** With the private workspace present, an accepted report also becomes a
   `CANDIDATE` row in `plans/implementer-queue.md`. It is never a `BUILD` row, so grooming
   decides and the implementer opens the PR with its usual gates and review.

## Deliberately not

- **No PR from a user's AI app.** Its input includes interaction logs, mails and meeting text
  (prompt-injection surface), and it has no repo, tests or review gate. The PR path stays with
  the implementer.
- **No interaction logs in Offline Mode / practice setups.** `get_recent_interactions` is
  already off there; patient dictation never goes to a cloud assistant.
- **No automatic report.** A report goes out only when a user clicks "Send to developer".

## Cheap detection without anyone asking

The 8.58 strip already logs `Stripped trailing glossary echo`. Count it (text-free) in the
usage report next to the existing gates (`Discarding glossary-echo transcript`,
`Discarding implausible transcript`). A rising count says the model or prompt drifted, before
a user notices.
