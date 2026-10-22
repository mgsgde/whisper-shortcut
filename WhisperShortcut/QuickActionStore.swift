//
//  QuickActionStore.swift
//  WhisperShortcut
//
//  Dictate Prompt quick actions for ⌘2: the user's own prompts, then ones learned from
//  the interaction log. The log is read off the main thread and cached; the ⌘2 path
//  only touches the cache and UserDefaults.
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

/// Dictate Prompt quick actions for ⌘2.
///
/// The user's own prompts come first (Settings → Dictate Prompt), then ones learned
/// from the last 30 days of interaction logs. Built-in defaults fill the list only when
/// the user has none of their own: when logging is off, Offline Mode is on, or fewer
/// than three learned instructions clear the bar.
final class QuickActionStore {

  static let shared = QuickActionStore()

  static let lookbackDays = 30
  static let maxEntries = 5
  /// ⌃1–9 picks an entry, so the card never shows more than this many.
  static let maxCustomEntries = 9
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
  /// Learned entries only, no built-in defaults. Combined with the user's prompts in `current()`.
  private var cachedLearned: [QuickAction]
  private var cachedForceFallback: Bool

  private init() {
    cachedLearned = []
    cachedForceFallback = false
  }

  /// Cache and UserDefaults only. Safe on the ⌘2 path — never reads the log.
  func current() -> [QuickAction] {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return Self.combined(
      custom: Self.storedCustomTexts(),
      learned: cachedLearned,
      forceFallback: cachedForceFallback,
      includeLearned: Self.learnedEnabled)
  }

  /// Re-reads the interaction log and replaces the cached learned list. Call off the main thread.
  func refresh() {
    let instructions = Self.promptInstructions(lastDays: Self.lookbackDays)
    let forceFallback = !ContextLoggingPreference.isEnabled || OfflineMode.isEnabled
    let learned = Self.rankLearned(from: instructions)
    cacheLock.lock()
    cachedLearned = learned
    cachedForceFallback = forceFallback
    cacheLock.unlock()
    DebugLogger.log(
      "QUICK-ACTIONS: Cached \(learned.count) entries from \(instructions.count) prompt logs")
  }

  /// Also show prompts learned from usage. Unset → true.
  static var learnedEnabled: Bool {
    UserDefaults.standard.object(
      forKey: UserDefaultsKeys.dictatePromptLearnedQuickActionsEnabled) as? Bool ?? true
  }

  /// The user's own quick prompts in display order. May include blanks still being edited.
  static func storedCustomTexts() -> [String] {
    UserDefaults.standard.stringArray(forKey: UserDefaultsKeys.dictatePromptCustomQuickActions) ?? []
  }

  /// Groups prompt instructions, drops same-kind single-word duplicates across languages
  /// (e.g. "Korrigiere" / "Corriger"), and, when asked or when fewer than three qualify,
  /// pads with the built-in defaults. Learned entries stay in front.
  static func ranked(from instructions: [String], forceFallback: Bool) -> [QuickAction] {
    applyingFallback(to: rankLearned(from: instructions), forceFallback: forceFallback)
  }

  /// Learned entries, padded with built-in defaults when asked or when fewer than
  /// `minimumLearnedToSkipDefaults` qualify.
  private static func applyingFallback(
    to learned: [QuickAction], forceFallback: Bool
  ) -> [QuickAction] {
    let fill = forceFallback || learned.count < minimumLearnedToSkipDefaults
    guard fill else { return learned }
    return padding(learned)
  }

  /// Own prompts first (trimmed, blanks and duplicate keys dropped, capped at
  /// `maxCustomEntries`), then learned entries whose key is not already present.
  /// With no own prompts, learning on returns the same list as `ranked`; learning off
  /// returns nothing. Built-in defaults are never appended once the user has prompts
  /// of their own.
  static func combined(
    custom: [String], learned: [QuickAction], forceFallback: Bool, includeLearned: Bool
  ) -> [QuickAction] {
    let own = customActions(from: custom)
    if own.isEmpty {
      guard includeLearned else { return [] }
      return applyingFallback(to: learned, forceFallback: forceFallback)
    }
    guard includeLearned else { return own }
    var result = own
    var seen = Set(own.map(\.key))
    for action in learned {
      if result.count >= maxCustomEntries { break }
      if seen.contains(action.key) { continue }
      seen.insert(action.key)
      result.append(action)
    }
    return result
  }

  /// Trimmed custom prompts in order. Blanks, empty keys, and later duplicate keys are
  /// dropped; text is kept as typed.
  private static func customActions(from texts: [String]) -> [QuickAction] {
    var result: [QuickAction] = []
    var seen: Set<String> = []
    for raw in texts {
      if result.count >= maxCustomEntries { break }
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty { continue }
      let key = normalizeKey(text)
      if key.isEmpty || seen.contains(key) { continue }
      seen.insert(key)
      result.append(QuickAction(key: key, text: text))
    }
    return result
  }

  // MARK: - Ranking

  /// Groups prompt instructions and drops same-kind single-word duplicates across
  /// languages. No built-in defaults; `ranked` adds those.
  static func rankLearned(from instructions: [String]) -> [QuickAction] {
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
