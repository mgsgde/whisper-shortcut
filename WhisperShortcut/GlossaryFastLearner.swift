//
//  GlossaryFastLearner.swift
//  WhisperShortcut
//
//  Fast loop of Smart Improvement: typed chat text is treated as ground-truth spelling.
//  Capitalized typed words are fuzzy-matched against recently dictated transcripts; when a
//  transcript contains a same-sounding but differently spelled word, the transcript word is
//  the machine's misspelling of what the user just typed — the typed spelling is added to
//  the Whisper Glossary immediately, so the very next dictation is conditioned with it.
//  Unlike the weekly Smart Improvement batch, a single typed occurrence is enough evidence.
//
//  False-positive guard: a matched pair is only accepted when at least one side is unknown
//  to the system spell checker. Two ordinary dictionary words that happen to sound alike
//  ("Woche"/"Wache") are both known and are rejected; a real dictation misspelling is
//  almost always a non-word ("Görde"). The typed side must NOT be required to be unknown —
//  names like the user's own surname are often "known" via Contacts integration.
//

import AppKit
import Foundation

final class GlossaryFastLearner {

  static let shared = GlossaryFastLearner()

  private let queue = DispatchQueue(label: "com.whisper-shortcut.glossaryfastlearner", qos: .utility)

  /// How far back dictation transcripts are scanned for phonetic near-misses.
  private let transcriptWindowDays = 14
  /// Cap per typed message so a pasted document can never flood the glossary.
  private let maxAdditionsPerMessage = 3
  /// Stop auto-adding once the glossary is this large — it is prepended to every
  /// transcription prompt, so unbounded growth would eat the prompt budget.
  private let glossaryAutoGrowthLimitChars = 2_000
  private let minTokenLength = 4
  private let maxCandidatesPerMessage = 12

  private init() {}

  /// Follows the same "Save usage data" toggle as ContextLogger: the transcripts this
  /// feature matches against only exist when interaction logging is enabled.
  private var isEnabled: Bool {
    UserDefaults.standard.object(forKey: UserDefaultsKeys.contextLoggingEnabled) == nil
      ? true
      : UserDefaults.standard.bool(forKey: UserDefaultsKeys.contextLoggingEnabled)
  }

  /// Entry point. Call with text the user typed themselves (chat composer).
  /// Safe to call from any thread; all work is deferred off the caller.
  func learnFromTypedText(_ text: String) {
    guard isEnabled else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= minTokenLength else { return }
    queue.async { [weak self] in
      guard let self else { return }
      let candidates = self.capitalizedTokens(in: trimmed).prefix(self.maxCandidatesPerMessage)
      guard !candidates.isEmpty else { return }
      let pairs = self.findMatches(candidates: Array(candidates))
      guard !pairs.isEmpty else { return }
      // NSSpellChecker is not thread-safe — filter the (few) matched pairs on main.
      DispatchQueue.main.async {
        let accepted = pairs.filter { !Self.isKnownWord($0.typed) || !Self.isKnownWord($0.transcript) }
        guard !accepted.isEmpty else { return }
        self.queue.async { self.commit(pairs: accepted) }
      }
    }
  }

  /// Explicit correction via the chat tool `remember_dictation_term`: appends the term to the
  /// Whisper Glossary immediately, optionally with the misheard variant as a negative example
  /// (the glossary is free text in the transcription prompt, so `Grok (not "Grog")` steers the
  /// model away from that specific error). Returns the functionResponse payload for the model.
  /// Unlike passive learning this is user intent, so it is not gated on the logging toggle.
  func rememberTerm(_ term: String, misheardAs: String?) -> [String: Any] {
    let glossary = SystemPromptsStore.shared.loadWhisperGlossary()
    let glossaryTokens = Set(tokenize(glossary).map(fold))
    let termTokens = tokenize(term).map(fold)
    if !termTokens.isEmpty, termTokens.allSatisfy({ glossaryTokens.contains($0) }) {
      DebugLogger.log("GLOSSARY-LEARN: chat tool — '\(term)' already in glossary")
      return ["ok": true, "status": "already_in_glossary", "term": term]
    }
    guard glossary.count < glossaryAutoGrowthLimitChars else {
      return [
        "error":
          "The glossary is already very large. Ask the user to prune it in Settings → Speech to Text before adding more terms."
      ]
    }
    let entry = misheardAs.map { "\(term) (not \"\($0)\")" } ?? term
    let newGlossary = glossary.isEmpty ? entry : glossary + "\n" + entry
    SystemPromptsStore.shared.updateSection(.whisperGlossary, content: newGlossary)
    DebugLogger.log("GLOSSARY-LEARN: chat tool added '\(entry)' to glossary")
    return [
      "ok": true, "status": "added", "glossary_entry": entry,
      "note": "Saved. All future dictations are conditioned with this term.",
    ]
  }

  // MARK: - Pipeline stages

  /// Capitalized words of useful length, deduped, in order of appearance.
  private func capitalizedTokens(in text: String) -> [String] {
    var seen = Set<String>()
    return tokenize(text).filter {
      $0.count >= minTokenLength && $0.first?.isUppercase == true && seen.insert($0).inserted
    }
  }

