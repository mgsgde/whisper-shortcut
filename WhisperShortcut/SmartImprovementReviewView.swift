//
//  SmartImprovementReviewView.swift
//  WhisperShortcut
//
//  Review UI for Smart Improvement: compare original prompt (read-only) with suggested prompt (editable), Accept or Cancel.
//

import AppKit
import SwiftUI

// MARK: - SwiftUI View

struct SmartImprovementReviewView: View {
  let focusDisplayName: String
  let index: Int?
  let total: Int?
  let originalText: String
  @State private var editedSuggestedText: String
  let onAccept: (String) -> Void
  let onCancel: () -> Void

  init(
    focusDisplayName: String,
    index: Int? = nil,
    total: Int? = nil,
    originalText: String,
    suggestedText: String,
    onAccept: @escaping (String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.focusDisplayName = focusDisplayName
    self.index = index
    self.total = total
    self.originalText = originalText
    self._editedSuggestedText = State(initialValue: suggestedText)
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
    suggestedText: String
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
