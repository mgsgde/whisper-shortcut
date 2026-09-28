# Writing Style — Drafts That Sound Like the User

**Status:** Slice 1 implemented (2026-09-28, branch `feat/writing-style-slice1`). Off by default (`UserDefaultsKeys.writingStyleEnabled`). Touch points: `WritingContextResolver.swift` (bundle id → bucket), `WritingStyleStore.swift` (profile, pool, retrieval, prompt block), `WritingStyleImporter.swift` (Gmail import, cleaning, profile derivation + review panel), `GmailAPIClient.listMessageRefs` / `readThread`, `SpeechService.writingStyleBlock` (appended in `buildPromptEnvelope`, so all three provider paths get it), `Settings/Components/WritingStyleSettingsSection.swift` in the Smart Improvement tab, `WhisperShortcutTests/WritingStyleTests.swift`. Log markers `WRITING-STYLE:`, `WRITING-STYLE-IMPORT:`, `WRITING-STYLE-PROFILE:` (counts only). Next: Slice 2 (A/B evaluation) before anything else.

Deviations from the plan as written, all deliberate:

- **No `stats.json`.** Median length and reply ratio are computed from the pool on each request (≤ 2,000 samples, milliseconds). One file fewer that can drift from the pool.
- **Gmail import reads threads, not messages.** One `threads.get` per thread returns the user's sent messages *and* the message each one answered, so `incomingChars` (the reply-length ratio) comes for free instead of costing one extra request per message.
- **Typed chat text is not a source yet.** Chat prompts are instructions to an assistant, not messages to people; feeding them in would teach the wrong voice. Revisit only if the `default` bucket turns out to be empty in practice.
- **Gmail window is the last 365 days, capped at 200 sent messages** (plan said 180 days). A year catches rarer contexts; the cap keeps the first import fast.
- **Local Dictate Prompt models get no style block.** A review of the first cut found that small local models follow the examples even for translate/correct instructions. Cloud models only; the Settings copy says so.
- **The block sits before `promptModeOutputRule`,** so the output-format rule stays last in the system prompt.
- **Signatures:** a trailing block repeated in ≥ 3 samples is cut from its first contact-looking line (phone, email, URL, company form). The recurring sign-off above it stays, since it is part of the voice.
- **Privacy wording corrected:** with the feature on, profile and a few messages go out with every Dictate Prompt request to the Dictate Prompt model — the first cut's copy wrongly said they stay on the Mac.
- **"Which instructions get the block?"** is solved at the instruction level: the block tells the model to apply it only when composing a message the user sends as themselves and to ignore it for translate/summarize/correct. Check the logs for misfires in Slice 2.
**Audience:** LLM implementing the feature end-to-end
**Goal:** When Dictate Prompt writes or rewrites text for the user (an email reply, a WhatsApp message, a Slack answer), the result should read like the user wrote it, not like an assistant. The app learns how the user writes, separately for each context (email vs. messenger, and eventually per recipient), from text the user actually wrote and sent.

---

## Why this exists (the problem it solves)

Today a Dictate Prompt instruction like *"reply that I can do Thursday but not Wednesday"* over a selected email produces a polished, generic draft: too long, greetings and closings the user never uses, assistant filler ("I hope this finds you well", "Happy to help"), dashes, a register that doesn't match the recipient. The user then rewrites it by hand or sends something that doesn't sound like them. The only lever the user has is the Dictate Prompt system prompt in `system-prompts.md`, which is global (one register for every app and recipient) and describes style in adjectives, which models follow badly.

## Design decisions (made; revisit only with evidence)

