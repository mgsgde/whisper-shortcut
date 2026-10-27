//
//  GlossaryLearning.swift
//  WhisperShortcut
//
//  The Whisper Glossary is free text the user asserts by hand (and via the chat tool).
//  Smart Improvement used to let the model rewrite that whole text, so an accepted
//  suggestion deleted annotated corrections. Every automatic edit now goes through
//  `mergeAdditively`, which only appends. Near-miss mining is the deterministic half
//  of the same idea: a term the corpus already spells one way, plus the other spellings
//  the recognizer keeps producing, without waiting for the model to notice.
//

import Foundation

enum GlossaryLearning {

  /// One glossary term and the spellings that should not be offered as that term.
  struct NearMiss: Equatable {
    let term: String
    let variants: [String]
  }

  /// Case- and diacritic-insensitive key shared with glossary dedupe ("Gödde" == "godde").
  /// `GlossaryDocument.fold` is POSIX, so this no longer follows the user's locale.
  static func fold(_ s: String) -> String {
    GlossaryDocument.fold(s)
  }

  /// One entry per term on a glossary line. Rejected spellings from every `(not …)` /
  /// `(nicht …)` group on that line attach to each of its terms — a line is normally one
  /// term, but `Terms: A, B` is several and they share the line's rejections.
  /// Parsing lives in `GlossaryDocument`; this is the tuple shape callers already use.
  static func entries(in glossary: String) -> [(term: String, rejected: [String])] {
    GlossaryDocument.parse(glossary).entries.map { (term: $0.term, rejected: $0.rejectedSpellings) }
  }

  /// `Term (not "A", "B")` — the only annotated shape this module writes, so a suggestion
  /// that arrived with `(nicht …)` or odd spacing is stored the way the prompt parser reads.
  static func annotatedLine(term: String, rejected: [String]) -> String {
    let quoted = rejected.map { "\"\($0)\"" }.joined(separator: ", ")
    return "\(term) (not \(quoted))"
  }

