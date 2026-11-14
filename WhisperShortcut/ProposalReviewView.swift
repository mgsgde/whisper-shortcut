//
//  ProposalReviewView.swift
//  WhisperShortcut
//
//  Review UI for a proposed change (an AI app's proposal, a new Writing Style profile): compare the
//  current text (read-only) with the suggested text (editable), Accept or Cancel.
//

import SwiftUI

// MARK: - SwiftUI View

/// One line of a unified line-based diff between current and suggested prompt.
struct ProposalDiffLine: Identifiable {
  enum Kind { case unchanged, removed, added, skipped }
  let id = UUID()
  let kind: Kind
  let text: String
}

/// Computes a line-based diff using Swift's CollectionDifference. Result is a unified list
/// (removed lines shown as red, added as green, common as grey) suitable for an at-a-glance review.
func computeProposalDiff(original: String, suggested: String) -> [ProposalDiffLine] {
  let oldLines = original.components(separatedBy: "\n")
  let newLines = suggested.components(separatedBy: "\n")
  let diff = newLines.difference(from: oldLines)

  // Apply diff incrementally to old, recording each change inline.
  var result: [ProposalDiffLine] = []
  var removals = Set<Int>()
  var insertions: [Int: String] = [:]
  for change in diff {
    switch change {
    case .remove(let offset, _, _): removals.insert(offset)
    case .insert(let offset, let element, _): insertions[offset] = element
    }
  }
  // Walk: emit unchanged old lines, mark removed ones, then insert new-line additions at their offsets.
  // Simpler: walk new sequence with offset, look up if line was an insertion or kept.
  var keptOldIndex = 0
  for (newIdx, newLine) in newLines.enumerated() {
    if insertions[newIdx] != nil {
      // Before emitting added line, drain any removals at the corresponding old index.
      while keptOldIndex < oldLines.count && removals.contains(keptOldIndex) {
        result.append(.init(kind: .removed, text: oldLines[keptOldIndex]))
        keptOldIndex += 1
      }
      result.append(.init(kind: .added, text: newLine))
    } else {
      // Drain removals first, then advance kept old index past unchanged lines.
      while keptOldIndex < oldLines.count && removals.contains(keptOldIndex) {
        result.append(.init(kind: .removed, text: oldLines[keptOldIndex]))
        keptOldIndex += 1
      }
      result.append(.init(kind: .unchanged, text: newLine))
      keptOldIndex += 1
    }
  }
  // Drain any trailing removals.
  while keptOldIndex < oldLines.count {
    if removals.contains(keptOldIndex) {
      result.append(.init(kind: .removed, text: oldLines[keptOldIndex]))
    }
    keptOldIndex += 1
  }
  return result
}

/// Folds long unchanged runs into one `.skipped` line, keeping `context` lines next to each
/// change. A one-line edit at the end of a long prompt is otherwise buried under the whole prompt.
func collapseUnchangedDiffLines(_ lines: [ProposalDiffLine], context: Int = 2) -> [ProposalDiffLine] {
  var result: [ProposalDiffLine] = []
  var start = 0
  while start < lines.count {
    guard lines[start].kind == .unchanged else {
      result.append(lines[start])
      start += 1
      continue
    }
    var end = start
    while end < lines.count && lines[end].kind == .unchanged { end += 1 }
    let keepBefore = start == 0 ? 0 : context
    let keepAfter = end == lines.count ? 0 : context
    let hidden = (end - start) - keepBefore - keepAfter
    if hidden > 1 {
      result.append(contentsOf: lines[start..<(start + keepBefore)])
      result.append(.init(kind: .skipped, text: String(localized: "⋯ \(hidden) unchanged lines")))
      result.append(contentsOf: lines[(end - keepAfter)..<end])
    } else {
      result.append(contentsOf: lines[start..<end])
    }
    start = end
  }
  return result
}

/// The red/green line diff, shared by the review window (MCP proposals, Writing Style) and the
/// Chat's approval card, so a change to the app's own instructions looks the same wherever it is
/// approved.
struct ProposalDiffLinesView: View {
  let lines: [ProposalDiffLine]
  var font: Font = .system(.body, design: .monospaced)
  var primary: Color = .primary
  var secondary: Color = .secondary
  var background: Color = Color(nsColor: .textBackgroundColor)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(lines) { line in
        HStack(alignment: .top, spacing: 6) {
          Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
            .font(font)
            .foregroundColor(line.kind == .added ? .green : line.kind == .removed ? .red : secondary)
          Text(line.text.isEmpty ? " " : line.text)
            .font(font)
            .italic(line.kind == .skipped)
            .foregroundColor(
              line.kind == .added ? .green : line.kind == .removed ? .red
                : line.kind == .skipped ? secondary : primary)
            .strikethrough(line.kind == .removed)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .background(
          line.kind == .added ? Color.green.opacity(0.10)
            : line.kind == .removed ? Color.red.opacity(0.10) : Color.clear)
      }
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(background)
    .cornerRadius(6)
  }
}

