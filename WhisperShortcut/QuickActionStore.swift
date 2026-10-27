//
//  QuickActionStore.swift
//  WhisperShortcut
//
//  The few Dictate Prompt instructions the user actually repeats, so ⌘2 can run one
//  without speaking. Read from the interaction log off the main thread and cached;
//  the ⌘2 path only touches the cache.
//

import Foundation

/// Coarse intent of a Dictate Prompt instruction, derived from its normalized key.
/// Drives the SF Symbol shown in front of an entry and cross-language de-duplication.
enum QuickActionKind: Equatable {
  case correct, rewrite, shorten, format, translate, other

  /// SF Symbol shown in front of the entry.
  var symbolName: String {
    switch self {
    case .correct: return "checkmark.circle"
    case .rewrite: return "pencil"
    case .shorten: return "arrow.down.right.and.arrow.up.left"
    case .format: return "list.bullet"
    case .translate: return "globe"
    case .other: return "text.bubble"
    }
  }

  /// Classifies a normalized key (output of `QuickActionStore.normalizeKey`) by substring
  /// match, first match wins. Order matters: shorten is checked before format before correct
  /// before rewrite, so e.g. "formatiere neu" doesn't fall through to rewrite and
  /// "formuliere neu kürzer" lands on shorten, not rewrite.
  static func classify(_ key: String) -> QuickActionKind {
    let lowered = key.lowercased()

    let shortenTokens = ["kürz", "kurz", "short", "concise", "condense", "raccourc", "acorta"]
    if shortenTokens.contains(where: lowered.contains) { return .shorten }

    let translateTokens = ["übersetz", "translat", "tradui", "tradu"]
    if translateTokens.contains(where: lowered.contains) { return .translate }

    let formatTokens = [
      "format", "to-do", "todo", "bullet", "aufzähl", "markdown", "tabelle", "table",
    ]
    if formatTokens.contains(where: lowered.contains) { return .format }

    let correctTokens = [
      "korrig", "corrig", "correct", "fix", "grammat", "grammar", "rechtschreib", "spelling",
      "tippfehler", "typo", "proofread",
    ]
    if correctTokens.contains(where: lowered.contains) { return .correct }

    let rewriteTokens = [
      "formulier", "rewrite", "rephrase", "reword", "umschreib", "reformul", "klarer", "clearer",
    ]
    if rewriteTokens.contains(where: lowered.contains) { return .rewrite }

    return .other
  }
}

struct QuickAction: Equatable, Identifiable {
  var id: String { key }
  /// Normalized grouping key. Not shown.
  let key: String
  /// What the list shows and what the model receives.
  let text: String
  /// Derived from `key`; drives the icon and de-duplication.
  var kind: QuickActionKind { QuickActionKind.classify(key) }
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

  /// Groups prompt instructions, drops same-kind single-word duplicates across languages
  /// (e.g. "Korrigiere" / "Corriger"), and, when asked or when fewer than three qualify,
  /// pads with the built-in defaults. Learned entries stay in front.
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

    let sorted = buckets
      .filter { $0.value.count >= minimumCount }
      .sorted { lhs, rhs in
        if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
        return lhs.value.firstIndex < rhs.value.firstIndex
      }
      .map { key, bucket in
        QuickAction(key: key, text: displayText(from: bucket.winningSpelling))
      }

    // Drop single-word entries whose kind duplicates an earlier, also single-word entry
    // (e.g. "korrigiere" and "corriger" are the same intent in two languages). Multi-word
    // entries are kept even when their kind repeats, since they carry more specific intent
    // (e.g. "formuliere neu" and "formuliere neu kürzer" both survive). Done before
    // `.prefix(maxEntries)` so the list still fills up to five.
    var keptSingleWordKinds: Set<QuickActionKind> = []
    var deduped: [QuickAction] = []
    for action in sorted {
      let isSingleWord = !action.key.contains(" ")
      if action.kind != .other, isSingleWord, keptSingleWordKinds.contains(action.kind) {
        continue
      }
      if action.kind != .other, isSingleWord {
        keptSingleWordKinds.insert(action.kind)
      }
      deduped.append(action)
    }

    return Array(deduped.prefix(maxEntries))
  }

  /// Fills the list up to `maxEntries` with built-in defaults, skipping a default whose key
  /// already appears and a default whose kind (other than `.other`) a learned entry already
  /// covers (e.g. learned "Korrigiere" skips the "Fix grammar and spelling" fallback).
  private static func padding(_ learned: [QuickAction]) -> [QuickAction] {
    var result = learned
    var seen = Set(learned.map(\.key))
    var seenKinds = Set(learned.map(\.kind).filter { $0 != .other })
    for text in fallbackTexts {
      if result.count >= maxEntries { break }
      let key = normalizeKey(text)
      if key.isEmpty || seen.contains(key) { continue }
      let kind = QuickActionKind.classify(key)
      if kind != .other, seenKinds.contains(kind) { continue }
      seen.insert(key)
      if kind != .other { seenKinds.insert(kind) }
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
    UserContextLog.interactions(lastDays: lastDays, mode: .prompt).compactMap(\.userInstruction)
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
