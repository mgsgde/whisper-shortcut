import AppKit
import Foundation

/// Words the app probably gets wrong in dictation, found by scanning the whole usage-log window
/// (no LLM). `/improve`'s `app_settings` review hands the list to the Chat model, which judges each
/// candidate. Spec: `plans/active/improve-dictation-candidates.md` (a Python port in the private
/// eval must give the same list for the same input).
enum DictationCandidates {

  static let maxCandidates = 5
  static let maxSpellCheckWords = 1500

  enum Source: String {
    case selfComplaint = "self_complaint"
    case glossaryNotWorking = "glossary_not_working"
    case typedCorrection = "typed_correction"
    case retryDiff = "retry_diff"
    case soundsLikeKnown = "sounds_like_known"
    case spellingVariants = "spelling_variants"
    case unknownRecurring = "unknown_recurring"

    var rank: Int {
      switch self {
      case .selfComplaint: return 1
      case .glossaryNotWorking: return 2
      case .typedCorrection: return 3
      case .retryDiff: return 4
      case .soundsLikeKnown: return 5
      case .spellingVariants: return 6
      case .unknownRecurring: return 7
      }
    }
  }

  struct Candidate: Equatable {
    let heard: String
    let suggested: String?
    let source: Source
    let count: Int
    let rowIds: [String]
    let alsoHeard: [String]

    var json: [String: Any] {
      [
        "heard": heard,
        "suggested": suggested.map { $0 as Any } ?? NSNull(),
        "source": source.rawValue,
        "count": count,
        "row_ids": rowIds,
        "also_heard": alsoHeard,
      ]
    }
  }

  // MARK: - Constants

  static let productVocabulary: [String] = [
    "Claude", "Claude Code", "Anthropic", "OpenAI", "ChatGPT", "Codex", "Gemini", "Google", "Grok",
    "xAI", "Cursor", "Copilot", "GitHub", "GitLab", "Perplexity", "Mistral", "Llama", "Ollama",
    "DeepSeek", "Qwen", "Whisper", "WhisperShortcut", "Parakeet", "Xcode", "Swift", "Python",
    "JavaScript", "TypeScript", "Slack", "Notion", "Figma", "Supabase", "Vercel", "Docker",
    "Kubernetes", "Firebase", "Hugging Face", "LangChain", "Midjourney", "ElevenLabs", "WhatsApp",
    "Telegram", "Zoom", "Linear", "Jira", "Obsidian", "Raycast", "Homebrew",
  ]

  static let stopwords: Set<String> = Set(
    [
      "ich", "du", "er", "sie", "es", "wir", "ihr", "mir", "mich", "dir", "dich", "uns", "euch",
      "ihm", "ihn", "ihnen", "das", "der", "die", "den", "dem", "des", "ein", "eine", "einen",
      "einem", "einer", "und", "oder", "aber", "also", "doch", "nicht", "noch", "auch", "nur",
      "schon", "mal", "ja", "nee", "nein", "okay", "ok", "gut", "bitte", "danke", "warum", "wieso",
      "weshalb", "was", "wer", "wie", "wo", "wann", "welche", "welcher", "welches", "kannst",
      "koennen", "konnen", "kann", "soll", "sollen", "sollte", "muss", "musst", "wird", "werden",
      "wurde", "ist", "sind", "war", "hat", "habe", "haben", "hast", "gibt", "mach", "mache",
      "machen", "dann", "wenn", "weil", "dass", "damit", "hier", "dort", "jetzt", "heute", "morgen",
      "frau", "herr", "herrn", "dr", "prof", "hallo", "hey", "hi", "liebe", "lieber", "the", "and",
      "but", "this", "that", "what", "why", "how", "who", "when", "where", "which", "can", "could",
      "would", "should", "will", "please", "thanks", "hello", "okay", "yes", "also", "just", "then",
      "there", "here", "today", "tomorrow", "mr", "mrs", "ms", "dear",
    ] as [String])