  /// The only way Smart Improvement may change the glossary. `current` is kept verbatim
  /// (trailing whitespace of the whole text aside) because those lines are user-asserted;
  /// `suggestion` may only contribute terms and rejected spellings that are not already there.
  static func mergeAdditively(current: String, suggestion: String) -> String {
    let base = trimmingTrailingWhitespaceAndNewlines(current)
    let currentEntries = entries(in: base)
    var knownTerms = Set<String>()
    var knownRejected = Set<String>()
    for entry in currentEntries {
      let foldedTerm = fold(entry.term)
      if !foldedTerm.isEmpty { knownTerms.insert(foldedTerm) }
      for rejected in entry.rejected {
        let folded = fold(rejected)
        if !folded.isEmpty { knownRejected.insert(folded) }
      }
    }
    let known = knownTerms.union(knownRejected)

    struct Addition {
      var term: String
      var rejected: [String]
    }
    var additions: [Addition] = []
    var indexByFold: [String: Int] = [:]
    var addedRejected = Set<String>()

    func alreadyQueued(_ folded: String) -> Bool {
      indexByFold[folded] != nil || addedRejected.contains(folded)
    }

    /// First spelling of each folded form wins; drop the term itself, known terms, and
    /// anything this merge has already queued. `dropRejected` is on for a term the glossary
    /// already asserts — repeating `Vianco` under `Wianco` teaches nothing.
    func freshRejected(_ forms: [String], termFold: String, dropRejected: Bool) -> [String] {
      var seen = Set<String>()
      var kept: [String] = []
      for form in forms {
        let folded = fold(form)
        if folded.isEmpty || folded == termFold { continue }
        if !seen.insert(folded).inserted { continue }
        if knownTerms.contains(folded) || alreadyQueued(folded) { continue }
        if dropRejected && knownRejected.contains(folded) { continue }
        kept.append(form)
      }
      return kept
    }

    func queue(term: String, rejected: [String]) {
      let folded = fold(term)
      if let index = indexByFold[folded] {
        var existing = Set(additions[index].rejected.map { fold($0) })
        for form in rejected where existing.insert(fold(form)).inserted {
          additions[index].rejected.append(form)
          addedRejected.insert(fold(form))
        }
        return
      }
      indexByFold[folded] = additions.count
      additions.append(Addition(term: term, rejected: rejected))
      for form in rejected { addedRejected.insert(fold(form)) }
    }

    for rawLine in suggestion.components(separatedBy: .newlines) {
      if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      let lineEntries = entries(in: rawLine)
      let annotated = lineEntries.contains { !$0.rejected.isEmpty }
      if annotated {
        for entry in lineEntries {
          let termFold = fold(entry.term)
          if termFold.isEmpty { continue }
          if knownTerms.contains(termFold) {
            let newRejected = freshRejected(entry.rejected, termFold: termFold, dropRejected: true)
            if newRejected.isEmpty { continue }
            queue(term: entry.term, rejected: newRejected)
          } else if known.contains(termFold) || addedRejected.contains(termFold) {
            // A spelling the user already marked wrong must not come back as the "correct" term.
            continue
          } else if indexByFold[termFold] != nil {
            let extra = freshRejected(entry.rejected, termFold: termFold, dropRejected: false)
            if extra.isEmpty { continue }
            queue(term: entry.term, rejected: extra)
          } else {
            let kept = freshRejected(entry.rejected, termFold: termFold, dropRejected: false)
            queue(term: entry.term, rejected: kept)
          }
        }
      } else {
        for entry in lineEntries {
          let term = entry.term
          if !GlossaryDocument.withinWordCap(term) { continue }
          let termFold = fold(term)
          if termFold.isEmpty || known.contains(termFold) || alreadyQueued(termFold) { continue }
          queue(term: term, rejected: [])
        }
      }
    }

    if additions.isEmpty { return base }
    let rendered = additions.map { addition in
      addition.rejected.isEmpty ? addition.term : annotatedLine(term: addition.term, rejected: addition.rejected)
    }
    if base.isEmpty { return rendered.joined(separator: "\n") }
    return base + "\n" + rendered.joined(separator: "\n")
  }

