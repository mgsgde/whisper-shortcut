//
//  QuickActionStore.swift
//  WhisperShortcut
//
//  Dictate Prompt quick actions for ⌘2: the three most-used prompts from the last 30
//  days. Own prompts and learned ones are ranked together, and own prompts win ties.
//  The log is read off the main thread and cached; the ⌘2 path only touches the cache
//  and UserDefaults.
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
    // Whole-word matching (R217): a token must start a word, so "information" is not "format"
    // and "comfortable" is not "table". Tokens are stems ("kürz" → "kürzer"), so the word may
    // continue — except for the few words that merely begin with a token.
    let words = lowered
      .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "-") })
      .map(String.init)
    let notVerbs = ["shortcut", "shortage", "tablet", "fixture", "bulletin", "formation"]
    func hasToken(_ tokens: [String]) -> Bool {
      words.contains { word in
        !notVerbs.contains(where: { word.hasPrefix($0) }) && tokens.contains(where: { word.hasPrefix($0) })
      }
    }

    let shortenTokens = ["kürz", "kurz", "short", "concise", "condense", "raccourc", "acorta"]
    if hasToken(shortenTokens) { return .shorten }

    let translateTokens = ["übersetz", "translat", "tradui", "tradu"]
    if hasToken(translateTokens) { return .translate }

    let formatTokens = [
      "format", "to-do", "todo", "bullet", "aufzähl", "markdown", "tabelle", "table",
    ]
    if hasToken(formatTokens) { return .format }

    let correctTokens = [
      "korrig", "corrig", "correct", "fix", "grammat", "grammar", "rechtschreib", "spelling",
      "tippfehler", "typo", "proofread",
    ]
    if hasToken(correctTokens) { return .correct }

    let rewriteTokens = [
      "formulier", "rewrite", "rephrase", "reword", "umschreib", "reformul", "klarer", "clearer",
    ]
    if hasToken(rewriteTokens) { return .rewrite }

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
  /// True for the built-in defaults (`QuickActionStore.fallbackTexts`) only.
  var isBuiltIn = false
  /// Needs a selection to act on: a built-in default, or text that is only an edit verb
  /// ("Korrigiere") — the same rule `refusesEditWithoutSelection` applies. `kind` is a substring
  /// guess that drives the icon, so it must not decide that "Write a short reply" is an edit.
  var isEdit: Bool { isBuiltIn || DictatePromptSelectionDecision.isBareEditCommand(text) }
}

/// Dictate Prompt quick actions for ⌘2.
///
/// The card shows the three most-used prompts from the last 30 days. Own prompts and
/// ones learned from the interaction log are ranked together; when the number of uses
/// ties, own prompts win and keep their order. Built-in defaults fill the list only when
/// the user has none of their own: when logging is off, Offline Mode is on, or fewer
/// than three learned instructions clear the bar.
final class QuickActionStore {

  static let shared = QuickActionStore()

  static let lookbackDays = 30
  static let maxEntries = 5
  /// Own prompts kept in Settings. The ⌘2 card shows the `cardEntries` most-used of them.
  static let maxCustomEntries = 9
  /// How many of the most-used prompts the ⌘2 card shows above the text field. Own prompts win ties.
  static let cardEntries = 3
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
  /// Normalized key → uses in the last `lookbackDays`. Every key, including a single use.
  private var cachedCounts: [String: Int]

  private init() {
    cachedLearned = []
    cachedForceFallback = false
    cachedCounts = [:]
  }

  /// Cache and UserDefaults only. Safe on the ⌘2 path — never reads the log.
  func current() -> [QuickAction] {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return Self.combined(
      custom: Self.storedCustomTexts(),
      learned: cachedLearned,
      forceFallback: cachedForceFallback,
      includeLearned: Self.learnedEnabled,
      counts: cachedCounts)
  }

