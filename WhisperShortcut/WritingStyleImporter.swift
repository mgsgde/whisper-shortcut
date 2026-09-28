//
//  WritingStyleImporter.swift
//  WhisperShortcut
//
//  Fills the writing-style pool from Gmail "Sent" and derives the per-context profile with the
//  Smart Improvement model. Only text the user wrote is kept: quoted replies, signatures and
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
        return "Not available in Offline Mode."
      case .googleNotConnected:
        return "Connect your Google account in Settings first."
      case .noSamples:
        return "No example messages yet. Import sent emails or add examples first."
      }
    }
  }

  private static let threadFetchConcurrency = 5

  // MARK: - Gmail Import

  /// Imports up to `maxMessages` recent sent emails. Returns how many new samples were stored.
  static func importFromGmail(maxMessages: Int = 200) async throws -> Int {
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
    for batchStart in stride(from: 0, to: threadIDs.count, by: threadFetchConcurrency) {
      try Task.checkCancellation()
      let batch = threadIDs[batchStart..<min(batchStart + threadFetchConcurrency, threadIDs.count)]
      let threads = await withTaskGroup(of: [[String: Any]].self) { group in
        for id in batch {
          group.addTask { (try? await GmailAPIClient.shared.readThread(threadId: id)) ?? [] }
        }
        var result: [[[String: Any]]] = []
        for await thread in group { result.append(thread) }
        return result
      }
      for thread in threads {
        samples.append(contentsOf: samplesFromThread(thread, sentIDs: sentIDs))
      }
    }

    let added = WritingStyleStore.shared.addSamples(samples)
    DebugLogger.log(
      "WRITING-STYLE-IMPORT: sent=\(refs.count) threads=\(threadIDs.count) kept=\(samples.count) added=\(added)")
    return added
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
    // Reply headers carry a date (hence `\d`, so "Am Donnerstag … schrieb er:" in the body is not
    // mistaken for one) and may be wrapped over two lines ("On …, Name <\nmail> wrote:"), hence `s`.
    let cutPatterns = [
      #"(?ms)^[ \t]*(On|Am)\b[^\n]{0,80}\d.{0,250}?(wrote|schrieb[^\n]*):[ \t]*$"#,
      #"(?m)^[ \t]*-{2,}[ \t]*(Original Message|Ursprüngliche Nachricht|Forwarded message|Weitergeleitete Nachricht)"#,
      #"(?m)^-- ?$"#,
      #"(?m)^[ \t]*(Sent from my (iPhone|iPad)|Von meinem (iPhone|iPad) gesendet|Gesendet von meinem (iPhone|iPad))"#,
    ]
    for pattern in cutPatterns {
      if let range = text.range(of: pattern, options: .regularExpression), range.lowerBound < cut {
        cut = range.lowerBound
      }
    }
    // An Outlook-style "From:" block only counts after the first lines, so a message that starts
    // by quoting a sender is not cut to nothing.
    var secondLineEnd = text.endIndex
    if let first = text.firstIndex(of: "\n") {
      let afterFirst = text.index(after: first)
      secondLineEnd = text[afterFirst...].firstIndex(of: "\n") ?? text.endIndex
    }
    if let range = text.range(of: #"(?m)^[ \t]*(From|Von):[ \t].+$"#, options: .regularExpression,
                              range: secondLineEnd..<text.endIndex),
      range.lowerBound < cut {
      cut = range.lowerBound
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
    let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
    for (entity, char) in entities { text = text.replacingOccurrences(of: entity, with: char) }
    return text
  }

  // MARK: - Profile Derivation

  private static let profileSamplesPerContext = 40

  private static let profileSchema: [String: Any] = [
    "type": "object",
    "properties": Dictionary(uniqueKeysWithValues: WritingContext.allCases.map {
      ($0.rawValue, [
        "type": "string",
        "description": "Profile lines for \($0.displayName) messages, or an empty string when there are no examples for it.",
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

  /// Asks the Smart Improvement model for a profile, shows it for review, and saves what the
  /// user accepts. Returns the saved profile, or nil when the user cancelled.
  @discardableResult
  static func deriveProfile() async throws -> String? {
    guard !OfflineMode.isEnabled else { throw ImportError.offlineMode }
    let store = WritingStyleStore.shared
    let samples = store.loadSamples()
    guard !samples.isEmpty else { throw ImportError.noSamples }

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

    let suggested = WritingContext.allCases.map { context in
      let lines = (result[context.rawValue] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return "\(context.profileHeader)\n\(lines)\n"
    }.joined(separator: "\n")

    let current = store.loadProfile()
    guard let accepted = await SmartImprovementReviewPanel.present(
      focusDisplayName: "Writing Style",
      originalText: current,
      suggestedText: suggested,
      rationale: "Derived from \(used) of your messages.")
    else {
      DebugLogger.log("WRITING-STYLE-PROFILE: review cancelled")
      return nil
    }
    store.saveProfile(accepted)
    DebugLogger.logSuccess("WRITING-STYLE-PROFILE: saved")
    return accepted
  }

  private static func evenSample<T>(_ items: [T], max count: Int) -> [T] {
    guard items.count > count else { return items }
    let step = Double(items.count) / Double(count)
    return (0..<count).map { items[Int(Double($0) * step)] }
  }
}