  /// Fuzzy-matches typed candidates against recent transcript words (utility queue).
  private func findMatches(candidates: [String]) -> [(typed: String, transcript: String)] {
    let glossary = SystemPromptsStore.shared.loadWhisperGlossary()
    guard glossary.count < glossaryAutoGrowthLimitChars else {
      DebugLogger.log("GLOSSARY-LEARN: skip — glossary at auto-growth limit (\(glossary.count) chars)")
      return []
    }
    let glossaryTokens = Set(tokenize(glossary).map(fold))

    let transcripts = recentTranscriptionResults()
    guard !transcripts.isEmpty else { return [] }
    // How many distinct transcripts contain each token, exact spelling.
    var transcriptCounts: [String: Int] = [:]
    var properTranscriptTokens: [(original: String, folded: String)] = []
    var seenProper = Set<String>()
    for result in transcripts {
      for token in Set(tokenize(result)) {
        transcriptCounts[token, default: 0] += 1
        if token.count >= minTokenLength, token.first?.isUppercase == true,
           seenProper.insert(token).inserted {
          properTranscriptTokens.append((original: token, folded: fold(token)))
        }
      }
    }

    var pairs: [(typed: String, transcript: String)] = []
    var addedFolded = Set<String>()
    var decisions: [String] = []
    for candidate in candidates {
      guard pairs.count < maxAdditionsPerMessage else { break }
      let foldedCandidate = fold(candidate)
      // Already in the glossary, or a case/diacritic variant was accepted earlier in this
      // same message ("Grok" then "GROK!!!") → nothing to learn.
      guard !glossaryTokens.contains(foldedCandidate), !addedFolded.contains(foldedCandidate) else {
        decisions.append("\(candidate):in-glossary")
        continue
      }
      // Same-sounding, differently spelled transcript words are potential machine
      // misspellings of what the user typed. Distance 0 after folding = pure
      // case/diacritic correction.
      let variants = properTranscriptTokens.filter { transcript in
        transcript.original != candidate
          && transcript.folded.first == foldedCandidate.first
          && Self.levenshtein(foldedCandidate, transcript.folded,
                              limit: foldedCandidate.count <= 5 ? 1 : 2) != nil
      }
      guard let best = variants.max(by: {
        transcriptCounts[$0.original, default: 0] < transcriptCounts[$1.original, default: 0]
      }) else { continue }
      // The human correction is the spelling the machine produces RARELY; the machine's
      // misspelling is the frequent one. This also rejects pasted dictation output: there
      // the "typed" word is itself the frequent transcript spelling.
      let candidateCount = transcriptCounts[candidate, default: 0]
      let variantCount = transcriptCounts[best.original, default: 0]
      if candidateCount < variantCount {
        pairs.append((typed: candidate, transcript: best.original))
        addedFolded.insert(foldedCandidate)
        decisions.append("\(candidate)←\(best.original)(\(candidateCount)vs\(variantCount))")
      } else {
        decisions.append("\(candidate):not-rarer-than-\(best.original)(\(candidateCount)vs\(variantCount))")
      }
    }
    if !decisions.isEmpty {
      DebugLogger.log("GLOSSARY-LEARN: run candidates=\(candidates.count) transcripts=\(transcripts.count) decisions=[\(decisions.joined(separator: ", "))]")
    }
    return pairs
  }

  /// Appends accepted spellings to the glossary (utility queue).
  private func commit(pairs: [(typed: String, transcript: String)]) {
    let glossary = SystemPromptsStore.shared.loadWhisperGlossary()
    let glossaryTokens = Set(tokenize(glossary).map(fold))
    let additions = pairs.map(\.typed).filter { !glossaryTokens.contains(fold($0)) }
    guard !additions.isEmpty else { return }
    let newGlossary = glossary.isEmpty
      ? additions.joined(separator: "\n")
      : glossary + "\n" + additions.joined(separator: "\n")
    SystemPromptsStore.shared.updateSection(.whisperGlossary, content: newGlossary)
    let matchLog = pairs.map { "\($0.typed)←\($0.transcript)" }.joined(separator: ", ")
    DebugLogger.log("GLOSSARY-LEARN: added \(additions.count) term(s) from typed chat text: [\(matchLog)]")
  }

  private func recentTranscriptionResults() -> [String] {
    let decoder = JSONDecoder()
    var results: [String] = []
    for fileURL in ContextLogger.shared.interactionLogFiles(lastDays: transcriptWindowDays) {
      guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
      for line in content.components(separatedBy: .newlines) where !line.isEmpty {
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(InteractionLogEntry.self, from: data),
              entry.mode == "transcription",
              let result = entry.result else { continue }
        results.append(result)
      }
    }
    return results
  }

  // MARK: - Text helpers

  /// True when the system spell checker (all active languages, plus learned/Contacts
  /// vocabulary) accepts the word. Main thread only.
  private static func isKnownWord(_ word: String) -> Bool {
    let checker = NSSpellChecker.shared
    checker.automaticallyIdentifiesLanguages = true
    return checker.checkSpelling(of: word, startingAt: 0).location == NSNotFound
  }

  private func tokenize(_ text: String) -> [String] {
    text.split(whereSeparator: { !$0.isLetter }).map(String.init)
  }

  /// Case- and diacritic-insensitive form used for phonetic-ish comparison
  /// ("Gödde" and "godde" fold to the same string).
  private func fold(_ word: String) -> String {
    word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
  }

  /// Edit distance if it is ≤ `limit`, else nil.
  private static func levenshtein(_ a: String, _ b: String, limit: Int) -> Int? {
    let aChars = Array(a), bChars = Array(b)
    guard abs(aChars.count - bChars.count) <= limit else { return nil }
    guard !aChars.isEmpty, !bChars.isEmpty else {
      let distance = max(aChars.count, bChars.count)
      return distance <= limit ? distance : nil
    }
    var previous = Array(0...bChars.count)
    var current = [Int](repeating: 0, count: bChars.count + 1)
    for i in 1...aChars.count {
      current[0] = i
      var rowMin = current[0]
      for j in 1...bChars.count {
        let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
        current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        rowMin = min(rowMin, current[j])
      }
      guard rowMin <= limit else { return nil }
      swap(&previous, &current)
    }
    let distance = previous[bChars.count]
    return distance <= limit ? distance : nil
  }
}
