import Foundation

// MARK: - Memory style facts

/// Facts from memory.md that are about HOW the user wants text written, never facts about
/// the person. Only these reach Dictate Prompt — personal facts must not leak into text
/// written to third parties.
enum MemoryStyleRules {
  /// Keeps writing-style facts in their original order and strips a leading `Style:` / `Stil:` marker.
  static func styleFacts(from facts: [String]) -> [String] {
    facts.compactMap { fact in
      guard isStyleFact(fact) else { return nil }
      let stripped = strippingStyleMarker(fact)
      return stripped.isEmpty ? nil : stripped
    }
  }

  /// True when the fact is an explicit style note, names a writing-style topic, or pairs a
  /// style adjective with a word for the text itself.
  static func isStyleFact(_ fact: String) -> Bool {
    let text = normalized(fact)
    if hasStyleMarker(text) { return true }
    if strongTerms.contains(where: { text.contains($0) }) { return true }
    // "dash" is a whole word so "dashboard" is not a style fact.
    if containsWholeWord(text, "dash") { return true }
    let hasAdjective = styleAdjectives.contains(where: { text.contains($0) })
    let hasNoun = textNouns.contains(where: { text.contains($0) })
    return hasAdjective && hasNoun
  }

  /// The user asked for a short hyphen instead of an em/en dash. Both the dash and the
  /// preference have to be in the same fact — a dash mentioned somewhere else is not a rule.
  static func prefersShortDashes(styleFacts: [String]) -> Bool {
    styleFacts.contains { fact in
      let text = normalized(fact)
      let mentionsDash = dashTerms.contains(where: { text.contains($0) })
      let statesPreference = preferenceWords.contains(where: { text.contains($0) })
      return mentionsDash && statesPreference
    }
  }

  /// Empty when there is nothing to apply, so the system prompt is unchanged.
  static func promptBlock(styleFacts: [String]) -> String {
    guard !styleFacts.isEmpty else { return "" }
    let lines = styleFacts.map { "- \($0)" }.joined(separator: "\n")
    return "\n\nThe user's standing writing preferences (from their saved memory). Apply them to every text you write or edit unless the voice instruction says otherwise:\n"
      + lines
  }

  private static let strongTerms = [
    "bindestrich", "gedankenstrich", "emoji", "floskel", "schreibstil", "writing style",
    "tonfall", "tone of voice", "anrede", "duzen", "siezen", "ki-deutsch", "ki-typisch",
    "ai-sounding", "sound like ai", "sound like an ai", "—", "–",
  ]

  private static let styleAdjectives = [
    "kurz", "knapp", "natürlich", "förmlich", "formell", "locker", "concise", "short",
    "brief", "casual", "formal", "informal", "blumig", "verbose",
  ]

  private static let textNouns = [
    "antwort", "formulier", "text", "sprache", "nachricht", "satz", "sätze", "answer",
    "repl", "response", "writing", "message", "wording", "sentence",
  ]

  private static let dashTerms = [
    "gedankenstrich", "bindestrich", "em dash", "em-dash", "en dash", "en-dash",
    "long dash", "—", "–",
  ]

  private static let preferenceWords = [
    "statt", "kein", "keine", "ohne", "nie", "niemals", "nicht", "nur", "ausschließlich",
    "ersetz", "avoid", "no ", "never", "instead", "don't", "do not", "only", "replace",
  ]

