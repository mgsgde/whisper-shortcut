//
//  OfflineChatAppContext.swift
//  WhisperShortcut
//
//  What the offline Chat model knows about the app it runs in.
//

import Foundation

/// A short "about this app" section for the offline Chat system prompt.
///
/// Cloud Chat answers questions about WhisperShortcut through `list_whisper_shortcut_docs` /
/// `read_whisper_shortcut_doc`. The in-process MLX model has no tools, so asked "does this Qwen
/// 3.5 9B work, and how is it different from the other one?" it knew neither that it runs inside
/// WhisperShortcut nor which model it is. This hands it the facts up front.
///
/// Two sizes, because offline Chat does not reuse a primed prefix (see
/// `ChatRequestOptions.reusablePromptPrefix`) and every token is prefilled on the user's Mac with
/// every message. Measured on Qwen3 4B (2026-10-18): first token 0.9 s with the bare offline
/// prompt, 4.5 s with the full section (~1.3k tokens). So every chat gets one identity line, and
/// the full section only once a user message in the chat is about the app (`isAboutTheApp`).
/// Even the full section is a digest: the README `## Features` section is ~4k tokens; only each
/// feature's name and first sentence go in. Nothing here is a second hand-kept list: features come
/// from the bundled README, models from `LocalLLMModelType`, shortcuts from the user's live config.
enum OfflineChatAppContext {
  /// The section for this chat: the identity line, or the full section once `userMessages` touch
  /// the app. A missing bundled README only drops the feature list.
  static func current(chatModel: PromptModel, userMessages: [String]) -> String {
    guard isAboutTheApp(userMessages) else {
      return identity(currentModel: chatModel.localMLXModelType, appVersion: AppConstants.appVersion)
    }
    let readme = bundledReadme() ?? ""
    let config = ShortcutConfigManager.shared.loadConfiguration()
    return block(
      readme: readme,
      currentModel: chatModel.localMLXModelType,
      shortcuts: config.assistantFacingRows.map { ($0.action, $0.definition.displayStringWithSeparator) },
      appVersion: AppConstants.appVersion)
  }

  /// Words that put a chat on the app itself. Matched as substrings of the lowercased,
  /// diacritic-folded user messages, so "Quen" (a common mishearing of Qwen) and "Tastenkürzel"
  /// count. Only words an ordinary question rarely contains: "model", "prompt", "offline" or
  /// "setting" would put most offline chats on the slow path. "Which model are you?" needs no
  /// entry, the always-on identity line answers it.
  static let appTopicWords: [String] = [
    "whisper", "shortcut", "diese app", "this app",
    "qwen", "quen", "mlx", "offline-modell", "offline modell", "offline model",
    "kurzel", "hotkey", "tastenkombi",
    "diktier", "dictat", "vorles", "read aloud", "glossar", "glossary",
    "smart improvement", "parakeet", "offline mode", "offline-modus",
  ]

  static func isAboutTheApp(_ userMessages: [String]) -> Bool {
    userMessages.contains { message in
      let folded = message.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      return appTopicWords.contains { folded.contains($0) }
    }
  }

  /// The always-on line, enough to answer "what are you?" in any chat.
  static func identity(currentModel: LocalLLMModelType?, appVersion: String) -> String {
    let model = currentModel.map { "You are \($0.displayName), running in-process on this Mac with MLX. " } ?? ""
    return "\(model)You are the offline Chat inside WhisperShortcut \(appVersion), a macOS menu bar app for dictation, voice-driven text editing, read-aloud, meetings and chat."
  }

