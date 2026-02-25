---
name: Gemini Chat Readability and Selection
overview: Improve readability of model replies (line length, line spacing, font size), enable full-post selection via single Text view, and show Sources in a compact grid instead of a vertical list.
todos: []
isProject: false
---

# Gemini Chat: Readability and Full-Post Selection

## Goals

1. **Full-post selection:** User can select the entire model reply with one continuous selection (no per-paragraph boundaries).
2. **Readability:** Shorter effective line length, more line spacing, and optionally slightly larger font for model replies.
3. **Sources display:** Show grounding sources in a compact grid (2–3 columns) instead of a vertical list.

## Cause of Current Selection Limit

In [WhisperShortcut/GeminiChatView.swift](WhisperShortcut/GeminiChatView.swift), model replies are rendered by `paragraphMarkdownView` (lines 536–551): content is split on `\n\n`, and each paragraph is a **separate** `Text` in a `VStack`. Text selection in SwiftUI is per view, so selection cannot span across these paragraphs.

## Changes (all in GeminiChatView.swift)

### 1. Single-Text rendering for model replies (enables full-post selection)

- **Replace** `paragraphMarkdownView` so the **entire** reply is one `Text`:
  - Use a single `AttributedString(markdown: content)` for the full `content` (no split by `\n\n`).
  - Render one `Text(attr)` (with fallback to `Text(content)` if Markdown parsing fails).
- **Effect:** One text view for the whole message, so the user can select from start to end in one drag. Paragraph breaks remain as `\n\n` in the string and will still show as line breaks in the single `Text`.
- **Trade-off:** The current 8pt `VStack(spacing: 8)` between paragraphs is removed; paragraph separation is only by line breaks. No code change for “paragraph spacing” beyond this single-Text approach.

### 2. Limit line length (readability)

- In `MessageBubbleView`, constrain the bubble (and thus the text block) to a maximum width so lines do not span the full window.
- **Where:** Apply `.frame(maxWidth: 560)` to the `VStack` that contains `bubbleContent` (the one with `spacing: 5`, around line 496). Use 560pt as a readable width; adjust if desired.
- **Effect:** Long lines wrap earlier; less horizontal eye travel.

### 3. Increase line spacing (readability)

- In `bubbleContent`, change `.lineSpacing(5)` to `.lineSpacing(8)` (line 519).
- **Effect:** More space between lines, less dense block of text.

### 4. Optional: slightly larger font (readability)

- In `bubbleContent`, optionally change `.font(.body)` to `.font(.system(size: 15))` for model (and optionally user) messages, or keep `.body` if the current size is preferred.
- **Recommendation:** Apply only to the model branch (the single `Text` for the reply) so user bubbles stay unchanged: e.g. use `.font(.body)` for user and `.font(.system(size: 15))` for the model reply view.

### 5. Sources: grid layout (readability)

- **Where:** `sourcesView` in `MessageBubbleView` (lines 553–579). Currently a `VStack` with `ForEach` – each source is one row.
- **Change:** Use a `LazyVGrid` with **adaptive columns**: `columns: [GridItem(.adaptive(minimum: 160))]` so sources wrap into 2–3 columns depending on bubble width. Keep the "Sources" heading above; each cell remains a `Link` (icon + `source.title`), with `.lineLimit(1)` and `.truncationMode(.tail)` so long titles don’t break the layout.
- **Effect:** Sources appear side-by-side where space allows, more compact and scannable than a long vertical list.

## File and code references

| Change              | Location                                           | Current                     | New                                                              |
| ------------------- | -------------------------------------------------- | --------------------------- | ---------------------------------------------------------------- |
| Full-post selection | `paragraphMarkdownView` (lines 534–551)            | Multiple `Text` in `VStack` | Single `Text(AttributedString(markdown: content))` with fallback |
| Line length         | `MessageBubbleView` body, `VStack` around line 496 | No max width                | `.frame(maxWidth: 560)` on that `VStack`                         |
| Line spacing        | `bubbleContent` (line 519)                         | `.lineSpacing(5)`           | `.lineSpacing(8)`                                                |
| Font (optional)     | `bubbleContent` (line 518)                         | `.font(.body)`              | `.font(.system(size: 15))` for model reply only                  |
| Sources layout      | `sourcesView` (lines 553–579)                      | `VStack` + `ForEach` (list) | `LazyVGrid` with `GridItem(.adaptive(minimum: 160))`             |

## Implementation notes

- Keep `.textSelection(.enabled)` on the parent of the text (already present on `bubbleContent`).
- For the single-Text fallback when Markdown fails: `Text(content)` with the raw string so something always renders.
- All edits remain in English (comments, no new German UI strings).

## Summary

- **Selection:** One `Text` for the full model reply so the complete post can be selected in one go.
- **Readability:** Cap bubble width at 560pt, line spacing 8pt, optional 15pt font for model replies only.
- **Sources:** Display grounding sources in an adaptive grid (min 160pt per column) instead of a vertical list.
