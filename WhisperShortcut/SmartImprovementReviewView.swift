//
//  SmartImprovementReviewView.swift
//  WhisperShortcut
//
//  Review UI for Smart Improvement: compare original prompt (read-only) with suggested prompt (editable), Accept or Cancel.
//

import AppKit
import SwiftUI

// MARK: - SwiftUI View

/// One line of a unified line-based diff between current and suggested prompt.
struct SmartImprovementDiffLine: Identifiable {
  enum Kind { case unchanged, removed, added, skipped }
  let id = UUID()
  let kind: Kind
  let text: String
}

/// Computes a line-based diff using Swift's CollectionDifference. Result is a unified list
/// (removed lines shown as red, added as green, common as grey) suitable for an at-a-glance review.
func computeSmartImprovementDiff(original: String, suggested: String) -> [SmartImprovementDiffLine] {
  let oldLines = original.components(separatedBy: "\n")
  let newLines = suggested.components(separatedBy: "\n")
  let diff = newLines.difference(from: oldLines)

  // Apply diff incrementally to old, recording each change inline.
  var result: [SmartImprovementDiffLine] = []
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
func collapseUnchangedDiffLines(_ lines: [SmartImprovementDiffLine], context: Int = 2) -> [SmartImprovementDiffLine] {
  var result: [SmartImprovementDiffLine] = []
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

struct SmartImprovementReviewView: View {
  let focusDisplayName: String
  let index: Int?
  let total: Int?
  let originalText: String
  let rationale: String?
  /// The prompt section under review, when there is one; it picks which scorecard numbers to show.
  let section: SystemPromptSection?
  /// "Smart Improvement" for the app's own runs; the AI-app inbox passes "Suggested by an AI app".
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
    index: Int? = nil,
    total: Int? = nil,
    originalText: String,
    suggestedText: String,
    rationale: String? = nil,
    section: SystemPromptSection? = nil,
    titlePrefix: LocalizedStringResource = "Smart Improvement",
    cancelTitle: LocalizedStringResource = "Cancel",
    acceptTitle: LocalizedStringResource = "Accept",
    textNoun: ReviewNoun = .prompt,
    allowsEditing: Bool = true,
    acceptOnReturn: Bool = true,
    onAccept: @escaping (String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.focusDisplayName = focusDisplayName
    self.index = index
    self.total = total
    self.originalText = originalText
    self._editedSuggestedText = State(initialValue: suggestedText)
    self.rationale = rationale
    self.section = section
    self.titlePrefix = titlePrefix
    self.cancelTitle = cancelTitle
    self.acceptTitle = acceptTitle
    self.textNoun = textNoun
    self.allowsEditing = allowsEditing
    self.acceptOnReturn = acceptOnReturn
    self.onAccept = onAccept
    self.onCancel = onCancel
  }

  /// Title for the review window (used by the panel).
  var windowTitle: String {
    if let index = index, let total = total, total > 1 {
      return String(localized: "\(String(localized: titlePrefix)) – \(focusDisplayName) (\(index) of \(total))")
    }
    return String(localized: "\(String(localized: titlePrefix)) – \(focusDisplayName)")
  }

  private var diffLines: [SmartImprovementDiffLine] {
    collapseUnchangedDiffLines(
      computeSmartImprovementDiff(original: originalText, suggested: editedSuggestedText))
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

      if let section {
        SmartImprovementScorecardStrip(section: section)
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diffLines) { line in
              HStack(alignment: .top, spacing: 6) {
                Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                  .font(.system(.body, design: .monospaced))
                  .foregroundColor(line.kind == .added ? .green : line.kind == .removed ? .red : .secondary)
                Text(line.text.isEmpty ? " " : line.text)
                  .font(.system(.body, design: .monospaced))
                  .italic(line.kind == .skipped)
                  .foregroundColor(
                    line.kind == .added ? .green : line.kind == .removed ? .red
                      : line.kind == .skipped ? .secondary : .primary)
                  .strikethrough(line.kind == .removed)
                  .frame(maxWidth: .infinity, alignment: .topLeading)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 1)
              .background(line.kind == .added ? Color.green.opacity(0.10) : line.kind == .removed ? Color.red.opacity(0.10) : Color.clear)
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(6)
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

// MARK: - Modal presentation

/// Turns "the window closed" into "the user cancelled".
///
/// The panel is `.closable`, so the red button, Escape and ⌘W can all dismiss it without ever
/// running Accept or Cancel. Without this, `NSApp.stopModal()` is never called: the window is
/// gone but the modal session keeps spinning, and every other window in the app stops
/// responding while nothing is on screen to explain why. Reported 2026-08-19 after a Voice
/// Feedback proposal was dismissed instead of answered.
private final class ReviewPanelCloseObserver: NSObject, NSWindowDelegate {
  private let onClose: () -> Void
  init(onClose: @escaping () -> Void) { self.onClose = onClose }
  func windowWillClose(_ notification: Notification) { onClose() }
}

enum SmartImprovementReviewPanel {
  /// Presents the review UI in a modal panel. Returns the edited text if the user clicked Accept,
  /// nil if the user cancelled **or dismissed the window any other way**.
  static func present(
    focusDisplayName: String,
    index: Int? = nil,
    total: Int? = nil,
    originalText: String,
    suggestedText: String,
    rationale: String? = nil,
    section: SystemPromptSection? = nil
  ) async -> String? {
    await withCheckedContinuation { continuation in
      let resultLock = NSLock()
      var hasResumed = false
      func resumeOnce(returning value: String?) {
        resultLock.lock()
        defer { resultLock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume(returning: value)
      }

      DispatchQueue.main.async {
        let panel = NSPanel(
          contentRect: NSRect(x: 0, y: 0, width: 900, height: 820),
          styleMask: [.titled, .closable, .resizable],
          backing: .buffered,
          defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 820, height: 600)

        let view = SmartImprovementReviewView(
          focusDisplayName: focusDisplayName,
          index: index,
          total: total,
          originalText: originalText,
          suggestedText: suggestedText,
          rationale: rationale,
          section: section,
          onAccept: { text in
            resumeOnce(returning: text)
            NSApp.stopModal()
            panel.orderOut(nil)
          },
          onCancel: {
            resumeOnce(returning: nil)
            NSApp.stopModal()
            panel.orderOut(nil)
          }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.view.frame = NSRect(x: 0, y: 0, width: 900, height: 820)
        panel.title = view.windowTitle
        panel.contentViewController = hosting

        // Dismissing the window is a cancel, not a way to wedge the app. Held strongly for the
        // duration of the modal session — NSWindow.delegate is weak.
        let closeObserver = ReviewPanelCloseObserver {
          DebugLogger.log("REVIEW-PANEL: window dismissed without Accept/Cancel — treating as cancel")
          resumeOnce(returning: nil)
          NSApp.stopModal()
        }
        panel.delegate = closeObserver

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        // Detach before the final close, or `panel.close()` re-enters the observer and calls
        // stopModal on whatever modal session happens to be running next.
        panel.delegate = nil
        withExtendedLifetime(closeObserver) {}
        panel.close()

        // Belt and braces: if the panel went away without any path resuming the continuation,
        // an awaiting caller would hang forever. Resuming twice is a no-op by construction.
        resumeOnce(returning: nil)
      }
    }
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