  /// Pure builder, so tests can pin the output without a bundle or user defaults.
  static func block(
    readme: String,
    currentModel: LocalLLMModelType?,
    shortcuts: [(action: String, keys: String)],
    appVersion: String
  ) -> String {
    var lines: [String] = [
      "ABOUT THIS APP — you are the offline Chat inside WhisperShortcut \(appVersion), a macOS menu bar app for dictation, voice-driven text editing, read-aloud, meetings and chat.",
      "Questions about WhisperShortcut, its features, shortcuts or offline models: answer from this section. If something is not covered here, say you are not sure and point to Settings or the README instead of guessing. A cloud model in Chat (an API key in Settings) can read the full documentation.",
      "Dictated questions often misspell names: \"Quen\" or \"Quent\" means Qwen, \"Whisper Shortcut\" means this app.",
    ]

    if let currentModel {
      lines.append("")
      lines.append(
        "You are \(currentModel.displayName), running in-process on this Mac with MLX (\(currentModel.quantisationLabel)). Asked whether a model works: you can only confirm that \(currentModel.displayName) works, because you are answering. For any other model, say you cannot test it from here and tell the user to switch to it with its slash command and ask again.")
    }
    lines.append("")
    lines.append("Offline Chat models (switch in the message box's model menu, or type the slash command):")
    for model in LocalLLMModelType.allCases where model.baseModel == model {
      lines.append("- \(summary(of: model))")
    }

    let features = featureDigest(fromReadme: readme)
    if !features.isEmpty {
      lines.append("")
      lines.append("Features:")
      lines.append(contentsOf: features.map { "- \($0)" })
    }

    if !shortcuts.isEmpty {
      lines.append("")
      lines.append(
        "The user's keyboard shortcuts (all of them are shown and changed in Settings → General): "
          + shortcuts.map { "\($0.action) \($0.keys)" }.joined(separator: "; ") + ".")
    }
    return lines.joined(separator: "\n")
  }

  /// One line per model family: name, slash command, download size, and whether Dictate Prompt
  /// can use it.
  ///
  /// Deliberately terse. This block is prefilled on every offline message and
  /// `OfflineChatAppContextTests.realReadmeStaysWithinBudget` caps it at 6,200 characters, so the
  /// nineteen-entry catalogue does not fit per-model prose. Size is the fact the assistant cannot
  /// look up anywhere else; the RAM floor is not, because Settings shows it next to the model and
  /// it follows from the size.
  ///
  /// The 6-bit and 8-bit variants are deliberately *not* listed. They are the same model at a
  /// higher precision, and naming each one with its own slash command cost ~190 characters — more
  /// than the whole budget had left (the nine family lines already sit at 6,196 of 6,200). The
  /// model menu in the message box lists every entry, so a user can still switch to a variant;
  /// what the assistant loses is the ability to recite a variant's alias, which is the cheaper
  /// thing to lose than a budget that is paid on every offline message.
  /// One model line *without* its list marker: the caller owns the `- `, so the bullet is not
  /// written twice ("- - Qwen3.5 4B …").
  static func summary(of model: LocalLLMModelType) -> String {
    let dictatePrompt = model.supportsDictatePrompt ? " (Dictate Prompt)" : ""
    return "\(model.displayName) /\(model.promptModel.shortAlias) \(model.estimatedSizeLabel)\(dictatePrompt)"
  }

  /// "Name: first sentence" for every `- **Name**: …` bullet under `## Features`.
  static func featureDigest(fromReadme readme: String) -> [String] {
    var inFeatures = false
    var digest: [String] = []
    for line in readme.components(separatedBy: "\n") {
      if line.hasPrefix("## ") {
        if inFeatures { break }
        inFeatures = line.hasPrefix("## Features")
        continue
      }
      guard inFeatures, line.hasPrefix("- **"),
        let nameEnd = line.range(of: "**", range: line.index(line.startIndex, offsetBy: 4)..<line.endIndex)
      else { continue }
      let name = String(line[line.index(line.startIndex, offsetBy: 4)..<nameEnd.lowerBound])
      var body = line[nameEnd.upperBound...].trimmingCharacters(in: .whitespaces)
      if body.hasPrefix(":") { body.removeFirst() }
      digest.append("\(name): \(firstSentence(of: body.trimmingCharacters(in: .whitespaces)))")
    }
    return digest
  }

  private static func firstSentence(of text: String) -> String {
    let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    guard let end = plain.range(of: ". ") else { return plain }
    return String(plain[..<end.lowerBound]) + "."
  }

  private static func bundledReadme() -> String? {
    let url =
      Bundle.main.url(forResource: "README", withExtension: "md", subdirectory: "Docs")
      ?? Bundle.main.url(forResource: "README", withExtension: "md")
    guard let url else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }
}