- **Real examples beat style descriptions.** A profile that says "casual, short, uses Du" still produces LLM prose, just a more casual version of it. What works is **few-shot retrieval**: at request time, 3–5 messages the user really wrote in the same context are put into the prompt. The profile carries only **hard, countable facts** that examples alone don't reliably convey.
- **The profile is small and human-readable.** One Markdown file with a short section per context: typical greeting and closing, Du/Sie default, median message length, emoji yes/no, lowercase in messengers yes/no, recurring phrases, and a **never list** (phrases and punctuation the user never uses). The user can open and edit it in Settings like `system-prompts.md`.
- **Length is calibrated, not described.** Over-length is the most visible "AI" tell. From the corpus, compute the user's typical reply length relative to the incoming message per context (e.g. "replies to emails are ~0.4× the incoming length, median 45 words") and state it as a concrete target in the prompt.
- **Context comes from the frontmost app.** When ⌘2 fires, the menu bar app does not activate, so `NSWorkspace.shared.frontmostApplication` is the app the user is writing in (the same call `MenuBarController` already uses for auto-paste logging). Bundle ID → context bucket: `email` (Mail, Outlook, Spark, a browser tab on mail.google.com is out of reach, so browsers fall through), `messenger` (WhatsApp, Signal, Messages, Telegram), `work-chat` (Slack, Teams), `default`. Works in the sandbox, so both builds get it.
- **The strongest signal is the user's own edit.** When the user changes a draft before sending, the diff between "what we drafted" and "what was sent" says exactly what didn't sound like them. Where the sent text is retrievable (Gmail), this feeds the learning loop (Slice 4). Everything before that slice is bootstrapping.
- **Human-in-the-loop for profile changes, silent for the example pool.** Adding a sent message to the example pool is harmless and silent. Changing the profile (especially the never list) goes through `SmartImprovementReviewPanel`, like every other context change.
- **Only text the user wrote goes into the pool.** Quoted replies, forwarded content, signatures and other people's messages are stripped before anything is stored. A pool polluted with other people's writing teaches the wrong voice.
- **Local only, never logged.** The corpus and profile live under `UserContext/writing-style/`. They never enter the interaction log, the usage report, or Smart Improvement's log mining. In Offline Mode the existing profile and pool keep working; importing (Gmail) and profile derivation with a cloud model stop, like Smart Improvement does.

## Where it plugs in

```
⌘2 Dictate Prompt
  → frontmost app → context bucket            (new: WritingContextResolver)
  → buildPromptEnvelope(...)
       systemPrompt = buildDictatePromptSystemPrompt(...)
                    + WritingStyleStore.promptBlock(for: context,
                                                   incoming: clipboardContext)   (new)
            ├── profile section for this context (hard facts + never list)
            ├── length target (derived from incoming length × ratio)
            └── 3–5 retrieved examples, labelled as examples of the user's voice
  → provider paths unchanged (the block is part of systemPrompt, so Gemini,
    OpenAI and local all get it without per-provider code)
```

The style block is appended inside `SpeechService.buildDictatePromptSystemPrompt` (or right after it in `buildPromptEnvelope`), so it lands in all three provider paths at once — the envelope exists precisely so this kind of addition is not copied per provider. It is **only** added when the instruction produces text meant to be sent (see Open questions: detecting "write/reply" vs. "translate/summarize"). The screenshot-selection prompt path gets it too.

Local MLX models have small context windows: cap the block (e.g. 1,500 chars for local, 4,000 for cloud) and drop examples before dropping the profile.

## Data layout

`UserContext/writing-style/` (add to `Docs/data-directories.md`):

| File | Content |
|---|---|
| `profile.md` | Human-editable. `=== Email ===`, `=== Messenger ===`, `=== Work Chat ===`, `=== Default ===` sections, same header convention as `system-prompts.md` |
| `samples.jsonl` | One sample per line: `{id, context, source, recipient?, sentAt, incomingChars?, text}` — `source ∈ gmail, whatsapp-export, chat-typed, manual, sent-after-draft` |
| `drafts.jsonl` | Slice 4: recent Dictate Prompt drafts awaiting a sent-message match, pruned after 7 days |
| `stats.json` | Derived numbers per context (median length, reply ratio, emoji rate), recomputed on import |

Pool cap: ~500 samples per context, newest wins, so retrieval stays cheap and the file stays small.

## Retrieval (V1: no embeddings)

Score candidates in the matching context bucket by: same recipient (strong boost), recency, and length similarity to the expected reply length. Take the top 3–5, preferring diversity (not five replies to the same thread). Embeddings (Gemini embedding API, or on-device `NLEmbedding`) are a later upgrade only if topic mismatch shows up as a real problem — `NLEmbedding` would keep it offline.

## Sources

| Source | Slice | Notes |
|---|---|---|
| Gmail "Sent" | 1 | `GmailAPIClient.searchMessages(query: "in:sent newer_than:180d")` + `readMessage`. The existing `gmail.readonly` scope is enough. Needs paging beyond the 50-per-call cap. Strip quoted text (`On … wrote:`, `Am … schrieb …:`, `>` lines), signatures (`-- ` delimiter, repeated trailing blocks across messages), forwards. Recipient from `To:`. The incoming message, for the reply ratio, is the previous message in the thread. |
| Typed chat text | 1 | Already intercepted for `GlossaryFastLearner.learnFromTypedText`. Only useful for the `default` bucket (chat prompts are instructions to an assistant, not messages to people) — **may turn out to be noise; drop it if the examples it contributes look like prompts.** |
| Manual paste | 1 | A "Add examples" text box in Settings: paste a few messages, pick the context. The zero-integration path for App Store users without Google connected. |
| WhatsApp chat export | 3 | User drags the `.txt` (or `.zip`) from WhatsApp → Export Chat. Parse `[dd.mm.yy, HH:MM:SS] Name: text` (format varies by locale and platform — test both iOS and Android exports), ask once which name is the user, keep only their lines, merge consecutive lines into one message. Works in the sandbox (user-selected file). |
| WhatsApp/iMessage databases | not planned | Needs Full Disk Access, schemas change without notice, impossible in the App Store build. |