struct ProposalReviewView: View {
  let focusDisplayName: String
  let originalText: String
  let rationale: String?
  /// "Suggested change" for the app's own proposals (Writing Style); the AI-app inbox passes
  /// "Suggested by an AI app".
  let titlePrefix: LocalizedStringResource
  let cancelTitle: LocalizedStringResource
  let acceptTitle: LocalizedStringResource
  /// Word in the "Current …" / "Suggested …" labels ("prompt", "command", "profile").
  let textNoun: ReviewNoun
  /// Off for a deletion: there is no new text to edit.
  let allowsEditing: Bool
  /// Off for changes from AI apps: their window can open while the user types elsewhere, and a
  /// stray Return must never accept a change nobody read.
  let acceptOnReturn: Bool
  @State private var editedSuggestedText: String
  let onAccept: (String) -> Void
  let onCancel: () -> Void

  init(
    focusDisplayName: String,
    originalText: String,
    suggestedText: String,
    rationale: String? = nil,
    titlePrefix: LocalizedStringResource = "Suggested change",
    cancelTitle: LocalizedStringResource = "Cancel",
    acceptTitle: LocalizedStringResource = "Accept",
    textNoun: ReviewNoun = .prompt,
    allowsEditing: Bool = true,
    acceptOnReturn: Bool = true,
    onAccept: @escaping (String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.focusDisplayName = focusDisplayName
    self.originalText = originalText
    self._editedSuggestedText = State(initialValue: suggestedText)
    self.rationale = rationale
    self.titlePrefix = titlePrefix
    self.cancelTitle = cancelTitle
    self.acceptTitle = acceptTitle
    self.textNoun = textNoun
    self.allowsEditing = allowsEditing
    self.acceptOnReturn = acceptOnReturn
    self.onAccept = onAccept
    self.onCancel = onCancel
  }

  /// Title shown above the diff.
  var windowTitle: String {
    return String(localized: "\(String(localized: titlePrefix)) – \(focusDisplayName)")
  }

  private var diffLines: [ProposalDiffLine] {
    collapseUnchangedDiffLines(
      computeProposalDiff(original: originalText, suggested: editedSuggestedText))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(windowTitle)
        .font(.headline)
        .padding(.bottom, 4)

      // Outer ScrollView so all sections fit on small windows; buttons stay pinned at the bottom.
      ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 16) {
      if let rationale = rationale, !rationale.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Why this change")
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
          Text(rationale)
            .font(.system(.body))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
        }
      }

      // Something new (an AI app's first command or profile) has nothing to compare against,
      // and a deletion has no suggestion: it shows only the current text.
      if !originalText.isEmpty {
      if allowsEditing {
      VStack(alignment: .leading, spacing: 6) {
        Text("Diff (current → suggested)")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        ProposalDiffLinesView(lines: diffLines)
      }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(textNoun.currentLabel)
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        Text(originalText)
          .font(.system(.body, design: .monospaced))
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .padding(8)
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(6)
      }

      }

      if allowsEditing {
      VStack(alignment: .leading, spacing: 6) {
        Text(textNoun.suggestedLabel)
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        TextEditor(text: $editedSuggestedText)
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(6)
          .frame(minHeight: 260)
      }
      }
        }
        .padding(.trailing, 4)
      }

      HStack(spacing: 12) {
        Button(String(localized: cancelTitle)) {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        .pointerCursorOnHover()

        Spacer()

        Button(String(localized: acceptTitle)) {
          onAccept(editedSuggestedText)
        }
        .keyboardShortcut(acceptOnReturn ? .defaultAction : nil)
        .buttonStyle(.borderedProminent)
        .pointerCursorOnHover()
      }
      .padding(.top, 8)
    }
    .padding(24)
    .frame(minWidth: 820, minHeight: 600)
  }
}

/// What the reviewed text is, so the "Current …" / "Suggested …" labels are whole sentences a
/// translation can inflect, not a noun glued into an English template.
enum ReviewNoun {
  case prompt, instructions, profile, command, report, settings

  var currentLabel: LocalizedStringKey {
    switch self {
    case .prompt: return "Current prompt"
    case .instructions: return "Current instructions"
    case .profile: return "Current profile"
    case .command: return "Current command"
    case .report: return "Current report"
    case .settings: return "Current settings"
    }
  }

  var suggestedLabel: LocalizedStringKey {
    switch self {
    case .prompt: return "Suggested prompt (editable)"
    case .instructions: return "Suggested instructions (editable)"
    case .profile: return "Suggested profile (editable)"
    case .command: return "Suggested command (editable)"
    case .report: return "Suggested report (editable)"
    case .settings: return "Suggested settings"
    }
  }
}
