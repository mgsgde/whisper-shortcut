---
name: competitor-teardown
description: Research one successful competitor end-to-end (product, pricing, marketing, growth story) and turn it into an adopt/adapt/ignore backlog plus a 15-minute hands-on trial checklist. Use when the user names a competitor, stumbles over one on social media, or asks "what can we learn from X?".
---

# Competitor Teardown

Input: a competitor name or URL in `$ARGUMENTS`. If none is given, first identify the 3–5
currently most successful competitors in this app's space (voice dictation / voice-first
productivity on macOS) via web search — rank by funding, growth reports, and App Store
presence — and ask the user which one to tear down.

Why this command exists: a 5–15 minute look at one successful competitor (Wispr Flow,
2026-07-08) produced more roadmap and marketing insight than weeks of inward-facing work —
instant glossary learning, chat-based dictation corrections, and several positioning angles
shipped within a day of that look. Do this deliberately and repeatedly, not accidentally.

## Desk research (the agent does this part)

1. **Product**: features page, docs, changelog, platforms. List features we lack. For each,
   estimate implementation effort against OUR architecture — read the relevant code first
   (e.g. SpeechService, ChatTools, MenuBarController), don't guess.
2. **Pricing & positioning**: pricing model, free-tier limits, headline value proposition,
   which personas the landing page targets, concrete quantified claims ("4× faster than
   typing").
3. **Growth & marketing**: funding/ARR/growth teardowns, founder interviews and podcasts,
   Product Hunt launches, social formats that work for them (before/after demos, founder
   content), and "X vs Y" comparison pages ranking on their brand searches.
4. **Weaknesses**: recent negative reviews, privacy criticism, pricing complaints — map each
   to our differentiation (BYOK, no subscription, cost-per-use, AGPL open source, offline
   Whisper, no screenshots to third-party clouds).
5. **Overlap check**: compare findings against `plans/active/`, recent git log, and existing
   features so the output doesn't propose what already exists.

## Output (single markdown report)

- **Adopt** (build it): max 3 items, each with a one-slice implementation sketch and the
  files it touches.
- **Adapt** (our angle): marketing/positioning moves, copy suggestions, comparison-page
  ideas.
- **Ignore**: what NOT to copy, and why.
- **Hands-on checklist for the human** — the agent cannot replace this part. The deepest
  insights come from using the product, not reading about it. Time-box 15 minutes:
  install/trial steps, 3 specific workflows to try, and what to observe (onboarding
  aha-moment, latency feel, error handling, how it earns trust).

Save the report to `plans/research/competitor-<name>-<yyyy-mm-dd>.md` (create the directory
if missing) so future sessions can diff against it and avoid re-proposing old ideas.
