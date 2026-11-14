//
//  WritingStyleImporter.swift
//  WhisperShortcut
//
//  Fills the writing-style pool from Gmail "Sent" and derives the per-context profile with the
//  Writing Style model (stored under `selectedImprovementModel`). Only text the user wrote is kept: quoted replies, signatures and
//  forwards are cut before anything is stored. See plans/active/writing-style.md.
//

import Foundation

enum WritingStyleImporter {

  enum ImportError: LocalizedError {
    case offlineMode
    case googleNotConnected
    case noSamples

    var errorDescription: String? {
      switch self {
      case .offlineMode:
        return String(localized: "Not available in Offline Mode.")
      case .googleNotConnected:
        return String(localized: "Connect your Google account in Settings first.")
      case .noSamples:
        return String(localized: "No example messages yet. Import sent emails or add examples first.")
      }
    }
  }

  private static let threadFetchConcurrency = 5

  // MARK: - Gmail Import

  struct ImportResult {
    let added: Int
    /// Threads that could not be read (rate limit, server error). The import is partial then.
    let failedThreads: Int

    var summary: String {
      failedThreads == 0
        ? String(localized: "Imported \(added) new messages.")
        : String(localized: "Imported \(added) new messages; \(failedThreads) threads could not be read, try again later for the rest.")
    }
  }

  /// Imports up to `maxMessages` sent emails from the last year.
  static func importFromGmail(maxMessages: Int = 200) async throws -> ImportResult {
    guard !OfflineMode.isEnabled else { throw ImportError.offlineMode }
    guard await GoogleAccountOAuthService.shared.isConnected else {
      throw ImportError.googleNotConnected
    }

    let refs = try await GmailAPIClient.shared.listMessageRefs(
      query: "in:sent newer_than:365d -in:chats", maxTotal: maxMessages)
    let sentIDs = Set(refs.map(\.id))
    var threadIDs: [String] = []
    for ref in refs where !threadIDs.contains(ref.threadId) { threadIDs.append(ref.threadId) }

    var samples: [WritingSample] = []
    var failed = 0
    for batchStart in stride(from: 0, to: threadIDs.count, by: threadFetchConcurrency) {
      try Task.checkCancellation()
      let batch = threadIDs[batchStart..<min(batchStart + threadFetchConcurrency, threadIDs.count)]
      let threads = await withTaskGroup(of: [[String: Any]]?.self) { group in
        for id in batch {
          group.addTask { try? await GmailAPIClient.shared.readThread(threadId: id) }
        }
        var result: [[[String: Any]]?] = []
        for await thread in group { result.append(thread) }
        return result
      }
      try Task.checkCancellation()
      for thread in threads {
        guard let thread else { failed += 1; continue }
        samples.append(contentsOf: samplesFromThread(thread, sentIDs: sentIDs))
      }
    }

    samples = stripRepeatedSignatures(samples)
    let added = WritingStyleStore.shared.addSamples(samples)
    UserDefaults.standard.set(Date(), forKey: UserDefaultsKeys.writingStyleLastGmailImportAt)
    DebugLogger.log(
      "WRITING-STYLE-IMPORT: sent=\(refs.count) threads=\(threadIDs.count) failed=\(failed) kept=\(samples.count) added=\(added)")
    return ImportResult(added: added, failedThreads: failed)
  }