  private static let complaintPattern =
    #"falsch (geschrieben|erkannt|transkribiert|diktiert)|schreibt man|heißt nicht|richtig geschrieben|schreibweise|buchstabier|(wrong(ly)?|incorrectly) (spelled|transcribed)|spelled (wrong|incorrectly)|misspell(ed|s)?"#
  private static let complaintRegex = try! NSRegularExpression(
    pattern: complaintPattern, options: [.caseInsensitive])
  private static let repeatRegex = try! NSRegularExpression(
    pattern: #"\b([^\W\d_]{3,})\b,?\s+nicht\s+\1\b"#, options: [.caseInsensitive])

  // MARK: - Text helpers

  static func tokens(_ text: String) -> [String] {
    text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
  }

  static func fold(_ s: String) -> String { GlossaryDocument.fold(s) }

  /// Lowercased with every non-letter, non-digit removed ("sabaki dance" == "sabaki.dance").
  static func compact(_ s: String) -> String {
    String(s.lowercased().filter { $0.isLetter || $0.isNumber })
  }

  static func isNameLike(_ t: String) -> Bool {
    guard t.count >= 4, let first = t.first else { return false }
    let shaped = first.isUppercase || t.contains(where: { $0.isNumber })
      || t.dropFirst().contains(where: { $0.isUppercase })
    return shaped && !stopwords.contains(fold(t))
  }

  /// Kölner Phonetik on the folded letters a-z (ä→a, ö→o, ü→u, ß→s; everything else dropped).
  /// H is dropped before adjacent duplicates collapse; zeros go except a leading one.
  static func cologne(_ s: String) -> String {
    let folded = fold(s).replacingOccurrences(of: "ß", with: "s")
    let letters: [Character] = folded.unicodeScalars
      .filter { $0.value >= 97 && $0.value <= 122 }.map { Character($0) }
    var codes: [Character] = []
    for i in 0..<letters.count {
      let c = letters[i]
      let prev: Character? = i > 0 ? letters[i - 1] : nil
      let next: Character? = i + 1 < letters.count ? letters[i + 1] : nil
      switch c {
      case "a", "e", "i", "j", "o", "u", "y": codes.append("0")
      case "h": break
      case "b": codes.append("1")
      case "p": codes.append(next == "h" ? "3" : "1")
      case "d", "t":
        codes.append(next.map { "csz".contains($0) } == true ? "8" : "2")
      case "f", "v", "w": codes.append("3")
      case "g", "k", "q": codes.append("4")
      case "c":
        if i == 0 {
          codes.append(next.map { "ahklqorux".contains($0) } == true ? "4" : "8")
        } else {
          let beforeOK = next.map { "ahkoqux".contains($0) } == true
          let afterSZ = prev.map { "sz".contains($0) } == true
          codes.append(beforeOK && !afterSZ ? "4" : "8")
        }
      case "x":
        if prev.map({ "ckq".contains($0) }) == true { codes.append("8") } else { codes.append(contentsOf: ["4", "8"]) }
      case "l": codes.append("5")
      case "m", "n": codes.append("6")
      case "r": codes.append("7")
      case "s", "z": codes.append("8")
      default: break
      }
    }
    var collapsed: [Character] = []
    for code in codes where collapsed.last != code { collapsed.append(code) }
    var out = ""
    for (i, code) in collapsed.enumerated() where i == 0 || code != "0" { out.append(code) }
    return out
  }

  // MARK: - Compute

  /// One config-history row of the whisper glossary or dictation section, as diffed against the
  /// previous row of the same section (the first row's `added` is its whole content).
  struct HistoryRow: Equatable {
    let ts: String
    let section: String
    let added: [String]
    let removed: [String]
  }

  /// One raw hit before merging. `base` is the source's score (sounds_like_known 200 / 150).
  private struct Hit {
    var heard: String
    let suggested: String?
    let source: Source
    let base: Int
    var alsoHeard: [String] = []
    var rows: [Int]? = nil
  }

  private struct Row {
    let ts: String
    let date: Date?
    let dictated: String?
    let typed: String?
    let dFold: [String]
    let tFold: [String]
  }

  private struct Target {
    let term: String
    let foldKey: String
    let parts: [String]
    let glossary: Bool
  }

  /// The pure core. `entries` arrive oldest first; the 7-day window is the caller's job.
  static func compute(
    entries: [InteractionLogEntry], signals: [SignalLogEntry], glossary: String,
    history: [HistoryRow], appNames: [String], isKnownWord: @escaping (String) -> Bool, now: Date = Date()
  ) -> [Candidate] {
    Run(
      entries: entries, signals: signals, glossary: glossary, history: history,
      appNames: appNames, isKnownWord: isKnownWord
    ).candidates()
  }

  private final class Run {
    let entries: [InteractionLogEntry]
    let signals: [SignalLogEntry]
    let isKnownRaw: (String) -> Bool
    var foldCache: [String: String] = [:]
    var cologneCache: [String: String] = [:]
    var knownCache: [String: Bool] = [:]

    let glossaryDoc: GlossaryDocument
    let glossaryHeads: [String]          // original spellings, document order, deduped by fold
    let glossaryHeadFolds: Set<String>
    let glossaryTokens: Set<String>
    let glossaryRejected: Set<String>
    let removedTokens: Set<String>
    let appNames: [String]
    let history: [HistoryRow]
    let glossaryText: String

    var rows: [Row] = []
    var transcriptions: [(entry: InteractionLogEntry, date: Date?)] = []

    // Dictated-text indexes (fold key → rows / exact spellings).
    var dictRows: [String: Set<Int>] = [:]
    var dictSpellings: [String: [String: Int]] = [:]
    var dictBigramRows: [String: Set<Int>] = [:]
    var dictBigramSpellings: [String: [String: Int]] = [:]
    var dictExactRows: [String: Int] = [:]
    var dictNameLikeOrder: [String] = []
    // Union (dictated + typed) index: fold unigram → row indexes ascending.
    var unionIndex: [String: [Int]] = [:]

    init(
      entries: [InteractionLogEntry], signals: [SignalLogEntry], glossary: String,
      history: [HistoryRow], appNames: [String], isKnownWord: @escaping (String) -> Bool
    ) {
      self.history = history
      self.glossaryText = glossary
      self.entries = entries
      self.signals = signals
      self.isKnownRaw = isKnownWord
      let doc = GlossaryDocument.parse(glossary)
      glossaryDoc = doc
      var heads: [String] = []
      var headFolds = Set<String>()
      var tokenFolds = Set<String>()
      var rejected = Set<String>()
      for entry in doc.entries {
        let f = GlossaryDocument.fold(entry.term)
        if headFolds.insert(f).inserted { heads.append(entry.term) }
        for t in DictationCandidates.tokens(entry.term) { tokenFolds.insert(GlossaryDocument.fold(t)) }
        for r in entry.rejectedSpellings { rejected.insert(GlossaryDocument.fold(r)) }
      }
      glossaryHeads = heads
      glossaryHeadFolds = headFolds
      glossaryTokens = tokenFolds
      glossaryRejected = rejected
      var removed = Set<String>()
      for line in history.flatMap({ $0.removed }) {
        for t in DictationCandidates.tokens(line) where t.count >= 3 {
          removed.insert(GlossaryDocument.fold(t))
        }
      }
      removedTokens = removed
      var seenApps = Set<String>()
      self.appNames = appNames.filter { !$0.isEmpty && seenApps.insert(GlossaryDocument.fold($0)).inserted }
        .sorted { GlossaryDocument.fold($0) < GlossaryDocument.fold($1) }
      buildRows()
      buildIndexes()
    }

    // MARK: caches

    func fold(_ s: String) -> String {
      if let hit = foldCache[s] { return hit }
      let value = GlossaryDocument.fold(s)
      foldCache[s] = value
      return value
    }

    func cologne(_ s: String) -> String {
      if let hit = cologneCache[s] { return hit }
      let value = DictationCandidates.cologne(s)
      cologneCache[s] = value
      return value
    }

    func known(_ w: String) -> Bool {
      if let hit = knownCache[w] { return hit }
      let value = isKnownRaw(w)
      knownCache[w] = value
      return value
    }

    /// The fast learner's rule.
    func levClose(_ a: String, _ b: String) -> Bool {
      let fa = fold(a), fb = fold(b)
      guard fa != fb, let ca = fa.first, ca == fb.first else { return false }
      if abs(fa.count - fb.count) > 2 { return false }
      if GlossaryFastLearner.isInflectionalVariant(fa, fb) { return false }
      let limit = min(fa.count, fb.count) >= 8 ? 2 : 1
      return GlossaryFastLearner.levenshtein(fa, fb, limit: limit) != nil
    }

    static let phoneticFirstPairs: Set<String> = ["sz", "ck", "vw", "fv", "bp", "dt", "gk"]

    func close(_ a: String, _ b: String) -> Bool {
      if levClose(a, b) { return true }
      let fa = fold(a), fb = fold(b)
      guard fa != fb, fa.count >= 5, fb.count >= 5, abs(fa.count - fb.count) <= 2 else { return false }
      if GlossaryFastLearner.isInflectionalVariant(fa, fb) { return false }
      let ka = cologne(a), kb = cologne(b)
      guard !ka.isEmpty, ka == kb else { return false }
      if fa.prefix(2) == fb.prefix(2) { return true }
      guard let x = fa.first, let y = fb.first else { return false }
      return Run.phoneticFirstPairs.contains(String([x, y]).sorted().map(String.init).joined())
    }

    // MARK: rows

    static func collapse(_ s: String) -> String {
      s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    func buildRows() {
      for entry in entries where entry.mode == InteractionMode.transcription.rawValue {
        transcriptions.append((entry, UserContextLog.timestamp(entry.ts)))
      }
      let transcriptTexts: [(date: Date?, text: String)] = transcriptions.map {
        ($0.date, Run.collapse(fold($0.entry.result ?? "")))
      }
      for entry in entries {
        var dictated: String?
        var typed: String?
        switch entry.mode {
        case InteractionMode.transcription.rawValue: dictated = entry.result
        case InteractionMode.prompt.rawValue: dictated = entry.userInstruction
        case InteractionMode.chat.rawValue:
          typed = typedText(of: entry, transcriptTexts: transcriptTexts)
        default: break
        }
        if let d = dictated, d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { dictated = nil }
        guard dictated != nil || typed != nil else { continue }
        rows.append(Row(
          ts: entry.ts, date: UserContextLog.timestamp(entry.ts), dictated: dictated, typed: typed,
          dFold: DictationCandidates.tokens(dictated ?? "").map(fold),
          tFold: DictationCandidates.tokens(typed ?? "").map(fold)))
      }
    }

    func typedText(of entry: InteractionLogEntry, transcriptTexts: [(date: Date?, text: String)]) -> String? {
      guard var text = entry.userInstruction else { return nil }
      for tag in ["<typed_by_user>", "</typed_by_user>", "<pasted_content>", "</pasted_content>"] {
        text = text.replacingOccurrences(of: tag, with: "")
      }
      text = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return nil }
      let needle = Run.collapse(fold(text))
      if let date = UserContextLog.timestamp(entry.ts) {
        for t in transcriptTexts {
          guard let other = t.date, abs(other.timeIntervalSince(date)) <= 180 else { continue }
          if t.text == needle || t.text.contains(needle) { return nil }
        }
      }
      return text
    }

    func buildIndexes() {
      var nameLikeSeen = Set<String>()
      for (index, row) in rows.enumerated() {
        var union = Set<String>()
        for f in row.dFold { union.insert(f) }
        for f in row.tFold { union.insert(f) }
        for f in union { unionIndex[f, default: []].append(index) }
        guard let dictated = row.dictated else { continue }
        let toks = DictationCandidates.tokens(dictated)
        var seenExact = Set<String>()
        var seenFold = Set<String>()
        for t in toks {
          if seenExact.insert(t).inserted {
            dictExactRows[t, default: 0] += 1
            dictSpellings[fold(t), default: [:]][t, default: 0] += 1
            if DictationCandidates.isNameLike(t) && nameLikeSeen.insert(t).inserted {
              dictNameLikeOrder.append(t)
            }
          }
          if seenFold.insert(fold(t)).inserted { dictRows[fold(t), default: []].insert(index) }
        }
        var seenBigramExact = Set<String>()
        var seenBigramFold = Set<String>()
        if toks.count >= 2 {
          for i in 0..<(toks.count - 1) {
            let exact = toks[i] + " " + toks[i + 1]
            let key = fold(toks[i]) + " " + fold(toks[i + 1])
            if seenBigramExact.insert(exact).inserted {
              dictBigramSpellings[key, default: [:]][exact, default: 0] += 1
            }
            if seenBigramFold.insert(key).inserted { dictBigramRows[key, default: []].insert(index) }
          }
        }
      }
    }

    func rowsContaining(_ phrase: String) -> [Int] {
      let parts = DictationCandidates.tokens(phrase).map(fold)
      guard let first = parts.first else { return [] }
      let candidates = unionIndex[first] ?? []
      if parts.count == 1 { return candidates }
      return candidates.filter { Run.hasSequence(parts, in: rows[$0].dFold) || Run.hasSequence(parts, in: rows[$0].tFold) }
    }

    static func hasSequence(_ seq: [String], in list: [String]) -> Bool {
      guard !seq.isEmpty, list.count >= seq.count else { return false }
      for i in 0...(list.count - seq.count) where Array(list[i..<(i + seq.count)]) == seq { return true }
      return false
    }

    /// Most frequent spelling; ties go to the smaller string.
    static func best(_ spellings: [String: Int]) -> String? {
      spellings.min { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }?.key
    }

    // MARK: sources

    func hits() -> [Hit] {
      var out: [Hit] = []
      out += selfComplaints()
      out += glossaryNotWorking()
      out += typedCorrections()
      out += retryDiffs()
      out += soundsLikeKnown()
      let variants = spellingVariants()
      out += variants
      out += unknownRecurring()
      return out
    }

    static func sentences(_ text: String) -> [String] {
      var out: [String] = []
      var current = ""
      func flush() {
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current) }
        current = ""
      }
      for c in text {
        if c.isNewline || c == "!" || c == "?" {
          flush()
        } else if c == "." {
          let tail = Array(current.suffix(3))
          var abbreviation = false
          if tail.count >= 2 {
            let two = String(tail.suffix(2))
            let before: Character? = tail.count == 3 ? tail[0] : nil
            if ["Dr", "Fr", "Hr", "St"].contains(two), before.map({ !$0.isLetter }) ?? true {
              abbreviation = true
            }
          }
          if abbreviation { current.append(c) } else { flush() }
        } else {
          current.append(c)
        }
      }
      flush()
      return out
    }