  /// Spellings the recognizer keeps substituting for a term the user (or the corpus) already
  /// spells one way. Deterministic on purpose: the weekly model pass is what used to delete
  /// asserted lines, and it also missed high-frequency pairs like Bachata / Batchata.
  ///
  /// `maxDistance == nil` uses the fast learner's length rule (2 edits only when the shorter
  /// word has at least 8 characters). Audio selection passes 2 so a slightly farther mishearing
  /// can still pick a clip; the suggestion itself stays on the strict rule.
  static func nearMisses(
    glossary: String,
    transcripts: [String],
    maxDistance: Int? = nil,
    isKnownWord: (String) -> Bool = { _ in false }
  ) -> [NearMiss] {
    struct TokenStats {
      var docFreq = 0
      var occurrences = 0
      var upperInitial = 0
      var spellingCounts: [String: Int] = [:]
    }
    var stats: [String: TokenStats] = [:]
    for text in transcripts {
      var seenInDoc = Set<String>()
      for tokenSub in text.split(whereSeparator: { !$0.isLetter }) {
        let token = String(tokenSub)
        let folded = fold(token)
        if folded.isEmpty { continue }
        var bucket = stats[folded] ?? TokenStats()
        bucket.occurrences += 1
        bucket.spellingCounts[token, default: 0] += 1
        if token.first?.isUppercase == true { bucket.upperInitial += 1 }
        if seenInDoc.insert(folded).inserted { bucket.docFreq += 1 }
        stats[folded] = bucket
      }
    }

    func majoritySpelling(_ folded: String) -> String? {
      guard let counts = stats[folded]?.spellingCounts else { return nil }
      return Self.majoritySpelling(in: counts)
    }

    let glossaryEntries = entries(in: glossary)
    var glossaryTerms = Set<String>()
    var rejectedForTerm: [String: Set<String>] = [:]
    for entry in glossaryEntries {
      let termFold = fold(entry.term)
      if termFold.isEmpty { continue }
      glossaryTerms.insert(termFold)
      var rejected = rejectedForTerm[termFold] ?? []
      for form in entry.rejected { rejected.insert(fold(form)) }
      rejectedForTerm[termFold] = rejected
    }

    struct Candidate {
      let folded: String
      let display: String
      let docFreq: Int
      let fromGlossary: Bool
    }
    var candidatesByFold: [String: Candidate] = [:]
    for entry in glossaryEntries {
      if entry.term.contains(" ") { continue }
      let termFold = fold(entry.term)
      guard termFold.count >= 5, candidatesByFold[termFold] == nil else { continue }
      let display = majoritySpelling(termFold) ?? entry.term
      candidatesByFold[termFold] = Candidate(
        folded: termFold,
        display: display,
        docFreq: stats[termFold]?.docFreq ?? 0,
        fromGlossary: true)
    }

    let totalDocs = transcripts.count
    let ambientCutoff = Int(ceil(Double(totalDocs) * AppConstants.audioCandidateAmbientDocRatio))
    for (folded, bucket) in stats {
      guard folded.count >= 5, bucket.docFreq >= 5, bucket.occurrences > 0 else { continue }
      let capitalRatio = Double(bucket.upperInitial) / Double(bucket.occurrences)
      guard capitalRatio >= AppConstants.audioCandidateConsistentCapRatio else { continue }
      guard bucket.docFreq < ambientCutoff else { continue }
      if candidatesByFold[folded] != nil { continue }
      guard let display = majoritySpelling(folded) else { continue }
      candidatesByFold[folded] = Candidate(
        folded: folded,
        display: display,
        docFreq: bucket.docFreq,
        fromGlossary: false)
    }

    let ordered = candidatesByFold.values.sorted { lhs, rhs in
      if lhs.docFreq != rhs.docFreq { return lhs.docFreq > rhs.docFreq }
      return lhs.folded < rhs.folded
    }

    var usedVariants = Set<String>()
    var misses: [NearMiss] = []
    for candidate in ordered {
      if misses.count >= 20 { break }
      guard let termFirst = candidate.folded.first else { continue }
      let alreadyRejected = rejectedForTerm[candidate.folded] ?? []
      var variants: [(folded: String, display: String, docFreq: Int)] = []
      for (variantFold, bucket) in stats {
        if variantFold == candidate.folded { continue }
        guard variantFold.first == termFirst, bucket.docFreq >= 2 else { continue }
        // A second glossary entry is a term the user wants, not a mishearing of this one.
        guard !glossaryTerms.contains(variantFold) else { continue }
        guard !alreadyRejected.contains(variantFold) else { continue }
        // A term found only in the corpus must clearly dominate its variant: a mishearing is the
        // rare form (Bachata ~100 vs Batchata 2). Two similar names used about equally often
        // ("Martin"/"Marvin") are two words. Glossary terms are user-asserted and skip this.
        if !candidate.fromGlossary, bucket.docFreq * 3 > candidate.docFreq { continue }
        if usedVariants.contains(variantFold) { continue }
        let shorter = min(candidate.folded.count, variantFold.count)
        let allowed = maxDistance ?? (shorter >= 8 ? 2 : 1)
        guard GlossaryFastLearner.levenshtein(candidate.folded, variantFold, limit: allowed) != nil else { continue }
        guard !GlossaryFastLearner.isInflectionalVariant(candidate.folded, variantFold) else { continue }
        guard let display = majoritySpelling(variantFold) else { continue }
        // Two ordinary dictionary words that happen to be one edit apart ("Sonne"/"Sonnet")
        // are not a recognizer mistake. Same guard as GlossaryFastLearner.
        if isKnownWord(candidate.display) && isKnownWord(display) { continue }
        variants.append((variantFold, display, bucket.docFreq))
      }
      variants.sort { lhs, rhs in
        if lhs.docFreq != rhs.docFreq { return lhs.docFreq > rhs.docFreq }
        if lhs.display != rhs.display { return lhs.display < rhs.display }
        return lhs.folded < rhs.folded
      }
      if variants.count > 4 { variants = Array(variants.prefix(4)) }
      guard !variants.isEmpty else { continue }
      for variant in variants { usedVariants.insert(variant.folded) }
      misses.append(NearMiss(term: candidate.display, variants: variants.map(\.display)))
    }
    return misses
  }