  /// The user's sent messages in one thread, each paired with the length of the message it
  /// answered (the latest earlier message the user did not send).
  static func samplesFromThread(_ messages: [[String: Any]], sentIDs: Set<String>) -> [WritingSample] {
    var samples: [WritingSample] = []
    var lastIncomingChars: Int?
    let ordered = messages.sorted { dateMillis($0) < dateMillis($1) }
    for message in ordered {
      let labels = message["labels"] as? [String] ?? []
      let body = message["body"] as? String ?? ""
      // An unsent draft is neither the user's sent voice nor a message they answered.
      if labels.contains("DRAFT") { continue }
      guard labels.contains("SENT") else {
        lastIncomingChars = cleanBody(body).map(\.count)
        continue
      }
      guard let id = message["message_id"] as? String, sentIDs.contains(id),
        !isForward(subject: message["subject"] as? String),
        let text = cleanSentBody(body)
      else { continue }
      samples.append(WritingSample(
        id: id,
        context: .email,
        source: "gmail",
        recipient: firstAddress(in: message["to"] as? String),
        sentAt: Date(timeIntervalSince1970: Double(dateMillis(message)) / 1000),
        incomingChars: lastIncomingChars,
        text: text))
    }
    return samples
  }

  private static func dateMillis(_ message: [String: Any]) -> Int64 {
    Int64(message["internal_date_ms"] as? String ?? "") ?? 0
  }

  static func isForward(subject: String?) -> Bool {
    guard let subject = subject?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
    return ["fwd:", "fw:", "wg:"].contains { subject.hasPrefix($0) }
  }

  static func firstAddress(in header: String?) -> String? {
    guard let header,
      let range = header.range(of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                               options: [.regularExpression, .caseInsensitive])
    else { return nil }
    return header[range].lowercased()
  }

  // MARK: - Cleaning

  /// Only what the user wrote in this message, or nil when too short/long to be a useful example.
  static func cleanSentBody(_ raw: String) -> String? {
    guard let text = cleanBody(raw), text.count >= 15, text.count <= 4_000 else { return nil }
    return text
  }