    static func tokenRanges(_ s: String) -> [Range<String.Index>] {
      var out: [Range<String.Index>] = []
      var start: String.Index?
      var i = s.startIndex
      while i < s.endIndex {
        let ch = s[i]
        if ch.isLetter || ch.isNumber {
          if start == nil { start = i }
        } else if let st = start {
          out.append(st..<i)
          start = nil
        }
        i = s.index(after: i)
      }
      if let st = start { out.append(st..<s.endIndex) }
      return out
    }

    func selfComplaints() -> [Hit] {
      var out: [Hit] = []
      for row in rows {
        for text in [row.dictated, row.typed].compactMap({ $0 }) {
          for sentence in Run.sentences(text) {
            let ns = NSRange(sentence.startIndex..., in: sentence)
            var heard: String?
            if let m = DictationCandidates.repeatRegex.firstMatch(in: sentence, range: ns),
              let gr = Range(m.range(at: 1), in: sentence)
            {
              let candidate = String(sentence[gr])
              guard !DictationCandidates.stopwords.contains(fold(candidate)) else { continue }
              let nearHead = glossaryHeads.contains { close(candidate, $0) }
              let isKnown = known(candidate)
              guard !isKnown || nearHead else { continue }
              heard = candidate
            } else if let match = DictationCandidates.complaintRegex.firstMatch(in: sentence, range: ns),
              let mr = Range(match.range, in: sentence)
            {
              let ranges = Run.tokenRanges(sentence)
              func eligible(_ r: Range<String.Index>) -> Bool {
                let t = String(sentence[r])
                guard t.count >= 3, let first = t.first else { return false }
                let shaped = first.isUppercase || t.contains(where: { $0.isNumber })
                  || t.dropFirst().contains(where: { $0.isUppercase })
                return shaped && !DictationCandidates.stopwords.contains(fold(t))
              }
              var found: String?
              if let r = ranges.last(where: { $0.lowerBound < mr.lowerBound && eligible($0) }) {
                found = String(sentence[r])
              } else if let r = ranges.first(where: { $0.lowerBound >= mr.upperBound && eligible($0) }) {
                found = String(sentence[r])
              }
              guard let candidate = found else { continue }
              let nearHead = glossaryHeads.contains { close(candidate, $0) }
              let isKnown = known(candidate)
              guard !isKnown || nearHead else { continue }
              heard = candidate
            }
            guard let heard else { continue }
            let near = glossaryHeads.filter { close(heard, $0) }
            out.append(Hit(
              heard: heard, suggested: near.count == 1 ? near[0] : nil,
              source: .selfComplaint, base: 1000))
          }
        }
      }
      return out
    }

