//
//  WritingStyleStore.swift
//  WhisperShortcut
//
//  The user's writing style: a small editable profile per context plus a pool of messages the
//  user really wrote. Dictate Prompt appends `promptBlock(for:incoming:maxChars:)` to its system
//  prompt so drafts are written from real examples instead of adjectives.
//  See plans/active/writing-style.md.
//
//  Everything stays under UserContext/writing-style/ and is never logged: log lines carry counts
//  and bucket names only, never message text or recipients.
//

import Foundation

struct WritingSample: Codable, Equatable {
  let id: String
  let context: WritingContext
  /// "gmail" or "manual".
  let source: String
  let recipient: String?
  let sentAt: Date
  /// Length of the message this one replied to, when known. Drives the reply-length target.
  let incomingChars: Int?
  let text: String
}

final class WritingStyleStore {

  static let shared = WritingStyleStore(
    directory: AppSupportPaths.userContextURL().appendingPathComponent("writing-style"),
    isEnabled: { UserDefaults.standard.bool(forKey: UserDefaultsKeys.writingStyleEnabled) })

  /// Newest samples win beyond this, so the file stays small and retrieval stays cheap.
  static let maxSamplesPerContext = 500
  static let examplesPerPrompt = 5
  static let maxExampleChars = 800
  /// Prompt budget. Local models get no block at all: a 4B model follows the examples even when
  /// the instruction is to translate or correct, so the style would leak into those results.
  static let maxChars = 4_000

  let directory: URL
  private let isEnabled: () -> Bool
  private let lock = NSLock()

  init(directory: URL, isEnabled: @escaping () -> Bool) {
    self.directory = directory
    self.isEnabled = isEnabled
  }

  var profileURL: URL { directory.appendingPathComponent("profile.md") }
  private var samplesURL: URL { directory.appendingPathComponent("samples.jsonl") }

  static var emptyProfile: String {
    WritingContext.allCases.map { "\($0.profileHeader)\n" }.joined(separator: "\n")
  }

  // MARK: - Profile

  func loadProfile() -> String {
    lock.lock()
    defer { lock.unlock() }
    return (try? String(contentsOf: profileURL, encoding: .utf8)) ?? ""
  }

  func saveProfile(_ text: String) {
    lock.lock()
    defer { lock.unlock() }
    AppSupportPaths.ensureDirectoryExists(directory)
    do {
      try text.write(to: profileURL, atomically: true, encoding: .utf8)
    } catch {
      DebugLogger.logError("WRITING-STYLE: Could not save profile: \(error.localizedDescription)")
    }
  }

  /// Creates the profile with empty section headers if it does not exist yet, so the user has
  /// something to fill in when opening it from Settings.
  func ensureProfileFileExists() {
    guard !FileManager.default.fileExists(atPath: profileURL.path) else { return }
    saveProfile(Self.emptyProfile)
  }

  func profileSection(for context: WritingContext) -> String {
    Self.profileSection(in: loadProfile(), for: context)
  }