  static func nearMissLines(_ misses: [NearMiss]) -> String {
    misses.map { annotatedLine(term: $0.term, rejected: $0.variants) }.joined(separator: "\n")
  }

  /// The chat tool often hand back a lowercase term. Lines already in
  /// `current` stay byte-for-byte — those are the user's spelling — and tokens inside a
  /// `(not …)` / `(nicht …)` group stay too, because that group is the mishearing, not the term.
  /// Everywhere else, a letter-token whose folded form shows up at least three times is rewritten
  /// to the corpus's majority spelling when the two differ only by case or diacritics.
  static func applyingMajorityCasing(
    to text: String,
    keepingLinesOf current: String,
    transcripts: [String]
  ) -> String {
    var counts: [String: [String: Int]] = [:]
    var totals: [String: Int] = [:]
    for transcript in transcripts {
      for tokenSub in transcript.split(whereSeparator: { !$0.isLetter }) {
        let token = String(tokenSub)
        let folded = fold(token)
        if folded.isEmpty { continue }
        totals[folded, default: 0] += 1
        counts[folded, default: [:]][token, default: 0] += 1
      }
    }
    var majority: [String: String] = [:]
    for (folded, total) in totals where total >= 3 {
      if let spelling = majoritySpelling(in: counts[folded] ?? [:]) {
        majority[folded] = spelling
      }
    }

    let protected = Set(current.components(separatedBy: .newlines))
    return text.components(separatedBy: .newlines).map { line in
      protected.contains(line) ? line : recasing(line, majority: majority)
    }.joined(separator: "\n")
  }

  // MARK: - Private

  private static func trimmingTrailingWhitespaceAndNewlines(_ text: String) -> String {
    var end = text.endIndex
    while end > text.startIndex {
      let previous = text.index(before: end)
      if text[previous].isWhitespace || text[previous].isNewline {
        end = previous
      } else {
        break
      }
    }
    return String(text[..<end])
  }

  /// Highest count wins; a tie keeps the lexicographically smaller spelling so the choice
  /// does not depend on dictionary order.
  private static func majoritySpelling(in counts: [String: Int]) -> String? {
    counts.max { lhs, rhs in
      if lhs.value != rhs.value { return lhs.value < rhs.value }
      return lhs.key > rhs.key
    }?.key
  }

  private static func recasing(_ line: String, majority: [String: String]) -> String {
    let protected = GlossaryDocument.annotationRanges(in: line)

    var output = ""
    var index = line.startIndex
    while index < line.endIndex {
      if let range = protected.first(where: { $0.contains(index) }) {
        output += line[range]
        index = range.upperBound
        continue
      }
      if line[index].isLetter {
        var end = index
        while end < line.endIndex, line[end].isLetter, !protected.contains(where: { $0.contains(end) }) {
          end = line.index(after: end)
        }
        let token = String(line[index..<end])
        let folded = fold(token)
        if let spelled = majority[folded], fold(spelled) == folded, spelled != token {
          output += spelled
        } else {
          output += token
        }
        index = end
      } else {
        output.append(line[index])
        index = line.index(after: index)
      }
    }
    return output
  }
}