    /// A rejected spelling still dictated after its `(not "…")` annotation was written.
    func glossaryNotWorking() -> [Hit] {
      var out: [Hit] = []
      var seen = Set<String>()
      for line in glossaryText.components(separatedBy: .newlines) {
        let rejected = GlossaryDocument.rejectedSpellings(on: line)
        guard !rejected.isEmpty else { continue }
        let heads = GlossaryDocument.lineTermText(line).components(separatedBy: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let head = heads.last else { continue }
        for x in rejected where seen.insert(fold(x)).inserted {
          let xf = fold(x)
          // Newest history row of the glossary whose added lines carry x inside (not "…").
          var annotated: Date?
          for h in history where h.section == "whisper_glossary" {
            let carries = h.added.contains { line in
              GlossaryDocument.rejectedSpellings(on: line).contains { fold($0) == xf }
            }
            if carries, let d = UserContextLog.timestamp(h.ts) { annotated = d }
          }
          guard let since = annotated else { continue }
          let parts = DictationCandidates.tokens(x).map(fold)
          guard !parts.isEmpty else { continue }
          var hitRows: [Int] = []
          for (i, row) in rows.enumerated() {
            guard row.dictated != nil, let d = row.date, d > since,
              Run.hasSequence(parts, in: row.dFold)
            else { continue }
            hitRows.append(i)
          }
          if hitRows.count >= 2 {
            out.append(Hit(heard: x, suggested: head, source: .glossaryNotWorking, base: 800, rows: hitRows))
          }
        }
      }
      return out
    }

    func typedCorrections() -> [Hit] {
      var out: [Hit] = []
      var seen = Set<String>()
      for row in rows {
        guard let typed = row.typed else { continue }
        var rowSeen = Set<String>()
        for t in DictationCandidates.tokens(typed)
        where t.count >= 4 && t.first?.isUppercase == true && rowSeen.insert(t).inserted
          && seen.insert(t).inserted
        {
          let tf = fold(t)
          if glossaryHeadFolds.contains(tf) || glossaryTokens.contains(tf) { continue }
          let typedCount = dictExactRows[t] ?? 0
          var bestD: String?
          var bestCount = -1
          for d in dictNameLikeOrder where d != t && levClose(t, d) {
            let c = dictExactRows[d] ?? 0
            if c > bestCount { bestD = d; bestCount = c }
          }
          guard let d = bestD, typedCount < bestCount else { continue }
          let kt = known(t)
          let kd = known(d)
          if kt && kd { continue }
          out.append(Hit(heard: d, suggested: t, source: .typedCorrection, base: 500))
        }
      }
      return out
    }

    func retryDiffs() -> [Hit] {
      var out: [Hit] = []
      for signal in signals where signal.kind == OutcomeSignal.dictationRestart.rawValue {
        guard let ref = signal.refTs,
          let ai = transcriptions.firstIndex(where: { $0.entry.ts == ref }),
          ai + 1 < transcriptions.count
        else { continue }
        let a = transcriptions[ai], b = transcriptions[ai + 1]
        guard let ad = a.date, let bd = b.date, bd.timeIntervalSince(ad) <= 120 else { continue }
        let aTokens = DictationCandidates.tokens(a.entry.result ?? "")
        let bTokens = DictationCandidates.tokens(b.entry.result ?? "")
        let aFolds = Set(aTokens.map(fold))
        let bFolds = Set(bTokens.map(fold))
        var seen = Set<String>()
        for t in aTokens where DictationCandidates.isNameLike(t) && seen.insert(t).inserted {
          guard !bFolds.contains(fold(t)) else { continue }
          if let match = bTokens.first(where: {
            $0.count >= 4 && !aFolds.contains(fold($0)) && close(t, $0)
          }) {
            let ka = known(t)
            let kb = known(match)
            if ka && kb { continue }
            out.append(Hit(heard: t, suggested: match, source: .retryDiff, base: 300))
          }
        }
      }
      return out
    }

    func targets() -> [Target] {
      var out: [Target] = []
      var seen = Set<String>()
      func add(_ term: String, glossary: Bool) {
        let parts = DictationCandidates.tokens(term)
        let key = parts.map(fold).joined(separator: " ")
        guard !key.isEmpty, seen.insert(key).inserted else { return }
        let eligible = (parts.count == 1 && parts[0].count >= 4) || parts.count == 2
        guard eligible else { return }
        out.append(Target(term: term, foldKey: key, parts: parts.map(fold), glossary: glossary))
      }
      for head in glossaryHeads { add(head, glossary: true) }
      for term in DictationCandidates.productVocabulary { add(term, glossary: false) }
      for app in appNames { add(app, glossary: false) }
      return out
    }

    func soundsLikeKnown() -> [Hit] {
      var out: [Hit] = []
      let unigramKeys = dictRows.keys.filter { (dictRows[$0]?.count ?? 0) >= 2 }.sorted()
      let bigramKeys = dictBigramRows.keys.filter { (dictBigramRows[$0]?.count ?? 0) >= 2 }.sorted()
      for v in targets() {
        let base = v.glossary ? 200 : 150
        if v.parts.count == 1 {
          for key in unigramKeys {
            guard let spelling = Run.best(dictSpellings[key] ?? [:]),
              close(spelling, v.term)
            else { continue }
            if known(spelling) { continue }
            out.append(Hit(heard: spelling, suggested: v.term, source: .soundsLikeKnown, base: base))
          }
        } else {
          for key in bigramKeys {
            let kp = key.components(separatedBy: " ")
            guard kp.count == 2 else { continue }
            let p0 = kp[0] == v.parts[0] || close(kp[0], v.parts[0])
            let p1 = kp[1] == v.parts[1] || close(kp[1], v.parts[1])
            guard p0, p1, kp[0] != v.parts[0] || kp[1] != v.parts[1],
              let spelling = Run.best(dictBigramSpellings[key] ?? [:])
            else { continue }
            out.append(Hit(heard: spelling, suggested: v.term, source: .soundsLikeKnown, base: base))
          }
        }
      }
      return out
    }

    /// Fold keys with at least one name-like spelling, sorted, and their name-like heard spelling.
    func nameKeys() -> [(key: String, spelling: String)] {
      var out: [(String, String)] = []
      for key in dictSpellings.keys.sorted() {
        let nameLike = (dictSpellings[key] ?? [:]).filter { DictationCandidates.isNameLike($0.key) }
        if let spelling = Run.best(nameLike) { out.append((key, spelling)) }
      }
      return out
    }

    /// The spelling judged for unknown-ness: the most frequent name-like one; when the oracle calls it a
    /// known word, the most frequent name-like spelling with >= 2 rows that is unknown ("AutoMagic" is
    /// known to the checker, "Automagic" is not). Nil when there is none.
    func unknownSpelling(key: String, spelling: String) -> String? {
      if !known(spelling) { return spelling }
      let alts = (dictSpellings[key] ?? [:]).filter {
        $0.value >= 2 && DictationCandidates.isNameLike($0.key) && !known($0.key)
      }
      return Run.best(alts)
    }

    /// Connected components under `close` among `keys` (tokens are their own first spelling).
    func components(_ keys: [(key: String, spelling: String)]) -> [[Int]] {
      var parent = Array(0..<keys.count)
      func find(_ x: Int) -> Int {
        var r = x
        while parent[r] != r { r = parent[r] }
        var c = x
        while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
        return r
      }
      for x in 0..<keys.count {
        for y in (x + 1)..<max(keys.count, x + 1) where close(keys[x].spelling, keys[y].spelling) {
          let rx = find(x), ry = find(y)
          if rx != ry { parent[max(rx, ry)] = min(rx, ry) }
        }
      }
      var comps: [Int: [Int]] = [:]
      for i in 0..<keys.count { comps[find(i), default: []].append(i) }
      return comps.keys.sorted().map { comps[$0]! }
    }

    func spellingVariants() -> [Hit] {
      let all = nameKeys()
      func union(_ members: [Int], _ keys: [(key: String, spelling: String)]) -> Int {
        var rowsUnion = Set<Int>()
        for m in members { rowsUnion.formUnion(dictRows[keys[m].key] ?? []) }
        return rowsUnion.count
      }
      var pool: [(key: String, spelling: String)] = []
      for comp in components(all) where comp.count >= 2 && union(comp, all) >= 3 {
        for m in comp { pool.append(all[m]) }
      }
      pool.sort { $0.key < $1.key }
      let unknownPool = pool.compactMap { entry in
        unknownSpelling(key: entry.key, spelling: entry.spelling).map { (key: entry.key, spelling: $0) }
      }
      var out: [Hit] = []
      for comp in components(unknownPool) where comp.count >= 2 && union(comp, unknownPool) >= 3 {
        let members = comp.map { unknownPool[$0] }.sorted { a, b in
          let ra = dictRows[a.key]?.count ?? 0, rb = dictRows[b.key]?.count ?? 0
          return ra != rb ? ra > rb : a.spelling < b.spelling
        }
        out.append(Hit(
          heard: members[0].spelling, suggested: nil, source: .spellingVariants, base: 100,
          alsoHeard: members.dropFirst().map { $0.spelling }))
      }
      return out
    }

    func unknownRecurring() -> [Hit] {
      var out: [Hit] = []
      for (key, spelling) in nameKeys() where (dictRows[key]?.count ?? 0) >= 3 {
        if let unknown = unknownSpelling(key: key, spelling: spelling) {
          out.append(Hit(heard: unknown, suggested: nil, source: .unknownRecurring, base: 0))
        }
      }
      return out
    }

    /// Most frequent exact spelling of `heard` over the rows containing it (distinct rows per
    /// spelling, dictated and typed text); ties go to the smaller string.
    func majorityCasing(_ heard: String) -> String {
      let n = DictationCandidates.tokens(heard).count
      guard n > 0 else { return heard }
      let parts = DictationCandidates.tokens(heard).map(fold)
      var counts: [String: Int] = [:]
      for index in rowsContaining(heard) {
        let row = rows[index]
        guard let text = row.dictated ?? row.typed else { continue }
        let toks = DictationCandidates.tokens(text)
        let folds = toks.map(fold)
        var seen = Set<String>()
        if folds.count >= n {
          for i in 0...(folds.count - n) where Array(folds[i..<(i + n)]) == parts {
            seen.insert(toks[i..<(i + n)].joined(separator: " "))
          }
        }
        for spelling in seen { counts[spelling, default: 0] += 1 }
      }
      return Run.best(counts) ?? heard
    }

    // MARK: merge, filter, rank

    func candidates() -> [Candidate] {
      var merged: [String: Hit] = [:]
      for hit in hits() {
        let key = fold(hit.heard)
        if let existing = merged[key] {
          if hit.source.rank < existing.source.rank
            || (hit.source.rank == existing.source.rank && hit.base > existing.base)
          {
            merged[key] = hit
          }
        } else {
          merged[key] = hit
        }
      }
      var survivors: [(hit: Hit, rows: [Int])] = []
      for key in merged.keys.sorted() {
        let hit = merged[key]!
        let suggestedFold = hit.suggested.map(fold)
        let suggestedIsHead = suggestedFold.map { glossaryHeadFolds.contains($0) } ?? false
        let keepForGlossary =
          (hit.source == .soundsLikeKnown || hit.source == .selfComplaint) && suggestedIsHead
        if glossaryRejected.contains(key) && hit.source != .glossaryNotWorking { continue }
        if hit.source == .spellingVariants || hit.source == .unknownRecurring,
          hit.alsoHeard.contains(where: { glossaryRejected.contains(fold($0)) })
        {
          continue
        }
        if glossaryHeadFolds.contains(key) || glossaryTokens.contains(key) { continue }
        if removedTokens.contains(key) { continue }
        if let s = suggestedFold, removedTokens.contains(s) { continue }
        if DictationCandidates.tokens(hit.heard).allSatisfy({ DictationCandidates.stopwords.contains(fold($0)) }) {
          continue
        }
        let rows = hit.rows ?? rowsContaining(hit.heard)
        // `heard` is the majority casing in the log, so it always equals itself: a fold-equal
        // suggestion is dropped unless the glossary entry is the suggested head.
        if !keepForGlossary, let s = suggestedFold, s == key { continue }
        // A suggestion that differs only in case, spacing or punctuation is no finding.
        if let sug = hit.suggested, DictationCandidates.compact(hit.heard) == DictationCandidates.compact(sug) {
          continue
        }
        var recased = hit
        recased.heard = majorityCasing(hit.heard)
        survivors.append((recased, rows))
      }
      var alsoKeys = Set<String>()
      for s in survivors { for a in s.hit.alsoHeard { alsoKeys.insert(fold(a)) } }
      let ranked = survivors
        .filter { !alsoKeys.contains(fold($0.hit.heard)) }
        .map { entry -> (Candidate, Int) in
          let ids = entry.rows.reversed().prefix(5).map { rows[$0].ts }
          let candidate = Candidate(
            heard: entry.hit.heard, suggested: entry.hit.suggested, source: entry.hit.source,
            count: entry.rows.count, rowIds: Array(ids), alsoHeard: entry.hit.alsoHeard)
          return (candidate, entry.hit.base + 10 * min(entry.rows.count, 20))
        }
        .sorted { a, b in
          if a.1 != b.1 { return a.1 > b.1 }
          if a.0.count != b.0.count { return a.0.count > b.0.count }
          return a.0.heard < b.0.heard
        }
      var usedSuggestions = Set<String>()
      var kept: [Candidate] = []
      for (candidate, _) in ranked {
        if let suggested = candidate.suggested, !usedSuggestions.insert(fold(suggested)).inserted { continue }
        kept.append(candidate)
      }
      return Array(kept.prefix(DictationCandidates.maxCandidates))
    }
  }