  /// Everything before the quoted reply, forward header or signature, without `>` lines.
  static func cleanBody(_ raw: String) -> String? {
    var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
    if text.range(of: #"</?(div|p|br|html|body|span)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
      text = plainText(fromHTML: text)
    }

    var cut = text.endIndex
    // A reply header is a line that starts with On/Am, carries a date and ENDS in "wrote:" /
    // "schrieb …:". Matching within single lines keeps a sentence of the user's ("Am Donnerstag um
    // 14 Uhr passt mir.") from becoming the cut point. The second pattern allows the one wrap mail
    // clients produce ("On …, Name <\nmail> wrote:"), only after a line without closing punctuation.
    let cutPatterns = [
      #"(?m)^[ \t]*(On|Am)\b[^\n]*\d[^\n]*(wrote|schrieb[^\n]*):[ \t]*$"#,
      #"(?m)^[ \t]*(On|Am)\b[^\n]*\d[^\n]*[^.!?\n][ \t]*\n(?![ \t]*(On|Am)\b)[^\n]{0,120}(wrote|schrieb[^\n]*):[ \t]*$"#,
      #"(?m)^[ \t]*-{2,}[ \t]*(Original Message|Ursprüngliche Nachricht|Forwarded message|Weitergeleitete Nachricht)"#,
      #"(?m)^[ \t]*_{10,}[ \t]*$"#,  // Outlook separator above the quoted message
      #"(?m)^-- ?$"#,
      #"(?m)^[ \t]*(Sent from my (iPhone|iPad)|Von meinem (iPhone|iPad) gesendet|Gesendet von meinem (iPhone|iPad))"#,
      // Outlook header block: From/Von followed within three lines by another header field, so
      // "Von: 10 Uhr" in the user's own text is not taken for one.
      #"(?m)^[ \t]*(From|Von):[ \t][^\n]+\n(?:[^\n]*\n){0,2}[ \t]*(Sent|Gesendet|Date|Datum|To|An|Subject|Betreff):"#,
    ]
    for pattern in cutPatterns {
      if let range = text.range(of: pattern, options: .regularExpression), range.lowerBound < cut {
        cut = range.lowerBound
      }
    }
    text = String(text[..<cut])

    text = text.components(separatedBy: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
      .joined(separator: "\n")
    text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private static func plainText(fromHTML html: String) -> String {
    var text = html
    let replacements: [(String, String)] = [
      (#"(?is)<(style|script|head)\b.*?</\1>"#, ""),
      (#"(?is)<div class="gmail_quote.*"#, ""),  // Gmail puts the quoted thread last
      (#"(?i)<br\s*/?>"#, "\n"),
      (#"(?i)</(p|div|li|tr|h[1-6])>"#, "\n"),
      (#"<[^>]+>"#, ""),
    ]
    for (pattern, replacement) in replacements {
      text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    return decodeEntities(text)
  }

  /// Named and numeric HTML entities. `&amp;` goes last so "&amp;lt;" stays the literal "&lt;".
  static func decodeEntities(_ html: String) -> String {
    var text = html
    let named = [
      "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
      "&ndash;": "–", "&mdash;": "—", "&lsquo;": "‘", "&rsquo;": "’", "&ldquo;": "“",
      "&rdquo;": "”", "&hellip;": "…", "&auml;": "ä", "&ouml;": "ö", "&uuml;": "ü",
      "&Auml;": "Ä", "&Ouml;": "Ö", "&Uuml;": "Ü", "&szlig;": "ß", "&euro;": "€",
    ]
    for (entity, char) in named { text = text.replacingOccurrences(of: entity, with: char) }
    for (pattern, radix) in [(#"&#([0-9]{1,7});"#, 10), (#"&#[xX]([0-9a-fA-F]{1,6});"#, 16)] {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let ns = text as NSString
      var result = ""
      var last = 0
      for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
        let digits = ns.substring(with: match.range(at: 1))
        if let code = UInt32(digits, radix: radix), let scalar = Unicode.Scalar(code) {
          result.unicodeScalars.append(scalar)
        } else {
          result += ns.substring(with: match.range)
        }
        last = match.range.location + match.range.length
      }
      result += ns.substring(from: last)
      text = result
    }
    return text.replacingOccurrences(of: "&amp;", with: "&")
  }

  // MARK: - Signatures

  /// Strips corporate signatures that repeat at the end of several messages. A repeated block is
  /// cut only from its first contact-looking line (phone, email, URL, company form), so a
  /// recurring sign-off like "Viele Grüße\nMagnus" above it — which is the user's voice — stays.
  static func stripRepeatedSignatures(_ samples: [WritingSample], minRepeats: Int = 3) -> [WritingSample] {
    let maxBlock = 8
    var suffixCounts: [String: Int] = [:]
    for sample in samples {
      let lines = sample.text.components(separatedBy: "\n")
      for k in 2...maxBlock where lines.count > k {
        suffixCounts[lines.suffix(k).joined(separator: "\n"), default: 0] += 1
      }
    }
    return samples.map { sample in
      var lines = sample.text.components(separatedBy: "\n")
      guard let k = (2...maxBlock).reversed().first(where: {
        lines.count > $0 && suffixCounts[lines.suffix($0).joined(separator: "\n"), default: 0] >= minRepeats
      }) else { return sample }
      let block = Array(lines.suffix(k))
      guard let contact = block.firstIndex(where: isContactLine) else { return sample }
      lines.removeLast(k - contact)
      let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return sample }
      return WritingSample(
        id: sample.id, context: sample.context, source: sample.source, recipient: sample.recipient,
        sentAt: sample.sentAt, incomingChars: sample.incomingChars, text: text)
    }
  }

  private static func isContactLine(_ line: String) -> Bool {
    line.range(
      of: #"(\+?\d[\d \-/().]{6,}\d)|@|www\.|https?://|\b(Tel|Phone|Fax|Mobil|Mobile|GmbH|AG|UG|Inc|Ltd|LLC)\b"#,
      options: [.regularExpression, .caseInsensitive]) != nil
  }

  // MARK: - Profile Derivation

  private static let profileSamplesPerContext = 40

  private static let profileSchema: [String: Any] = [
    "type": "object",
    "properties": Dictionary(uniqueKeysWithValues: WritingContext.allCases.map {
      ($0.rawValue, [
        "type": "string",
        "description": "Profile lines for \($0.englishName) messages, or an empty string when there are no examples for it.",
      ] as [String: Any])
    }),
    "required": WritingContext.allCases.map(\.rawValue),
  ]

  private static let profileSystemPrompt = """
    You analyse messages one person wrote and extract how they write, per context.
    For each context, output short lines of hard, observable facts only:
    - Greeting: the greetings they actually use (quote them).
    - Closing: the closings and sign-off they actually use (quote them).
    - Register: Du or Sie in German, formal or informal in English, and when it changes.
    - Length: typical length in words or sentences.
    - Emoji: whether and which.
    - Capitalization and punctuation habits in short messages.
    - Phrases: recurring phrases worth imitating (quote them).
    - Never: phrases and punctuation typical of AI assistants that this person demonstrably does not use (for example em dashes, "I hope this finds you well", "Happy to help"). List something here only if it is absent from their messages.
    No adjectives like "friendly" or "professional". At most 12 lines per context. Write the lines in English, quoted phrases in their original language. Use an empty string for a context without messages.
    """

  /// One evidence-checked edit of a single context section. Field names match the model schema.
  struct ProfileOperation: Codable, Equatable {
    enum Op: String, Codable, Equatable {
      case add, replace, remove
    }

    let context: WritingContext
    let op: Op
    let oldLine: String
    let newLine: String
    let evidence: [String]

    enum CodingKeys: String, CodingKey {
      case context
      case op
      case oldLine = "old_line"
      case newLine = "new_line"
      case evidence
    }
  }

  private static let reviseNewLimit = 60
  private static let reviseAnchorLimit = 15

  /// Line rules from `profileSystemPrompt`, plus the revise contract: keep the current profile
  /// and propose an operation only when the messages show it.
  private static let reviseSystemPrompt = profileSystemPrompt + """

    The current profile is given. Keep every line verbatim. Propose a change only when the messages clearly show a habit the profile lacks or contradict a line. Never reword a line just to phrase it differently. An empty list is the expected answer most of the time. Every operation needs at least 2 verbatim quotes copied exactly from the messages.
    """

  private static let revisionSchema: [String: Any] = [
    "type": "object",
    "properties": [
      "operations": [
        "type": "array",
        "description": "Changes to the current profile. Empty when the profile already matches the messages.",
        "items": [
          "type": "object",
          "properties": [
            "context": [
              "type": "string",
              "enum": WritingContext.allCases.map(\.rawValue),
            ] as [String: Any],
            "op": [
              "type": "string",
              "enum": ["add", "replace", "remove"],
            ] as [String: Any],
            "old_line": [
              "type": "string",
              "description": "Exact current line for replace and remove. Empty string for add.",
            ] as [String: Any],
            "new_line": [
              "type": "string",
              "description": "The line to add, or the replacement line. Empty string for remove.",
            ] as [String: Any],
            "evidence": [
              "type": "array",
              "items": ["type": "string"] as [String: Any],
              "description": "Verbatim quotes copied from the messages. At least 2.",
            ] as [String: Any],
          ] as [String: Any],
          "required": ["context", "op", "old_line", "new_line", "evidence"],
        ] as [String: Any],
      ] as [String: Any],
    ] as [String: Any],
    "required": ["operations"],
  ]

  /// Asks the Writing Style model (`selectedImprovementModel`) for a profile, shows it for review, and saves what the
  /// user accepts. The first profile is derived from scratch. When one already exists, the same entry point revises
  /// it and shows the panel only for changes backed by at least two messages. Returns the saved profile, or nil when
  /// the user cancelled, the save failed, or no revision applied.
  @discardableResult
  static func deriveProfile() async throws -> String? {
    guard !OfflineMode.isEnabled else { throw ImportError.offlineMode }
    let store = WritingStyleStore.shared
    let samples = store.loadSamples()
    guard !samples.isEmpty else { throw ImportError.noSamples }
    if store.hasProfile {
      return try await reviseProfile(store: store, samples: samples)
    }
    return try await deriveFirstProfile(store: store, samples: samples)
  }

  private static func deriveFirstProfile(store: WritingStyleStore, samples: [WritingSample]) async throws -> String? {
    var userMessage = ""
    var used = 0
    for context in WritingContext.allCases {
      let inContext = samples.filter { $0.context == context }.sorted { $0.sentAt > $1.sentAt }
      let picked = evenSample(inContext, max: profileSamplesPerContext)
      guard !picked.isEmpty else { continue }
      used += picked.count
      userMessage += "## Context: \(context.rawValue)\n\n"
      userMessage += picked.map { "---\n\($0.text)" }.joined(separator: "\n") + "\n\n"
    }

    let model = PromptModel.loadChatSlotModel(
      forKey: UserDefaultsKeys.selectedImprovementModel,
      default: SettingsDefaults.selectedImprovementModel)
    try ProviderCredentials.verifyConfigured(model.provider)
    DebugLogger.log("WRITING-STYLE-PROFILE: deriving from \(used) samples with \(model.displayName)")

    let result = try await LLMProviderFactory.provider(for: model).generateStructured(
      model: model.rawValue,
      contents: [["role": "user", "parts": [["text": userMessage]]]],
      systemInstruction: ["parts": [["text": profileSystemPrompt]]],
      schema: profileSchema,
      schemaName: "writing_style_profile",
      thinkingLevel: .low)

    let current = store.loadProfile()
    var derived: [WritingContext: String] = [:]
    for context in WritingContext.allCases {
      derived[context] = result[context.rawValue] as? String ?? ""
    }
    let suggested = mergedProfile(
      derived: derived, current: current, contextsWithSamples: Set(samples.map(\.context)))
    let rationale = "Derived from \(used) of your messages."
    guard let accepted = await ProposalReviewPanel.present(
      focusDisplayName: "Writing Style",
      originalText: current,
      suggestedText: suggested,
      rationale: rationale)
    else { return cancelProfileReview(store: store) }
    return saveAcceptedProfile(accepted, rationale: rationale)
  }

  /// New samples are the tail of that context in file order (append order), at most the last 60
  /// and never more than the samples added since the profile was saved. Up to 15 earlier samples
  /// of the same context are anchors. A context with nothing in the tail is skipped.
  private struct RevisionSelection {
    let newSamples: [WritingSample]
    let anchors: [WritingSample]
  }

  private static func revisionSelection(samples: [WritingSample], since: Int) -> [WritingContext: RevisionSelection] {
    let window = min(max(since, 0), reviseNewLimit)
    guard window > 0 else { return [:] }
    var selected: [WritingContext: RevisionSelection] = [:]
    for context in WritingContext.allCases {
      let inContext = samples.filter { $0.context == context }
      let newSamples = Array(inContext.suffix(window))
      guard !newSamples.isEmpty else { continue }
      let older = Array(inContext.dropLast(newSamples.count))
      selected[context] = RevisionSelection(
        newSamples: newSamples, anchors: evenSample(older, max: reviseAnchorLimit))
    }
    return selected
  }

  private static func revisionUserMessage(current: String, selection: [WritingContext: RevisionSelection]) -> String {
    var message = "## Current profile\n\(current)\n\n"
    for context in WritingContext.allCases {
      guard let picked = selection[context] else { continue }
      message += "## Context: \(context.rawValue)\n\n"
      let shown = picked.newSamples + picked.anchors
      message += shown.map { "---\n\($0.text)" }.joined(separator: "\n") + "\n\n"
    }
    return message
  }

  private static func profileOperations(from result: [String: Any]) -> [ProfileOperation] {
    guard let raw = result["operations"] as? [Any] else { return [] }
    return raw.compactMap { item in
      guard JSONSerialization.isValidJSONObject(item),
        let data = try? JSONSerialization.data(withJSONObject: item)
      else { return nil }
      return try? JSONDecoder().decode(ProfileOperation.self, from: data)
    }
  }

  private static func reviseProfile(store: WritingStyleStore, samples: [WritingSample]) async throws -> String? {
    let current = store.loadProfile()
    let selection = revisionSelection(samples: samples, since: store.samplesSinceProfile)
    guard !selection.isEmpty else {
      store.resetSamplesSinceProfile()
      DebugLogger.log("WRITING-STYLE-PROFILE: revise proposed=0 applied=0")
      return nil
    }

    let model = PromptModel.loadChatSlotModel(
      forKey: UserDefaultsKeys.selectedImprovementModel,
      default: SettingsDefaults.selectedImprovementModel)
    try ProviderCredentials.verifyConfigured(model.provider)
    let shown = selection.values.reduce(0) { $0 + $1.newSamples.count + $1.anchors.count }
    DebugLogger.log("WRITING-STYLE-PROFILE: revising from \(shown) samples with \(model.displayName)")

    let result = try await LLMProviderFactory.provider(for: model).generateStructured(
      model: model.rawValue,
      contents: [["role": "user", "parts": [["text": revisionUserMessage(current: current, selection: selection)]]]],
      systemInstruction: ["parts": [["text": reviseSystemPrompt]]],
      schema: revisionSchema,
      schemaName: "writing_style_revision",
      thinkingLevel: .low)

    let operations = profileOperations(from: result)
    let revised = applyRevision(current: current, operations: operations, samples: samples)
    DebugLogger.log(
      "WRITING-STYLE-PROFILE: revise proposed=\(operations.count) applied=\(revised.applied.count)")
    guard !revised.applied.isEmpty else {
      store.resetSamplesSinceProfile()
      return nil
    }
    let rationale = String(
      localized: "\(revised.applied.count) changes, each backed by at least 2 of your messages.")
    guard let accepted = await ProposalReviewPanel.present(
      focusDisplayName: "Writing Style",
      originalText: current,
      suggestedText: revised.profile,
      rationale: rationale)
    else { return cancelProfileReview(store: store) }
    return saveAcceptedProfile(accepted, rationale: rationale)
  }

  private static func saveAcceptedProfile(_ accepted: String, rationale: String) -> String? {
    switch MCPConfigApplier(targets: .live, changeLog: .shared).applyWritingStyle(
      content: accepted, rationale: rationale, viaProposal: true)
    {
    case .success:
      DebugLogger.logSuccess("WRITING-STYLE-PROFILE: saved")
      return accepted
    case .failure:
      DebugLogger.logError("WRITING-STYLE-PROFILE: save failed")
      return nil
    }
  }

  private static func cancelProfileReview(store: WritingStyleStore) -> String? {
    store.markProfileDismissed()
    DebugLogger.log("WRITING-STYLE-PROFILE: review cancelled")
    return nil
  }

  /// Applies evidence-checked line edits. An operation is dropped unless every quote occurs in a
  /// sample of its context and the quotes together hit at least two different samples, the line
  /// it replaces or removes is actually in that section, and a line it adds is not already there.
  /// Sections with no applied operation keep their text. The result uses the same headers as
  /// `mergedProfile`.
  static func applyRevision(
    current: String, operations: [ProfileOperation], samples: [WritingSample]
  ) -> (profile: String, applied: [ProfileOperation]) {
    var sections: [WritingContext: [String]] = [:]
    for context in WritingContext.allCases {
      sections[context] = sectionLines(WritingStyleStore.profileSection(in: current, for: context))
    }
    var applied: [ProfileOperation] = []
    for operation in operations {
      var lines = sections[operation.context] ?? []
      guard revisionIsSupported(operation, lines: lines, samples: samples) else { continue }
      let newLine = operation.newLine.trimmingCharacters(in: .whitespacesAndNewlines)
      switch operation.op {
      case .add:
        lines.append(newLine)
      case .replace:
        guard let index = lines.firstIndex(where: { linesMatch($0, operation.oldLine) }) else { continue }
        lines[index] = newLine
      case .remove:
        guard let index = lines.firstIndex(where: { linesMatch($0, operation.oldLine) }) else { continue }
        lines.remove(at: index)
      }
      sections[operation.context] = lines
      applied.append(operation)
    }
    let profile = WritingContext.allCases.map { context in
      let body = (sections[context] ?? []).joined(separator: "\n")
      return "\(context.profileHeader)\n\(body)\n"
    }.joined(separator: "\n")
    return (profile, applied)
  }

  private static func sectionLines(_ section: String) -> [String] {
    guard !section.isEmpty else { return [] }
    return section.components(separatedBy: .newlines)
  }

  /// Trimmed, and a single leading "- " does not count, so a bullet and the same words match.
  private static func comparableLine(_ line: String) -> String {
    var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("- ") {
      trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
  }

  private static func linesMatch(_ line: String, _ other: String) -> Bool {
    let key = comparableLine(line)
    return !key.isEmpty && key == comparableLine(other)
  }

  private static func sectionContains(_ line: String, in lines: [String]) -> Bool {
    let key = comparableLine(line)
    guard !key.isEmpty else { return false }
    return lines.contains { comparableLine($0) == key }
  }

  /// Lowercased, trimmed, and internal whitespace collapsed to single spaces.
  private static func normalizedEvidence(_ text: String) -> String {
    text.lowercased()
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func evidenceMatches(_ operation: ProfileOperation, samples: [WritingSample]) -> Bool {
    let quotes = operation.evidence.map(normalizedEvidence)
    guard !quotes.isEmpty, quotes.allSatisfy({ $0.count >= 2 }) else { return false }
    let texts = samples.filter { $0.context == operation.context }.map { normalizedEvidence($0.text) }
    var hit = Set<Int>()
    for quote in quotes {
      var found = false
      for (index, text) in texts.enumerated() where text.contains(quote) {
        found = true
        hit.insert(index)
      }
      if !found { return false }
    }
    return hit.count >= 2
  }

  private static func revisionIsSupported(
    _ operation: ProfileOperation, lines: [String], samples: [WritingSample]
  ) -> Bool {
    guard evidenceMatches(operation, samples: samples) else { return false }
    switch operation.op {
    case .add:
      let newLine = operation.newLine.trimmingCharacters(in: .whitespacesAndNewlines)
      return !newLine.isEmpty && !sectionContains(newLine, in: lines)
    case .replace:
      let newLine = operation.newLine.trimmingCharacters(in: .whitespacesAndNewlines)
      return lines.contains(where: { linesMatch($0, operation.oldLine) })
        && !newLine.isEmpty
        && !sectionContains(newLine, in: lines)
    case .remove:
      return lines.contains(where: { linesMatch($0, operation.oldLine) })
    }
  }

  /// A context with samples takes the derived lines (even if the model wrote filler for the rest).
  /// A context without samples keeps its existing section, so hand-written text (the Default
  /// context never gets samples) survives a re-derive. Empty stays empty, so the Default fallback
  /// in `promptBlock` still applies when nothing was written.
  static func mergedProfile(
    derived: [WritingContext: String], current: String, contextsWithSamples: Set<WritingContext>
  ) -> String {
    WritingContext.allCases.map { context in
      let lines = contextsWithSamples.contains(context)
        ? (derived[context] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        : WritingStyleStore.profileSection(in: current, for: context)
      return "\(context.profileHeader)\n\(lines)\n"
    }.joined(separator: "\n")
  }

  private static func evenSample<T>(_ items: [T], max count: Int) -> [T] {
    guard items.count > count else { return items }
    let step = Double(items.count) / Double(count)
    return (0..<count).map { items[Int(Double($0) * step)] }
  }
}
