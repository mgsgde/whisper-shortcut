//
//  QuickActionStore.swift
//  WhisperShortcut
//
//  The few Dictate Prompt instructions the user actually repeats, so ⌘2 can run one
//  without speaking. Read from the interaction log off the main thread and cached;
//  the ⌘2 path only touches the cache.
//

import Foundation

struct QuickAction: Equatable, Identifiable {
  var id: String { key }
  /// Normalized grouping key. Not shown.
  let key: String
  /// What the list shows and what the model receives.
  let text: String
}

/// Top Dictate Prompt instructions from the last 30 days of interaction logs.
///
/// Learned entries come first. When logging is off, Offline Mode is on, or fewer than
/// three instructions clear the bar, the list is filled up to five with built-in defaults.
final class QuickActionStore {

  static let shared = QuickActionStore()

  static let lookbackDays = 30
  static let maxEntries = 5
  static let minimumCount = 2
  static let maxKeyLength = 60
  /// Below this many learned entries the built-in defaults fill the rest of the list.
  static let minimumLearnedToSkipDefaults = 3

  static let fallbackTexts = [
    "Fix grammar and spelling",
    "Rewrite more clearly",
    "Make it shorter",
    "Format as a to-do",
    "Translate to English",
  ]

  private static let fillerTokens: Set<String> = ["ähm", "äh", "ehm", "um", "uh"]
  private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:")

  private let cacheLock = NSLock()
  private var cached: [QuickAction]

  private init() {
    cached = Self.padding([])
  }

  /// Cache only. Safe on the ⌘2 path — never reads the log.
  func current() -> [QuickAction] {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return cached
  }

  /// Re-reads the interaction log and replaces the cache. Call off the main thread.
  func refresh() {
    let instructions = Self.promptInstructions(lastDays: Self.lookbackDays)
    let forceFallback = !ContextLoggingPreference.isEnabled || OfflineMode.isEnabled
    let actions = Self.ranked(from: instructions, forceFallback: forceFallback)
    cacheLock.lock()
    cached = actions
    cacheLock.unlock()
    DebugLogger.log(
      "QUICK-ACTIONS: Cached \(actions.count) entries from \(instructions.count) prompt logs")
  }

  /// Groups prompt instructions and, when asked or when fewer than three qualify, pads
  /// with the built-in defaults. Learned entries stay in front.
  static func ranked(from instructions: [String], forceFallback: Bool) -> [QuickAction] {
    let learned = rankLearned(from: instructions)
    let fill = forceFallback || learned.count < minimumLearnedToSkipDefaults
    guard fill else { return learned }
    return padding(learned)
  }

  // MARK: - Ranking

  private static func rankLearned(from instructions: [String]) -> [QuickAction] {
    let placeholder = normalizeKey(SpeechService.voiceInstructionPlaceholder)
    var buckets: [String: Bucket] = [:]

    for (index, raw) in instructions.enumerated() {
      let key = normalizeKey(raw)
      if key.isEmpty || key.count > maxKeyLength || key == placeholder { continue }
      var bucket = buckets[key] ?? Bucket(firstIndex: index)
      bucket.count += 1
      let spelling = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if bucket.spellingCounts[spelling] == nil {
        bucket.spellingOrder.append(spelling)
      }
      bucket.spellingCounts[spelling, default: 0] += 1
      buckets[key] = bucket
    }

    let ordered = buckets
      .filter { $0.value.count >= minimumCount }
      .sorted { lhs, rhs in
        if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
        return lhs.value.firstIndex < rhs.value.firstIndex
      }
      .prefix(maxEntries)

    return ordered.map { key, bucket in
      QuickAction(key: key, text: displayText(from: bucket.winningSpelling))
    }
  }

  private static func padding(_ learned: [QuickAction]) -> [QuickAction] {
    var result = learned
    var seen = Set(learned.map(\.key))
    for text in fallbackTexts {
      if result.count >= maxEntries { break }
      let key = normalizeKey(text)
      if key.isEmpty || seen.contains(key) { continue }
      seen.insert(key)
      result.append(QuickAction(key: key, text: text))
    }
    return result
  }

  /// Lowercase, trim, strip leading/trailing punctuation, drop filler tokens, collapse whitespace.
  static func normalizeKey(_ raw: String) -> String {
    let stripped = stripEdgePunctuation(
      raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    let tokens = stripped.split(whereSeparator: { $0.isWhitespace }).compactMap { token -> String? in
      let cleaned = stripEdgePunctuation(String(token))
      if cleaned.isEmpty || fillerTokens.contains(cleaned) { return nil }
      return cleaned
    }
    return tokens.joined(separator: " ")
  }

  /// Most-frequent raw spelling, trimmed, one trailing period removed, first letter uppercased.
  static func displayText(from spelling: String) -> String {
    var text = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasSuffix(".") {
      text.removeLast()
      text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let first = text.first else { return text }
    return String(first).uppercased() + text.dropFirst()
  }

  private static func stripEdgePunctuation(_ value: String) -> String {
    var text = value
    while let last = text.unicodeScalars.last, edgePunctuation.contains(last) {
      text.unicodeScalars.removeLast()
    }
    while let first = text.unicodeScalars.first, edgePunctuation.contains(first) {
      text.unicodeScalars.removeFirst()
    }
    return text
  }

  private static func promptInstructions(lastDays: Int) -> [String] {
    let decoder = JSONDecoder()
    var instructions: [String] = []
    for fileURL in ContextLogger.shared.interactionLogFiles(lastDays: lastDays) {
      guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
      for line in content.split(whereSeparator: \.isNewline) {
        guard let entry = try? decoder.decode(InteractionLogEntry.self, from: Data(line.utf8)),
          entry.mode == "prompt",
          let userInstruction = entry.userInstruction
        else { continue }
        instructions.append(userInstruction)
      }
    }
    return instructions
  }

  private struct Bucket {
    var count = 0
    var firstIndex: Int
    var spellingOrder: [String] = []
    var spellingCounts: [String: Int] = [:]

    var winningSpelling: String {
      var best = spellingOrder.first ?? ""
      var bestCount = 0
      for spelling in spellingOrder {
        let seen = spellingCounts[spelling] ?? 0
        if seen > bestCount {
          best = spelling
          bestCount = seen
        }
      }
      return best
    }
  }
}