  /// Text under `context`'s header up to the next `=== ` header, trimmed.
  static func profileSection(in profile: String, for context: WritingContext) -> String {
    var collecting = false
    var lines: [String] = []
    for line in profile.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("=== ") {
        if collecting { break }
        collecting = trimmed == context.profileHeader
        continue
      }
      if collecting { lines.append(line) }
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - Samples

  func loadSamples() -> [WritingSample] {
    lock.lock()
    defer { lock.unlock() }
    return readSamplesUnlocked()
  }

  /// Adds samples, skipping duplicates by id and by identical text. Returns how many were added.
  @discardableResult
  func addSamples(_ new: [WritingSample]) -> Int {
    lock.lock()
    defer { lock.unlock() }
    var samples = readSamplesUnlocked()
    var ids = Set(samples.map(\.id))
    var texts = Set(samples.map { Self.normalized($0.text) })
    var added = 0
    for sample in new {
      let key = Self.normalized(sample.text)
      guard !key.isEmpty, !ids.contains(sample.id), !texts.contains(key) else { continue }
      samples.append(sample)
      ids.insert(sample.id)
      texts.insert(key)
      added += 1
    }
    var capped: [WritingSample] = []
    for context in WritingContext.allCases {
      let inContext = samples.filter { $0.context == context }.sorted { $0.sentAt > $1.sentAt }
      capped.append(contentsOf: inContext.prefix(Self.maxSamplesPerContext))
    }
    writeSamplesUnlocked(capped)
    return added
  }

  func sampleCounts() -> [WritingContext: Int] {
    Dictionary(grouping: loadSamples(), by: \.context).mapValues(\.count)
  }

  func clearAll() {
    lock.lock()
    defer { lock.unlock() }
    try? FileManager.default.removeItem(at: directory)
  }

  private func readSamplesUnlocked() -> [WritingSample] {
    guard let content = try? String(contentsOf: samplesURL, encoding: .utf8) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return content.split(separator: "\n").compactMap {
      try? decoder.decode(WritingSample.self, from: Data($0.utf8))
    }
  }

  private func writeSamplesUnlocked(_ samples: [WritingSample]) {
    AppSupportPaths.ensureDirectoryExists(directory)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let lines = samples.compactMap { sample -> String? in
      guard let data = try? encoder.encode(sample) else { return nil }
      return String(data: data, encoding: .utf8)
    }
    do {
      try (lines.joined(separator: "\n") + "\n").write(to: samplesURL, atomically: true, encoding: .utf8)
    } catch {
      DebugLogger.logError("WRITING-STYLE: Could not save samples: \(error.localizedDescription)")
    }
  }

  private static func normalized(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  // MARK: - Prompt Block

  struct PromptBlock {
    let text: String
    /// The context actually used — `.defaultContext` when the requested one had nothing learned.
    let context: WritingContext
    let exampleCount: Int
  }

  /// The block for the Dictate Prompt system prompt, or nil when the feature is off or there is
  /// nothing learned for this context (nor for the default context).
  func promptBlock(for context: WritingContext, incoming: String?, maxChars: Int) -> PromptBlock? {
    guard isEnabled() else { return nil }
    let profile = loadProfile()
    let all = loadSamples()

    var effective = context
    var section = Self.profileSection(in: profile, for: context)
    var samples = all.filter { $0.context == context }
    if section.isEmpty && samples.isEmpty && context != .defaultContext {
      effective = .defaultContext
      section = Self.profileSection(in: profile, for: .defaultContext)
      samples = all.filter { $0.context == .defaultContext }
    }
    guard !section.isEmpty || !samples.isEmpty else { return nil }

    let target = Self.targetWords(samples: samples, incoming: incoming)
    let examples = Self.pickExamples(from: samples, targetWords: target)
    let rendered = Self.renderBlock(
      context: effective, profileSection: section, targetWords: target,
      examples: examples.map(\.text), maxChars: maxChars)
    return PromptBlock(text: rendered.text, context: effective, exampleCount: rendered.exampleCount)
  }

  static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
  }

  private static func median<T: Comparable>(_ values: [T]) -> T? {
    guard !values.isEmpty else { return nil }
    return values.sorted()[values.count / 2]
  }

  /// Expected reply length in words: the user's typical reply-to-incoming ratio applied to the
  /// incoming text, clamped around their median, so a long email does not produce an essay.
  static func targetWords(samples: [WritingSample], incoming: String?) -> Int? {
    guard let medianWords = median(samples.map { wordCount($0.text) }), medianWords > 0 else {
      return nil
    }
    let ratios = samples.compactMap { sample -> Double? in
      guard let incomingChars = sample.incomingChars, incomingChars > 0 else { return nil }
      return Double(sample.text.count) / Double(incomingChars)
    }
    guard let ratio = median(ratios), let incoming else { return medianWords }
    let incomingWords = wordCount(incoming)
    guard incomingWords > 0 else { return medianWords }
    let estimate = Int((Double(incomingWords) * ratio).rounded())
    return min(max(estimate, max(1, medianWords / 2)), medianWords * 2)
  }

  /// Recency plus closeness to the target length, at most two examples per recipient so one
  /// busy thread does not define the voice.
  static func pickExamples(from samples: [WritingSample], targetWords: Int?) -> [WritingSample] {
    let newestFirst = samples.sorted { $0.sentAt > $1.sentAt }
    let count = Double(max(newestFirst.count, 1))
    let scored = newestFirst.enumerated().map { index, sample -> (WritingSample, Double) in
      let recency = 1 - Double(index) / count
      var lengthFit = 0.5
      if let targetWords, targetWords > 0 {
        let diff = abs(Double(wordCount(sample.text) - targetWords)) / Double(targetWords)
        lengthFit = 1 - min(1, diff)
      }
      return (sample, recency + lengthFit)
    }
    var picked: [WritingSample] = []
    var perRecipient: [String: Int] = [:]
    for (sample, _) in scored.sorted(by: { $0.1 > $1.1 }) {
      if let recipient = sample.recipient {
        guard perRecipient[recipient, default: 0] < 2 else { continue }
        perRecipient[recipient, default: 0] += 1
      }
      picked.append(sample)
      if picked.count == examplesPerPrompt { break }
    }
    return picked
  }

  /// Examples are dropped from the end before the profile is ever cut.
  static func renderBlock(
    context: WritingContext, profileSection: String, targetWords: Int?,
    examples: [String], maxChars: Int
  ) -> (text: String, exampleCount: Int) {
    var block = """
      === Writing style of the user ===
      Apply this section only when you compose a message the user will send as themselves (a reply, a new email or message). When the instruction is to translate, summarize, correct or otherwise transform existing text, ignore this section.
      Write the way the examples below are written: same greeting and closing habits, same register, same sentence length, same punctuation. Never add phrases or punctuation the user does not use.
      """
    if let targetWords {
      block += " Aim for about \(targetWords) words unless the instruction says otherwise."
    }
    if !profileSection.isEmpty {
      block += "\n\nProfile (\(context.displayName)):\n\(profileSection)"
    }
    guard !examples.isEmpty else { return (block, 0) }

    let header = "\n\nExamples of messages the user wrote (context: \(context.displayName)). They show voice only; do not copy their content:"
    var body = ""
    var count = 0
    for (index, example) in examples.enumerated() {
      var text = example.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.count > maxExampleChars { text = String(text.prefix(maxExampleChars)) + "…" }
      let part = "\n--- example \(index + 1) ---\n\(text)"
      guard block.count + header.count + body.count + part.count <= maxChars else { break }
      body += part
      count += 1
    }
    return body.isEmpty ? (block, 0) : (block + header + body, count)
  }
}
