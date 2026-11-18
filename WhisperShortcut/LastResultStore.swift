//
//  LastResultStore.swift
//  WhisperShortcut
//
//  The last Prompt Mode answer and the last Read Aloud, for "Report a Problem".
//

import Foundation

/// The last Prompt Mode answer and the last Read Aloud.
///
/// In memory only, never written to disk. A Prompt selection or a text that was read aloud in a
/// practice can be a patient note. This exists only so the user can report that result; it is
/// gone when the app quits.
final class LastResultStore {

  static let shared = LastResultStore()

  struct PromptResult: Equatable {
    let ts: Date
    let instruction: String
    let selectedText: String?
    let response: String
    let model: String?
    let provider: String?
    let hadScreenshot: Bool
  }

  struct ReadAloudResult: Equatable {
    let ts: Date
    let text: String
    let model: String?
    let voice: String?
  }

  /// Selected text kept for a report. Longer text is the first 600 characters plus "…".
  private static let selectedTextCap = 600
  /// Answer and read-aloud text kept for a report. Longer text is the first 2,000 characters plus "…".
  private static let bodyCap = 2_000

  private let queue = DispatchQueue(label: "com.whisper-shortcut.lastresult")
  private var promptStorage: PromptResult?
  private var readAloudStorage: ReadAloudResult?

  /// Internal so tests can use a fresh store. The app uses `shared`.
  init() {}

  var lastPrompt: PromptResult? {
    queue.sync { promptStorage }
  }

  var lastReadAloud: ReadAloudResult? {
    queue.sync { readAloudStorage }
  }

  /// Records a Prompt answer. An empty response (whitespace only) is ignored.
  func recordPrompt(_ result: PromptResult) {
    guard !result.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let stored = PromptResult(
      ts: result.ts,
      instruction: result.instruction,
      selectedText: result.selectedText.map { Self.cap($0, limit: Self.selectedTextCap) },
      response: Self.cap(result.response, limit: Self.bodyCap),
      model: result.model,
      provider: result.provider,
      hadScreenshot: result.hadScreenshot)
    queue.sync { promptStorage = stored }
  }

  /// Records a Read Aloud. Empty text (whitespace only) is ignored.
  func recordReadAloud(_ result: ReadAloudResult) {
    guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let stored = ReadAloudResult(
      ts: result.ts,
      text: Self.cap(result.text, limit: Self.bodyCap),
      model: result.model,
      voice: result.voice)
    queue.sync { readAloudStorage = stored }
  }

  func clear() {
    queue.sync {
      promptStorage = nil
      readAloudStorage = nil
    }
  }

  private static func cap(_ text: String, limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit)) + "…" : text
  }
}