## Implementation slices (each independently shippable)

1. **Profile + pool from Gmail and manual examples; injected into Dictate Prompt.**
   - `WritingStyleStore` (load/save `profile.md`, `samples.jsonl`, `stats.json`; `promptBlock(for:incoming:)`).
   - `WritingContextResolver` (bundle ID → bucket; table in code, unknown → `default`).
   - `WritingStyleImporter.importFromGmail()` with the cleaning rules above; progress + result count in Settings.
   - Profile derivation: one call to the improvement model (same picker `ContextDerivation` uses) over a sample of ~40 messages per context, returning the hard-facts profile + never list as structured output. Shown in `SmartImprovementReviewPanel` before it is written.
   - Settings: new "Writing Style" section (Smart Improvement tab or its own tab — decide at build time based on tab length): enable toggle (default off until Slice 2 proves itself), Import from Gmail, Add examples, Edit profile, Clear data.
   - Hook into `buildDictatePromptSystemPrompt`. Log marker `WRITING-STYLE:` with context bucket, number of examples, block size — never the text.
2. **Evaluate before building more.** Take 10–15 real sent emails, replay the instruction that would have produced each against the incoming message with the feature on and off, and compare side by side (a blind A/B with the user picking which sounds more like them is the honest test). If the gain is not obvious, fix retrieval and the profile before Slice 3. Record the result in this plan.
3. **WhatsApp export + per-recipient retrieval.** Importer as described; recipient boost in retrieval; for messengers the recipient comes from the window title via Accessibility where available (direct build only), otherwise context-only.
4. **Learn from the user's edits.**
   - After each Dictate Prompt draft in the `email` bucket, append `{draft, createdAt, recipientHint?, contextBucket}` to `drafts.jsonl`.
   - The weekly `AutoPromptImprovementScheduler` run (or a lighter daily pass) fetches Gmail sent messages from the last 7 days, matches them to drafts by time window + token overlap (e.g. Jaccard > 0.4), and computes the diff.
   - Matched sent messages join the pool as `sent-after-draft` (silent).
   - Recurring edits (≥2 occurrences, the same evidence rule as `ContextDerivation`) — a phrase always deleted, a closing always replaced, drafts always shortened — become proposed profile changes, reviewed in the panel.
   - Non-Gmail contexts have no sent text to compare against; Voice Feedback covers them ("I never write 'Liebe Grüße', I write 'Grüße Magnus'") by adding `writingStyle` as a `targetSection` option in `VoiceFeedbackService`.
5. **Optional: Dictate in the user's voice.** Apply a very light version of the profile (never list only, no examples) to plain Dictate cleanup, so spoken text isn't polished into assistant prose. Only if Slice 2 showed that the never list alone makes a difference.

## Success criteria / falsifier

- Slice 2 A/B: the user prefers the style-on draft in a clear majority of pairs. If not, the feature doesn't ship as default-on.
- After Slice 4: median edit distance between draft and sent text (normalised by length) goes down over the first month. Log it per match as a number only.
- Existing outcome signals (`plans/active/outcome-signals.md`): the Dictate Prompt redo rate in the `email` and `messenger` buckets should not go up.

## Open questions

- **Which instructions should get the style block?** "Reply to this" and "write a message to Anna" should; "translate to English", "summarize", "fix the grammar" arguably should not, since those preserve someone else's text. Options: always add it but tell the model to apply it only when composing the user's own message, or a cheap keyword heuristic. Start with the instruction-level approach and check the logs for misfires.
- **Language.** The user writes German and English. Should buckets be split by language (`email-de`, `email-en`), or should retrieval simply prefer same-language samples? Prefer the latter unless the profile facts differ (Du/Sie only exists in German).
- **Browser-based mail and messengers.** Gmail or WhatsApp Web in a browser show up as "Safari/Chrome". The window title (Accessibility, direct build only) could disambiguate; otherwise they fall back to inferring the register from the incoming text.

## Non-goals

- Fine-tuning a model on the user's texts. Retrieval + profile is cheaper, works with every provider including local MLX, and can be inspected and edited.
- Reading other apps' databases (WhatsApp, iMessage, Mail.app).
- Sending anything. The feature only drafts; the user always sends.