  /// What the ⌘2 card lists, and which entry it opens on. Cache and UserDefaults only.
  func forCard() -> (actions: [QuickAction], preselectIndex: Int?) {
    Self.card(
      custom: Self.storedCustomTexts(), recent: Self.storedRecentTexts(), ranked: current(),
      preselect: Self.preselectsRecent)
  }

  /// With prompts of the user's own, the card lists the three most-used prompts in `ranked`
  /// (own prompts win ties) and shows `cardEntries` rows. The last one run is highlighted
  /// where it stands when that prompt is still on the card.
  /// Without, it lists the last instructions run first (`cardList`) and highlights the first.
  static func card(
    custom: [String], recent: [String], ranked: [QuickAction], preselect: Bool
  ) -> (actions: [QuickAction], preselectIndex: Int?) {
    guard !customActions(from: custom).isEmpty else {
      let list = cardList(recent: recent, ranked: ranked)
      return (list, preselect && !list.isEmpty ? 0 : nil)
    }
    let list = Array(ranked.prefix(cardEntries))
    guard preselect, let last = recent.first else { return (list, nil) }
    let key = normalizeKey(last.trimmingCharacters(in: .whitespacesAndNewlines))
    return (list, list.firstIndex { $0.key == key })
  }

  /// Recent texts first (an entry that also ranks keeps its flags, so a built-in default stays
  /// an edit), then ranked entries not already listed, capped at `cardEntries`.
  static func cardList(recent: [String], ranked: [QuickAction]) -> [QuickAction] {
    var result: [QuickAction] = []
    var seen: Set<String> = []
    let rankedByKey = Dictionary(ranked.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    for raw in recent {
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      let key = normalizeKey(text)
      if key.isEmpty || seen.contains(key) { continue }
      seen.insert(key)
      result.append(rankedByKey[key] ?? QuickAction(key: key, text: text))
    }
    for action in ranked where !seen.contains(action.key) {
      seen.insert(action.key)
      result.append(action)
    }
    return Array(result.prefix(cardEntries))
  }

  /// Instructions last run from the card, most recent first.
  static func storedRecentTexts() -> [String] {
    UserDefaults.standard.stringArray(forKey: UserDefaultsKeys.dictatePromptRecentQuickActions) ?? []
  }

  /// Whether the card opens on its first entry: the last run picked an entry.
  static var preselectsRecent: Bool {
    UserDefaults.standard.bool(forKey: UserDefaultsKeys.dictatePromptPreselectRecent)
  }

  /// Records what a Dictate Prompt run used. `text`: the entry or typed instruction, moved to
  /// the front of the recent list (typed text longer than `maxKeyLength` is not kept — it is a
  /// one-off, not a prompt to repeat). nil: the spoken instruction. `fromEntry`: an entry was
  /// picked, so the next card opens on it.
  static func recordUse(text: String?, fromEntry: Bool) {
    let defaults = UserDefaults.standard
    defaults.set(fromEntry, forKey: UserDefaultsKeys.dictatePromptPreselectRecent)
    guard let text else { return }
    defaults.set(
      updatedRecent(storedRecentTexts(), using: text),
      forKey: UserDefaultsKeys.dictatePromptRecentQuickActions)
  }

  /// `text` in front, earlier entries with the same key dropped, capped at `cardEntries`.
  static func updatedRecent(_ recent: [String], using text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let key = normalizeKey(trimmed)
    guard !key.isEmpty, key.count <= maxKeyLength else { return recent }
    let rest = recent.filter { normalizeKey($0) != key }
    return Array(([trimmed] + rest).prefix(cardEntries))
  }

  /// Re-reads the interaction log and replaces the cached learned list. Call off the main thread.
  func refresh() {
    let instructions = Self.promptInstructions(lastDays: Self.lookbackDays)
    let forceFallback = !ContextLoggingPreference.isEnabled || OfflineMode.isEnabled
    let learned = Self.rankLearned(from: instructions)
    let counts = Self.usageCounts(from: instructions)
    cacheLock.lock()
    cachedLearned = learned
    cachedForceFallback = forceFallback
    cachedCounts = counts
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

  /// With own prompts, the three most-used of the last 30 days (`cardEntries`). Own prompts
  /// and learned entries are ranked together by `counts` (a missing key counts as 0). Ties
  /// keep candidate order, so own prompts win ties and keep their order. A learned entry
  /// whose kind matches an entry already taken is left out (`.other` is not compared).
  /// Own prompts are capped at `maxCustomEntries` before ranking; learning off returns
  /// them in their own order, still capped at `cardEntries`.
  /// With no own prompts, learning on returns the same list as `ranked`; learning off
  /// returns nothing. Built-in defaults are never appended once the user has prompts
  /// of their own.
  static func combined(
    custom: [String], learned: [QuickAction], forceFallback: Bool, includeLearned: Bool,
    counts: [String: Int] = [:]
  ) -> [QuickAction] {
    let own = customActions(from: custom)
    if own.isEmpty {
      guard includeLearned else { return [] }
      return applyingFallback(to: learned, forceFallback: forceFallback)
    }
    guard includeLearned else { return Array(own.prefix(cardEntries)) }

    let ownKeys = Set(own.map(\.key))
    var candidates = own
    for action in learned where !ownKeys.contains(action.key) {
      candidates.append(action)
    }
    let ranked = candidates.enumerated().sorted { lhs, rhs in
      let left = counts[lhs.element.key] ?? 0
      let right = counts[rhs.element.key] ?? 0
      if left != right { return left > right }
      return lhs.offset < rhs.offset
    }.map(\.element)

    var result: [QuickAction] = []
    var takenKinds = Set<QuickActionKind>()
    for action in ranked {
      if result.count >= cardEntries { break }
      let isOwn = ownKeys.contains(action.key)
      if !isOwn, action.kind != .other, takenKinds.contains(action.kind) { continue }
      result.append(action)
      if action.kind != .other { takenKinds.insert(action.kind) }
    }
    return result
  }

  /// One row per own prompt and per cached learned entry, most used first. `on_card` is
  /// whether that key is in `current()`. `current()` runs before the lock: NSLock does not re-enter.
  func usageSummary() -> [[String: Any]] {
    let onCard = Set(current().map(\.key))
    cacheLock.lock()
    let learned = cachedLearned
    let counts = cachedCounts
    cacheLock.unlock()

    struct Row {
      let text: String
      let uses: Int
      let own: Bool
      let onCard: Bool
      let index: Int
    }
    var rows: [Row] = []
    var seen = Set<String>()
    func append(_ action: QuickAction, own: Bool) {
      if seen.contains(action.key) { return }
      seen.insert(action.key)
      rows.append(Row(
        text: action.text, uses: counts[action.key] ?? 0, own: own,
        onCard: onCard.contains(action.key), index: rows.count))
    }
    for action in Self.customActions(from: Self.storedCustomTexts()) { append(action, own: true) }
    for action in learned { append(action, own: false) }
    rows.sort { lhs, rhs in
      if lhs.uses != rhs.uses { return lhs.uses > rhs.uses }
      return lhs.index < rhs.index
    }
    return rows.map { row in
      [
        "text": row.text, "uses_30d": row.uses, "own": row.own, "on_card": row.onCard,
      ] as [String: Any]
    }
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

  /// Uses per normalized key. Every key counts, including a single use. Empty keys and the
  /// voice-instruction placeholder are skipped.
  static func usageCounts(from instructions: [String]) -> [String: Int] {
    let placeholder = normalizeKey(SpeechService.voiceInstructionPlaceholder)
    var counts: [String: Int] = [:]
    for raw in instructions {
      let key = normalizeKey(raw)
      if key.isEmpty || key == placeholder { continue }
      counts[key, default: 0] += 1
    }
    return counts
  }

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
      result.append(QuickAction(key: key, text: text, isBuiltIn: true))
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