  // MARK: - Live

  /// Diffs of the whisper glossary and dictation history rows against the previous row of the same
  /// stored section (the first row's whole content counts as added), any age, oldest first.
  static func historyRows(_ rows: [UnifiedSystemPromptHistoryEntry]) -> [HistoryRow] {
    var previous: [String: String] = [:]
    var out: [HistoryRow] = []
    for row in rows {
      let name = ConfigHistoryQuery.name(forStoredSection: row.section)
      if name == "whisper_glossary" || name == "dictation" {
        let diff = ConfigHistoryReader.lineDiff(old: previous[row.section] ?? "", new: row.content)
        out.append(HistoryRow(ts: row.ts, section: name, added: diff.added, removed: diff.removed))
      }
      previous[row.section] = row.content
    }
    return out
  }

  /// The review's list for this Mac, JSON-ready. Log loading and both compute passes run off the
  /// main actor; only the NSSpellChecker lookups (main thread only) hop onto it. The words the core
  /// asks about are collected first (a run with every word unknown, capped at `maxSpellCheckWords`),
  /// checked in one batch, and the core runs again with a set lookup. Words past the cap count as
  /// known, so they can never surface as unknown_recurring.
  static func liveAsync(now: Date = Date()) async -> [[String: Any]] {
    let started = Date()
    let prepared = await Task.detached(priority: .userInitiated) { () -> Prepared in
      let query = InteractionLogQuery()
      let loaded = InteractionLogReader.load(query, now: now)
      let windowStart = query.windowStart(now: now)
      let entries = loaded.entries.filter { LogWindowArgs.isAtOrAfter(since: windowStart, ts: $0.ts) }
      let signals = loaded.signals.filter { LogWindowArgs.isAtOrAfter(since: windowStart, ts: $0.ts) }
      let glossary = SystemPromptsStore.shared.loadWhisperGlossary()
      let history = historyRows(ConfigHistoryReader.load())
      let apps = entries.compactMap { $0.appName }
      var asked: [String] = []
      var askedSet = Set<String>()
      _ = compute(
        entries: entries, signals: signals, glossary: glossary, history: history, appNames: apps,
        isKnownWord: { word in
          if asked.count < maxSpellCheckWords, askedSet.insert(word).inserted { asked.append(word) }
          return true
        }, now: now)
      return Prepared(
        entries: entries, signals: signals, glossary: glossary, history: history, apps: apps,
        words: asked)
    }.value

    let words = prepared.words
    let unknown: Set<String> = await MainActor.run {
      // Without both dictionaries every word reads as unknown; treat them all as known then.
      guard GlossaryFastLearner.dictationDictionariesAvailable() else { return [] }
      return Set(words.filter { !GlossaryFastLearner.isKnownWordInDictationLanguages($0) })
    }
    let result = await Task.detached(priority: .userInitiated) { () -> [Candidate] in
      compute(
        entries: prepared.entries, signals: prepared.signals, glossary: prepared.glossary,
        history: prepared.history, appNames: prepared.apps,
        isKnownWord: { !unknown.contains($0) }, now: now)
    }.value
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    DebugLogger.log(
      "IMPROVE-CANDIDATES: rows=\(prepared.entries.count) signals=\(prepared.signals.count) spellchecked=\(words.count) candidates=\(result.count) ms=\(ms)")
    return result.map { $0.json }
  }

  private struct Prepared: @unchecked Sendable {
    let entries: [InteractionLogEntry]
    let signals: [SignalLogEntry]
    let glossary: String
    let history: [HistoryRow]
    let apps: [String]
    let words: [String]
  }
}
