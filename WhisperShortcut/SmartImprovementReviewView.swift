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
  enum Kind { case unchanged, removed, added }
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

struct SmartImprovementReviewView: View {
  let focusDisplayName: String
  let index: Int?
  let total: Int?
  let originalText: String
  let rationale: String?
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
    onAccept: @escaping (String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.focusDisplayName = focusDisplayName
    self.index = index
    self.total = total
    self.originalText = originalText
    self._editedSuggestedText = State(initialValue: suggestedText)
    self.rationale = rationale
    self.onAccept = onAccept
    self.onCancel = onCancel
  }

  /// Title for the review window (used by the panel).
  var windowTitle: String {
    if let index = index, let total = total, total > 1 {
      return "Smart Improvement – \(focusDisplayName) (\(index) of \(total))"
    }
    return "Smart Improvement – \(focusDisplayName)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(windowTitle)
        .font(.headline)
        .padding(.bottom, 4)

      if let rationale = rationale, !rationale.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("Why this change")
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
          ScrollView(.vertical, showsIndicators: true) {
            Text(rationale)
              .font(.system(.body))
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
              .padding(8)
          }
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(6)
          .frame(minHeight: 60, maxHeight: 140)
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Diff (current → suggested)")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        ScrollView(.vertical, showsIndicators: true) {
          let lines = computeSmartImprovementDiff(original: originalText, suggested: editedSuggestedText)
          VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
              HStack(alignment: .top, spacing: 6) {
                Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                  .font(.system(.body, design: .monospaced))
                  .foregroundColor(line.kind == .added ? .green : line.kind == .removed ? .red : .secondary)
                Text(line.text.isEmpty ? " " : line.text)
                  .font(.system(.body, design: .monospaced))
                  .foregroundColor(line.kind == .added ? .green : line.kind == .removed ? .red : .primary)
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
        }
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(6)
        .frame(minHeight: 180, maxHeight: 320)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Current prompt")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        ScrollView(.vertical, showsIndicators: true) {
          Text(originalText)
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(6)
        .frame(minHeight: 200, maxHeight: 320)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Suggested prompt (editable)")
          .font(.subheadline)
          .fontWeight(.medium)
          .foregroundColor(.secondary)
        TextEditor(text: $editedSuggestedText)
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .background(Color(nsColor: .textBackgroundColor))
          .cornerRadius(6)
          .frame(minHeight: 200, maxHeight: 320)
      }

      HStack(spacing: 12) {
        Button("Cancel") {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)
        .pointerCursorOnHover()

        Spacer()

        Button("Accept") {
          onAccept(editedSuggestedText)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .pointerCursorOnHover()
      }
      .padding(.top, 8)
    }
    .padding(24)
    .frame(minWidth: 780, minHeight: 720)
  }
}

// MARK: - Modal presentation

enum SmartImprovementReviewPanel {
  /// Presents the review UI in a modal panel. Returns the edited text if the user clicked Accept, nil if Cancel.
  static func present(
    focusDisplayName: String,
    index: Int? = nil,
    total: Int? = nil,
    originalText: String,
    suggestedText: String,
    rationale: String? = nil
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
          contentRect: NSRect(x: 0, y: 0, width: 820, height: 760),
          styleMask: [.titled, .closable, .resizable],
          backing: .buffered,
          defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 720, height: 560)

        let view = SmartImprovementReviewView(
          focusDisplayName: focusDisplayName,
          index: index,
          total: total,
          originalText: originalText,
          suggestedText: suggestedText,
          rationale: rationale,
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
        hosting.view.frame = NSRect(x: 0, y: 0, width: 820, height: 760)
        panel.title = view.windowTitle
        panel.contentViewController = hosting

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.close()
      }
    }
  }
}