  private static func normalized(_ fact: String) -> String {
    fact.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func hasStyleMarker(_ text: String) -> Bool {
    text.hasPrefix("style:") || text.hasPrefix("stil:")
  }

  private static func strippingStyleMarker(_ fact: String) -> String {
    let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    for marker in ["style:", "stil:"] where lower.hasPrefix(marker) {
      return String(trimmed.dropFirst(marker.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
  }
}

// MARK: - Dash backstop

/// Replaces em/en dashes with "-" in model output when the user's memory asks for short
/// hyphens and the selection itself had none (so we never rewrite dashes the user wrote).
/// Fenced ``` code blocks and inline `code` spans are left untouched.
enum DashBackstop {
  /// Callers decide whether the preference is set; this does not read memory.
  static func apply(to output: String, selection: String?) -> String {
    if let selection, selection.contains("—") || selection.contains("–") {
      return output
    }
    return replacingDashes(outsideCodeFences: output)
  }

  /// Odd fence segments are code, including an unterminated fence through the end of the string.
  private static func replacingDashes(outsideCodeFences text: String) -> String {
    let segments = text.components(separatedBy: "```")
    let rewritten = segments.enumerated().map { index, segment in
      index.isMultiple(of: 2) ? replacingDashes(outsideInlineCode: segment) : segment
    }
    return rewritten.joined(separator: "```")
  }

  /// Odd backtick segments are inline code. An unterminated backtick is code until the end,
  /// same rule as an unterminated fence.
  private static func replacingDashes(outsideInlineCode text: String) -> String {
    let segments = text.components(separatedBy: "`")
    let rewritten = segments.enumerated().map { index, segment in
      index.isMultiple(of: 2) ? replacingDashes(in: segment) : segment
    }
    return rewritten.joined(separator: "`")
  }

  /// Spaced dashes become a spaced hyphen first, so " — " stays a separator and not a glued "-".
  private static func replacingDashes(in text: String) -> String {
    var rewritten = text.replacingOccurrences(of: " — ", with: " - ")
    rewritten = rewritten.replacingOccurrences(of: " – ", with: " - ")
    rewritten = rewritten.replacingOccurrences(of: "—", with: "-")
    rewritten = rewritten.replacingOccurrences(of: "–", with: "-")
    return rewritten
  }
}

// MARK: - Follow-up chains

/// Iterative Dictate Prompt edits: the user selected the previous output and asked for a change.
/// The window and the similarity cutoff are the ones from the 2026-10 log review, so the
/// falsifier baseline (136 of 722 follow-ups, 46 style) stays comparable.
enum PromptFollowUp {
  enum Kind: String {
    case style
    case transform
    case other
  }

  /// Same window and threshold as the 2026-10 log review (scratch a5.py).
  static let window: TimeInterval = 300
  static let similarityThreshold = 0.6

  struct Chain: Equatable {
    let ts: String
    let kind: Kind
    let previousOutput: String
    let instruction: String
    let newOutput: String
  }

  /// Lowercased words. Split on everything that is not a Unicode letter or digit.
  static func words(_ text: String) -> Set<String> {
    Set(
      text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    )
  }

  /// `|a ∩ b| / max(1, |a ∪ b|)`. Generic so the same formula scores word sets and the
  /// word-hash sets `ContextLogger` keeps (it must not retain the words themselves).
  static func jaccard<Element: Hashable>(_ a: Set<Element>, _ b: Set<Element>) -> Double {
    Double(a.intersection(b).count) / Double(max(1, a.union(b).count))
  }

  static func isFollowUp<Element: Hashable>(
    selectionWords: Set<Element>, previousResponseWords: Set<Element>, gap: TimeInterval
  ) -> Bool {
    gap >= 0 && gap < window && !selectionWords.isEmpty
      && jaccard(selectionWords, previousResponseWords) > similarityThreshold
  }

  /// The string form of the predicate above. The scorecard used to reimplement follow-up
  /// detection with word-Levenshtein at 0.8, so its count was not the `promptFollowUp` signal.
  static func isFollowUp(selection: String, previousResponse: String, gap: TimeInterval) -> Bool {
    isFollowUp(
      selectionWords: words(selection),
      previousResponseWords: words(previousResponse),
      gap: gap)
  }

  /// Transform before style: "translate this shorter" is a request, not a style complaint.
  /// `ton`, `list`, and `less` are whole words so "Tonne" / "listen" / "unless" do not match
  /// those three; `liste` stays a substring so the German word still matches.
  static func classify(instruction: String) -> Kind {
    let text = instruction.lowercased()
    if matches(text, terms: transformTerms) { return .transform }
    if matches(text, terms: styleTerms) { return .style }
    return .other
  }

  /// Prompt-mode rows only, oldest first. A chain is two consecutive rows where the later
  /// selection is the earlier output, inside the window, and the later row is on or after `cutoff`.
  static func chains(
    in entries: [InteractionLogEntry], since cutoff: Date, parseDate: (String) -> Date
  ) -> [Chain] {
    let promptEntries = entries.filter { $0.interactionMode == .prompt }.sorted { $0.ts < $1.ts }
    guard promptEntries.count >= 2 else { return [] }
    var found: [Chain] = []
    for index in 1..<promptEntries.count {
      let previous = promptEntries[index - 1]
      let current = promptEntries[index]
      guard
        let previousOutput = nonEmpty(previous.modelResponse),
        let selected = nonEmpty(current.selectedText),
        let newOutput = nonEmpty(current.modelResponse)
      else { continue }
      let currentDate = parseDate(current.ts)
      guard currentDate >= cutoff else { continue }
      let gap = currentDate.timeIntervalSince(parseDate(previous.ts))
      guard isFollowUp(
        selectionWords: words(selected), previousResponseWords: words(previousOutput), gap: gap
      ) else { continue }
      found.append(Chain(
        ts: current.ts,
        kind: classify(instruction: current.userInstruction ?? ""),
        previousOutput: previousOutput,
        instruction: current.userInstruction ?? "",
        newOutput: newOutput
      ))
    }
    return found
  }

  /// Newest chains are kept when the text would exceed `maxChars`; the result is chronological.
  /// One chain that is itself over the budget is still returned — dropping it would hide the
  /// only evidence left.
  static func render(_ chains: [Chain], maxFieldChars: Int, maxChars: Int) -> String {
    let kept = fitting(chains, maxFieldChars: maxFieldChars, maxChars: maxChars)
    guard !kept.isEmpty else { return "" }
    return format(kept, maxFieldChars: maxFieldChars)
  }

  /// The chains `render` keeps, so a caller printing "Total:" counts the same rows the body shows.
  static func fitting(_ chains: [Chain], maxFieldChars: Int, maxChars: Int) -> [Chain] {
    var kept = chains.sorted { $0.ts < $1.ts }
    while kept.count > 1 && format(kept, maxFieldChars: maxFieldChars).count > maxChars {
      kept.removeFirst()
    }
    return kept
  }

  private static let transformTerms: [(String, wholeWord: Bool)] = [
    ("übersetz", false), ("translate", false), ("englisch", false), ("english", false),
    ("auf deutsch", false), ("in german", false), ("stichpunkt", false), ("bullet", false),
    ("aufzählung", false), ("liste", false), ("list", true), ("tabelle", false),
    ("table", false), ("zusammenfass", false), ("summar", false), ("json", false),
    ("markdown", false),
  ]

  private static let styleTerms: [(String, wholeWord: Bool)] = [
    ("kürz", false), ("kurz", false), ("short", false), ("knapp", false), ("straff", false),
    ("concise", false), ("länger", false), ("longer", false), ("ausführlich", false),
    ("locker", false), ("lässig", false), ("informell", false), ("casual", false),
    ("freundlich", false), ("friendly", false), ("förmlich", false), ("formell", false),
    ("formal", false), ("professionell", false), ("duz", false), ("siez", false),
    ("per du", false), ("per sie", false), ("anrede", false), ("gruß", false), ("grüß", false),
    ("greet", false), ("strich", false), ("dash", false), ("emoji", false),
    ("natürlich", false), ("natural", false), ("ton", true), ("tone", false),
    ("floskel", false), ("weniger", false), ("ohne", false), ("without", false),
    ("less", true), ("nicht so", false), ("klingt", false), ("sound", false),
  ]

  private static func matches(_ text: String, terms: [(String, wholeWord: Bool)]) -> Bool {
    terms.contains { term, wholeWord in
      wholeWord ? containsWholeWord(text, term) : text.contains(term)
    }
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func format(_ chains: [Chain], maxFieldChars: Int) -> String {
    chains.enumerated().map { index, chain in
      let number = String(format: "%03d", index + 1)
      return """
      chain: fu-\(number) | ts: \(chain.ts) | kind: \(chain.kind.rawValue)
      previousOutput: \(clip(chain.previousOutput, maxFieldChars))
      userInstruction: \(clip(chain.instruction, maxFieldChars))
      newOutput: \(clip(chain.newOutput, maxFieldChars))
      """
    }
    .joined(separator: "\n---\n")
  }

  private static func clip(_ text: String, _ maxChars: Int) -> String {
    String(text.prefix(maxChars))
  }
}

/// Whole-word match on an already-lowercased string. A hyphen is a boundary, so "dash" matches
/// "em-dash" and does not match "dashboard".
private func containsWholeWord(_ text: String, _ word: String) -> Bool {
  guard !word.isEmpty else { return false }
  var searchStart = text.startIndex
  while searchStart < text.endIndex, let range = text.range(of: word, range: searchStart..<text.endIndex) {
    let beforeIsBoundary = range.lowerBound == text.startIndex
      || !isWordCharacter(text[text.index(before: range.lowerBound)])
    let afterIsBoundary = range.upperBound == text.endIndex || !isWordCharacter(text[range.upperBound])
    if beforeIsBoundary && afterIsBoundary { return true }
    searchStart = range.upperBound
  }
  return false
}

private func isWordCharacter(_ character: Character) -> Bool {
  character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
}
