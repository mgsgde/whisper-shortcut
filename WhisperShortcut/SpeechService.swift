import AVFoundation
import Foundation
import NaturalLanguage

// MARK: - Prompt Mode Enum
enum PromptMode {
  case togglePrompting
}

// MARK: - Constants
private enum Constants {
  static let resourceTimeout: TimeInterval = 300.0

  // Retry budget for the OpenAI Dictate Prompt 429 backoff (1 attempt + 1 retry).
  static let maxRetryAttempts = 2
  static let retryDelaySeconds: TimeInterval = 1.5
}

// MARK: - Core Service
class SpeechService {

  /// Placeholder used in conversation history when the parallel voice-to-text transcription
  /// fails or times out.
  fileprivate static let voiceInstructionPlaceholder = "(voice instruction)"

  /// Fallback transcription instruction used when the user hasn't supplied a custom prompt.
  private static let defaultTranscriptionInstruction = "Transcribe this audio. Return only the transcribed text without any additional commentary or formatting."

  // MARK: - Shared Infrastructure
  private let keychainManager: KeychainManaging
  private let credentialProvider: GeminiCredentialProviding
  private var clipboardManager: ClipboardManager?
  private let geminiClient: GeminiAPIClient

  // MARK: - Chunked Transcription
  /// Delegate for receiving chunk progress updates during long audio transcription.
  weak var chunkProgressDelegate: ChunkProgressDelegate?

  // MARK: - Task Tracking for Cancellation
  private let transcriptionTaskLock = NSLock()
  private var currentTranscriptionTask: Task<String, Error>?
  private var currentPromptTask: Task<String, Error>?
  private var currentTTSTask: Task<Data, Error>?

  init(
    keychainManager: KeychainManaging = KeychainManager.shared,
    credentialProvider: GeminiCredentialProviding = GeminiCredentialProvider.shared,
    clipboardManager: ClipboardManager? = nil,
    geminiClient: GeminiAPIClient? = nil
  ) {
    self.keychainManager = keychainManager
    self.credentialProvider = credentialProvider
    self.clipboardManager = clipboardManager
    self.geminiClient = geminiClient ?? GeminiAPIClient()
  }

  // MARK: - Transcription Mode Configuration
  /// Notifies the service that the selected transcription model changed (the model itself
  /// is persisted via UserDefaults; this is purely a hook for side effects like releasing
  /// the offline Whisper model when the user switches to a cloud backend).
  func setModel(_ model: TranscriptionModel) {
    // `unloadModel()` is idempotent — no-op when nothing is loaded — so we don't need
    // to track the previous selection just to decide whether to call it.
    if !model.isOffline {
      Task {
        await LocalSpeechService.shared.unloadModel()
      }
    }
  }

  // MARK: - Model Information for Notifications
  func getTranscriptionModelInfo() async -> String {
    let model = TranscriptionModel.loadSelected()
    if model.isOffline {
      return await LocalSpeechService.shared.getCurrentModelInfo() ?? model.displayName
    }
    return model.displayName
  }
  
  func getPromptModelInfo() -> String {
    getPromptModel().displayName
  }
  
  // MARK: - Prompt Model Selection Helper
  /// Reads the user's currently-selected Dictate Prompt model from UserDefaults,
  /// applying the legacy-rawValue migration first.
  private func getPromptModel() -> PromptModel {
    let defaultModel = SettingsDefaults.selectedPromptModel
    let modelString = UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedPromptModel) ?? defaultModel.rawValue
    let normalized = PromptModel.migrateLegacyPromptRawValue(modelString)
    return PromptModel(rawValue: normalized) ?? defaultModel
  }

  // MARK: - Prompt Building
  /// Returns the dictation system prompt (custom prompt only).
  private func buildDictationPrompt() -> String {
    SystemPromptsStore.shared.loadDictationPrompt()
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Appends the user's vocabulary Glossary (when non-empty) to a transcription instruction.
  /// Instructable cloud models (Gemini, OpenAI, xAI) lack offline Whisper's native conditioning
  /// channel, so the expected-term list is surfaced inline in the prompt — wrapped in an explicit
  /// instruction so the model actually biases toward these spellings. A bare term list is too weak
  /// a signal for Flash-tier models, especially for near-homophones (e.g. "Claude" vs "Cloud").
  /// Returns `base` unchanged when the Glossary is empty.
  ///
  /// The list must be framed strictly as a spelling reference: phrased as "these terms may appear
  /// in the audio", Flash-tier models compose whole sentences out of the terms on short or silent
  /// recordings (glossary echo — sub-second audio produced paragraph-length fake transcripts built
  /// from glossary entries).
  private func appendGlossaryHint(to base: String) -> String {
    let parsed = parsedGlossary()
    let glossary = parsed.terms.joined(separator: ", ")
    guard !glossary.isEmpty || !parsed.corrections.isEmpty else { return base }

    var block = ""
    if !glossary.isEmpty {
      block = "Reference vocabulary — correct spellings of names and terms this speaker uses. "
        + "If, and only if, you clearly hear one of them, transcribe it with exactly this spelling "
        + "and capitalization instead of a more common, similar-sounding word. This list is a "
        + "spelling reference only, NOT content: never output a listed term you did not clearly "
        + "hear, and never append these terms to the transcript. If the audio is silent or "
        + "unintelligible, return an empty response.\n" + glossary
    }
    if let tieBreakers = Self.tieBreakerBlock(for: parsed.corrections) {
      block = block.isEmpty ? tieBreakers : block + "\n\n" + tieBreakers
    }

    DebugLogger.log(
      "GLOSSARY: conditioning transcription with \(glossary.count) chars"
        + " + \(parsed.corrections.count) tie-breaker(s): \(glossary.prefix(200))")
    return base.isEmpty ? block : base + "\n\n" + block
  }

  /// The `Term (not "Wrong")` pairs, rendered as an explicit override of the reference-vocabulary
  /// rule above them. Returns nil when the user has annotated nothing.
  ///
  /// The reference list on its own cannot settle a near-homophone: it says "only if you clearly
  /// hear one of them", and for `Claude` /kloːd/ vs `Cloud` /klaʊd/ a Flash-tier model is never
  /// confident, so it falls back on whichever word carries the stronger language prior — which is
  /// exactly the one the user rejected. This block is the only place the app tells the model which
  /// of the two to pick when it cannot decide, so it deliberately drops the "clearly hear" hedge
  /// for these pairs while keeping the anti-echo guard that the hedge was there for.
  ///
  /// The rejected spelling usually remains a legitimate word elsewhere in the same speaker's
  /// vocabulary ("Google Cloud" is frequent in this corpus even though bare "Cloud" is rejected),
  /// hence the explicit escape hatch for established compounds.
  private static func tieBreakerBlock(for corrections: [GlossaryCorrection]) -> String? {
    guard !corrections.isEmpty else { return nil }
    let pairs = corrections
      .map { "- \"\($0.correct)\" — not \"\($0.rejected.joined(separator: "\" / \""))\"" }
      .joined(separator: "\n")
    return "Homophone tie-breakers — this refines the rule above for these specific pairs. For "
      + "this speaker each pair is settled in favour of the FIRST spelling: when what you hear "
      + "could be either member of a pair, write the first spelling, even though the second is "
      + "the more common word. Use the second spelling only where the surrounding words make it "
      + "unmistakable, such as an established product name it forms part of. These are spelling "
      + "decisions only — never output either form unless you actually heard it.\n" + pairs
  }

  /// One `Term (not "Wrong")` line from the Whisper Glossary: the spelling the user wants, plus
  /// every spelling they explicitly rejected for it.
  private struct GlossaryCorrection {
    let correct: String
    let rejected: [String]
  }

  /// The Whisper Glossary split into the two things a cloud model needs separately: a flat
  /// reference vocabulary, and the correction pairs the user annotated.
  private struct ParsedGlossary {
    /// Terms fit for the reference list — annotations removed, phrase-style entries (more than
    /// 3 words, e.g. "einen Crawler am Laufen") dropped, rejected spellings filtered out.
    let terms: [String]
    /// The annotated pairs, in glossary order.
    let corrections: [GlossaryCorrection]
  }

  /// Parses the Whisper Glossary once for both consumers.
  ///
  /// Phrase-style entries and the raw `(not "…")` syntax are offline-Whisper priming forms; fed
  /// verbatim into an instruction prompt they invite echo (Flash-Lite reproduced a 4-word glossary
  /// phrase instead of the actual audio in every test run), which is why the reference list keeps
  /// them out. The annotation itself is *not* discarded any more, though: it is the only signal
  /// that distinguishes a near-homophone pair, and `tieBreakerBlock` renders it in a shape that
  /// cannot be echoed as content.
  private func parsedGlossary() -> ParsedGlossary {
    let lines = SystemPromptsStore.shared.loadWhisperGlossary()
      .components(separatedBy: .newlines)

    // Spellings the user explicitly marked as WRONG (`Kimi (not "Kimmi")`) must never be offered
    // as reference vocabulary. `GlossaryFastLearner` writes bare terms one per line, so a form it
    // auto-learned before the user corrected it otherwise sits in the list right next to its own
    // correction — the model is told both spellings are right and the correction cancels out.
    // Stripping the annotation is not enough; the rejected form has to be filtered out by name.
    var rejected = Set<String>()
    var corrections: [GlossaryCorrection] = []
    for line in lines {
      var cursor = Substring(line)
      var lineRejects: [String] = []
      while let range = cursor.range(
        of: #"\((?:not|nicht)\s+[^)]*\)"#, options: [.regularExpression, .caseInsensitive])
      {
        let inner = cursor[range]
          .replacingOccurrences(
            of: #"^\((?:not|nicht)\s+"#, with: "",
            options: [.regularExpression, .caseInsensitive])
          .replacingOccurrences(of: ")", with: "")
        for form in inner.components(separatedBy: ",") {
          let cleaned = form.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
          if !cleaned.isEmpty {
            rejected.insert(Self.foldGlossaryTerm(cleaned))
            lineRejects.append(cleaned)
          }
        }
        cursor = cursor[range.upperBound...]
      }
      guard !lineRejects.isEmpty else { continue }
      let correct = Self.strippingAnnotations(from: line)
        .replacingOccurrences(
          of: #"^Terms:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        .trimmingCharacters(in: .whitespaces)
      // An annotated entry only earns a tie-breaker if its correct form is itself a term rather
      // than a phrase — same bar the reference list applies.
      guard !correct.isEmpty, correct.split(separator: " ").count <= 3 else { continue }
      corrections.append(GlossaryCorrection(correct: correct, rejected: lineRejects))
    }

    let terms = lines
      .flatMap { line -> [String] in
        // Strip the `(not "…")` annotation BEFORE splitting on commas, so a comma inside the
        // parenthetical (e.g. `Gödde (not "Godde, Goedde")`) can't shear it into leaking fragments.
        Self.strippingAnnotations(from: line)
          .components(separatedBy: ",")
          .map { $0.trimmingCharacters(in: .whitespaces) }
      }
      .filter { term in
        // The built-in list is written as `Terms: A, B, C`, so the first element carries the
        // label — compare without it, or a rejected form in first position slips through.
        let bare = term.replacingOccurrences(
          of: #"^Terms:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        return !bare.isEmpty && bare.split(separator: " ").count <= 3
          && !rejected.contains(Self.foldGlossaryTerm(bare))
      }

    return ParsedGlossary(terms: terms, corrections: corrections)
  }

  private static func strippingAnnotations(from line: String) -> String {
    line.replacingOccurrences(
      of: #"\s*\((?:not|nicht)\s+[^)]*\)"#,
      with: "",
      options: [.regularExpression, .caseInsensitive])
  }

  /// The same sanitized glossary the prompt gets, as individual terms — the input to
  /// `TextProcessingUtility.discardingGlossaryEchoTranscript`, which needs to recognise a
  /// transcript that is nothing but vocabulary we ourselves put in the prompt.
  private func glossaryTermsForEchoCheck() -> [String] {
    parsedGlossary().terms
      .map {
        $0.replacingOccurrences(
          of: #"^\s*Terms:\s*"#, with: "", options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)
      }
      .filter { !$0.isEmpty }
  }

  /// The Whisper Glossary as literal terms for `gpt-transcribe`'s `keywords` field: the same
  /// sanitized reference vocabulary the prompt-based backends get, plus the *correct* half of
  /// every tie-breaker pair.
  ///
  /// The rejected spellings are deliberately left out — `keywords` are hints for what may appear
  /// in the audio, so feeding it both sides of a near-homophone pair would cancel the correction
  /// out. Settling a pair the model still gets wrong stays the job of
  /// `correctingRejectedSpellings`, which runs on the transcript afterwards.
  private func glossaryKeywords() -> [String] {
    let parsed = parsedGlossary()
    var seen = Set<String>()
    var keywords: [String] = []
    for term in glossaryTermsForEchoCheck() + parsed.corrections.map(\.correct) {
      let folded = Self.foldGlossaryTerm(term)
      guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
      keywords.append(term)
    }
    return keywords
  }

  /// Case- and diacritic-insensitive comparison form, matching `GlossaryFastLearner.fold`.
  private static func foldGlossaryTerm(_ word: String) -> String {
    word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
  }

  // MARK: - Rejected-Spelling Correction

  /// Rewrites a transcript that came back carrying a spelling the user explicitly rejected in the
  /// Whisper Glossary (`Claude CLI (not "Cloud CLI")`), as a backstop behind `tieBreakerBlock`.
  ///
  /// Prompt conditioning alone does not reliably settle a near-homophone. In four days of this
  /// user's dictation logs, Flash-Lite returned "Cloud CLI" for spoken "Claude CLI" in every
  /// attempt after the glossary entry was added — including one dictation where they said both
  /// words in a single sentence to contrast them and both came out identical.
  ///
  /// Deliberately narrow, because a rejected spelling normally stays a legitimate word elsewhere
  /// in the same speaker's vocabulary:
  /// - Only multi-word rejected forms are rewritten. Bare "Cloud" is left alone — "Google Cloud",
  ///   "Sovereign Cloud" and "Cloud-Anbieter" are all frequent in this corpus, and the phrase is
  ///   what makes the intent unambiguous.
  /// - A match preceded by another capitalised word is left alone, so "Google Cloud CLI" survives
  ///   while "die Cloud CLI" is corrected. German capitalises nouns, which makes the preceding
  ///   token a decent signal for exactly the compounds that must not be touched.
  ///
  /// Both rules fail toward changing nothing, i.e. toward the behaviour before this existed.
  private func correctingRejectedSpellings(in text: String) -> String {
    guard !text.isEmpty else { return text }
    let corrections = parsedGlossary().corrections
    guard !corrections.isEmpty else { return text }

    var result = text
    for correction in corrections {
      for rejected in correction.rejected where rejected.contains(" ") {
        result = Self.replacingRejectedSpelling(
          rejected, with: correction.correct, in: result)
      }
    }
    if result != text {
      DebugLogger.log("GLOSSARY-CORRECT: rewrote rejected spelling(s) in transcript")
    }
    return result
  }

  /// Internal rather than private so `RejectedSpellingCorrectionTests` can pin the two guards
  /// down: both are silent when wrong, one way leaving the misheard word in place and the other
  /// corrupting a legitimate compound.
  static func replacingRejectedSpelling(
    _ rejected: String, with correct: String, in text: String
  ) -> String {
    let escaped = NSRegularExpression.escapedPattern(for: rejected)
    guard let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b") else { return text }
    let source = text as NSString
    var result = text
    // Back to front: a replacement only shifts offsets after its own range, so the remaining
    // (earlier) match ranges stay valid against `result`.
    for match in regex.matches(
      in: text, range: NSRange(location: 0, length: source.length)
    ).reversed() {
      guard !isPrecededByCapitalizedWord(in: source, before: match.range.location) else { continue }
      result = (result as NSString).replacingCharacters(in: match.range, with: correct)
    }
    return result
  }

  /// True when the token immediately before `location` begins with an uppercase letter — the
  /// signal that the rejected spelling sits inside a proper compound ("Google Cloud CLI") rather
  /// than standing on its own. Punctuation, digits, or the start of the text count as "not
  /// preceded", so a sentence-initial match is still corrected.
  private static func isPrecededByCapitalizedWord(in text: NSString, before location: Int) -> Bool {
    func scalar(at index: Int) -> UnicodeScalar? {
      UnicodeScalar(text.character(at: index))
    }

    var index = location - 1
    while index >= 0, let s = scalar(at: index),
      CharacterSet.whitespacesAndNewlines.contains(s)
    {
      index -= 1
    }
    let wordEnd = index
    while index >= 0, let s = scalar(at: index), CharacterSet.letters.contains(s) {
      index -= 1
    }
    guard wordEnd > index, let first = scalar(at: index + 1) else { return false }
    return CharacterSet.uppercaseLetters.contains(first)
  }

  /// The full transcription instruction shared by every Gemini sub-path (inline, Files API, and
  /// chunking): the user's dictation prompt — or the built-in default when unset — with the
  /// vocabulary Glossary appended. Substituting the default *before* appending the Glossary keeps
  /// all three paths identical; previously the chunking path appended the Glossary to an empty
  /// base, sending a bare word-list with no transcription instruction when only a Glossary was set.
  /// `suppressGlossary` drops the vocabulary block for the glossary-echo retry — see
  /// `transcribeWithGeminiInline`. Without it the retry would offer the model exactly the words it
  /// just confabulated from.
  private func geminiTranscriptionInstruction(promptOverride: String?, suppressGlossary: Bool = false) -> String {
    let base = promptOverride ?? buildDictationPrompt()
    let resolved = base.isEmpty ? Self.defaultTranscriptionInstruction : base
    return suppressGlossary ? resolved : appendGlossaryHint(to: resolved)
  }

  // MARK: - Cancellation Methods
  func cancelTranscription() {
    DebugLogger.log("CANCELLATION: Cancelling transcription task")
    transcriptionTaskLock.lock()
    let task = currentTranscriptionTask
    currentTranscriptionTask = nil
    transcriptionTaskLock.unlock()
    task?.cancel()
  }

  func cancelPrompt() {
    DebugLogger.log("CANCELLATION: Cancelling prompt task")
    currentPromptTask?.cancel()
    currentPromptTask = nil
  }
  
  func cancelTTS() {
    DebugLogger.log("CANCELLATION: Cancelling TTS task")
    currentTTSTask?.cancel()
    currentTTSTask = nil
  }

  // MARK: - Transcription Mode (Public API with Task Tracking)
  /// - Parameters:
  ///   - preferredModel: If set (e.g. for live meeting), use this model; otherwise use the global Dictate selection.
  ///   - promptOverride: If set, use this prompt instead of the user's dictation prompt.
  ///   - cancellable: When false, skips the cancellation slot (e.g. live-meeting chunks).
  ///   - reportsProgress: When false, a chunked transcription (>45s audio) does not drive
  ///     the global chunk-progress delegate. Background transcriptions (streaming dictate
  ///     chunks) must pass false — the delegate mutates the app state machine, which
  ///     belongs to the foreground pipeline only.
  func transcribe(
    audioURL: URL,
    preferredModel: TranscriptionModel? = nil,
    promptOverride: String? = nil,
    cancellable: Bool = true,
    reportsProgress: Bool = true
  ) async throws -> String {
    // Create and store task for cancellation support
    let task = Task<String, Error> {
      let transcript = try await self.performTranscription(audioURL: audioURL, preferredModel: preferredModel, promptOverride: promptOverride, reportsProgress: reportsProgress)
      // Applied here rather than per-provider: every path (offline Whisper, Gemini inline /
      // Files API / chunked, OpenAI, xAI, self-hosted) and both dictation and live meeting
      // return through this one call.
      return self.correctingRejectedSpellings(in: transcript)
    }

    if cancellable {
      transcriptionTaskLock.lock()
      currentTranscriptionTask = task
      transcriptionTaskLock.unlock()
      // Only clear the slot if this call still owns it — a concurrent newer call may have
      // overwritten `currentTranscriptionTask` while we were suspended on `task.value`; its
      // own `defer` will handle the clear.
      defer {
        transcriptionTaskLock.lock()
        if currentTranscriptionTask == task { currentTranscriptionTask = nil }
        transcriptionTaskLock.unlock()
      }
    }

    return try await task.value
  }

  // MARK: - Transcription Mode (Private Implementation)
  private func performTranscription(audioURL: URL, preferredModel: TranscriptionModel? = nil, promptOverride: String? = nil, reportsProgress: Bool = true) async throws -> String {
    let startTime = CFAbsoluteTimeGetCurrent()
    let model = preferredModel ?? TranscriptionModel.loadSelected()

    // Check if using offline model
    if model.isOffline {
      // For offline models, use LocalSpeechService
      guard let offlineModelType = model.offlineModelType else {
        throw TranscriptionError.networkError("Invalid offline model type")
      }

      // Check if model is available before attempting to use it
      if !ModelManager.shared.isModelAvailable(offlineModelType) {
        throw TranscriptionError.modelNotAvailable(offlineModelType)
      }

      // Use the selected model: initialize if not ready, or re-initialize if a different model is loaded (e.g. pre-loaded Large but user selected Base)
      if await !LocalSpeechService.shared.isLoaded(modelType: offlineModelType) {
        try await LocalSpeechService.shared.initializeModel(offlineModelType)
      }
      try Task.checkCancellation()

      // Validate format
      try validateAudioFileFormat(at: audioURL)
      try Task.checkCancellation()

      // Get language setting for Whisper (defaults to auto-detect)
      let savedLanguageString = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperLanguage)
      let savedLanguage = WhisperLanguage(rawValue: savedLanguageString ?? WhisperLanguage.auto.rawValue) ?? WhisperLanguage.auto
      let languageString = savedLanguage.languageCode // Returns nil for .auto, which enables auto-detect

      if savedLanguage == .auto {
        DebugLogger.log("LOCAL-SPEECH: Using auto-detect language (default)")
      } else {
        DebugLogger.log("LOCAL-SPEECH: Using language setting: \(savedLanguage.displayName) (\(savedLanguage.rawValue))")
      }

      // Pass Whisper Glossary for offline conditioning (nil when empty)
      let whisperGlossary = SystemPromptsStore.shared.loadWhisperGlossary().trimmingCharacters(in: .whitespacesAndNewlines)
      let whisperPrompt: String? = whisperGlossary.isEmpty ? nil : whisperGlossary

      // Transcribe using local service
      let result = try await LocalSpeechService.shared.transcribe(audioURL: audioURL, language: languageString, prompt: whisperPrompt)
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.logSpeech("SPEED: Whisper transcription completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }

    // Check if using Gemini model
    if model.isGemini {
      // For Gemini, validate format but not size (Gemini supports up to 9.5 hours)
      try validateAudioFileFormat(at: audioURL)
      let result = try await transcribeWithGemini(audioURL: audioURL, model: model, promptOverride: promptOverride, reportsProgress: reportsProgress)
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.logSpeech("SPEED: [\(model.displayName)] transcription completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }

    // OpenAI cloud transcription (gpt-transcribe / gpt-4o-transcribe / gpt-4o-mini-transcribe)
    if model.isOpenAI, let openAIModelID = model.openAIAPIModelID {
      try validateAudioFileFormat(at: audioURL)
      // gpt-4o-transcribe family accepts a full GPT-4o-style instruction via the `prompt`
      // multipart field — pass the user's dictation prompt so OpenAI behaves like Gemini.
      // `gpt-transcribe` ignores instructions and is fed keywords instead; the shared multipart
      // helper drops this hint for it.
      let dictationHint = (promptOverride ?? buildDictationPrompt()).trimmingCharacters(in: .whitespacesAndNewlines)
      let result = try await transcribeWithOpenAI(
        audioURL: audioURL,
        modelID: openAIModelID,
        dictationHint: dictationHint.isEmpty ? nil : dictationHint
      )
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.logSpeech("SPEED: [\(model.displayName)] transcription completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }

    // xAI Grok hosted transcription (/v1/stt)
    if model.isXAI {
      try validateAudioFileFormat(at: audioURL)
      let dictationHint = (promptOverride ?? buildDictationPrompt()).trimmingCharacters(in: .whitespacesAndNewlines)
      let result = try await transcribeWithXAI(
        audioURL: audioURL,
        dictationHint: dictationHint.isEmpty ? nil : dictationHint
      )
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.logSpeech("SPEED: [\(model.displayName)] transcription completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }

    // OpenRouter (audio as a chat-completion content part)
    if model == .openRouterTranscription {
      try validateAudioFileFormat(at: audioURL)
      let result = try await transcribeWithOpenRouter(audioURL: audioURL, promptOverride: promptOverride)
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.logSpeech("SPEED: [OpenRouter] transcription completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }

    // Self-hosted OpenAI-compatible endpoint
    if model == .selfHostedTranscription {
      try validateAudioFileFormat(at: audioURL)
      let result = try await transcribeWithSelfHostedEndpoint(audioURL: audioURL)
      let elapsedTime = CFAbsoluteTimeGetCurrent() - startTime
      DebugLogger.logSpeech("SPEED: [Self-hosted Transcription] completed in \(String(format: "%.3f", elapsedTime))s (\(String(format: "%.0f", elapsedTime * 1000))ms)")
      return result
    }

    // Should never reach here
    throw TranscriptionError.networkError("Unsupported transcription model")
  }
  

  // MARK: - Prompt Modes (Public API with Task Tracking)
  func executePrompt(audioURL: URL, mode: PromptMode = .togglePrompting) async throws -> String {
    // Create and store task for cancellation support
    let task = Task<String, Error> {
      try await self.performPrompt(audioURL: audioURL, mode: mode)
    }

    currentPromptTask = task
    // See `transcribe` for the identity-check rationale.
    defer { if currentPromptTask == task { currentPromptTask = nil } }

    return try await task.value
  }

  // MARK: - Async Helpers

  /// Awaits `task.value` but gives up after `timeoutSeconds`, returning `nil` instead
  /// of blocking the caller. Used by the Dictate Prompt paths so the secondary
  /// transcription-for-history call never holds up the user-visible response.
  /// On timeout the wrapped `task` is also cancelled so it does not keep running
  /// in the background after the user-visible response has already returned.
  ///
  /// Caveat: if `T` is itself an `Optional`, a real `nil` result from `task` is
  /// indistinguishable from a timeout. All current callers use `T = String`, so
  /// this is latent; tighten the type constraint before reusing for optional Ts.
  private func awaitWithTimeout<T>(_ task: Task<T, Never>, timeoutSeconds: Double) async -> T? {
    await withTaskGroup(of: Optional<T>.self, returning: T?.self) { group in
      group.addTask { await task.value }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      if first == nil {
        task.cancel()
      }
      return first
    }
  }

  // MARK: - Prompt Modes (Private Implementation)
  private func performPrompt(audioURL: URL, mode: PromptMode) async throws -> String {
    // Get clipboard context. In screenshot-selection mode (App Store build) this is skipped so the
    // model relies solely on the highlighted region in the screenshot instead of the ⌘C-copied selection.
    let clipboardContext = AppConstants.dictatePromptUsesScreenshotSelection ? nil : getClipboardContext()

    // With nothing selected there is no material to edit, and the model reliably "edits" the
    // instruction instead — a user who said "formuliere Antwort, mein Geburtsdatum ist 15.08.91"
    // got back that same sentence, tidied up. Refusing here is cheaper and far clearer than
    // pasting the user's own words back at them. Screenshot-selection builds are exempt: there
    // the selection lives in the screenshot, so a nil clipboard is the normal case.
    if !AppConstants.dictatePromptUsesScreenshotSelection, clipboardContext == nil {
      DebugLogger.log("PROMPT-MODE: No selected text — refusing to send, nothing to edit")
      ContextLogger.shared.logSignal(
        .promptNoSelection, mode: "prompt",
        detail: ["reason": clipboardManager == nil ? "clipboardUnavailable" : "emptySelection"])
      throw TranscriptionError.noSelectedText
    }

    // The selected text is user-curated ground-truth spelling (unlike the voice instruction,
    // which is machine transcription) — feed it to the same instant glossary learning as
    // typed chat text. Independent of whether the prompt call below succeeds.
    if let clipboardContext {
      GlossaryFastLearner.shared.learnFromTypedText(clipboardContext)
    }

    // Get selected model from settings based on mode
    let selectedPromptModel = getPromptModel()

    guard selectedPromptModel.supportsDictatePrompt else {
      throw TranscriptionError.networkError("Selected Dictate Prompt model does not accept direct audio input. Pick a Gemini model or OpenAI's GPT-4o Audio.")
    }

    try validateAudioFileFormat(at: audioURL)

    switch selectedPromptModel.provider {
    case .gemini:
      return try await executePromptWithGemini(audioURL: audioURL, clipboardContext: clipboardContext, mode: mode, model: selectedPromptModel)
    case .openai:
      return try await executePromptWithOpenAI(audioURL: audioURL, clipboardContext: clipboardContext, mode: mode, model: selectedPromptModel)
    case .local:
      return try await executePromptWithLocal(audioURL: audioURL, clipboardContext: clipboardContext, mode: mode, model: selectedPromptModel)
    case .grok:
      // Defensive: the supportsDictatePrompt guard above already excludes Grok, but throw
      // rather than crash the menu-bar app if a future model/provider change reaches here.
      throw TranscriptionError.networkError("Grok can't process audio directly. Pick a Gemini model or OpenAI's GPT-4o Audio for Dictate Prompt.")
    case .anthropic:
      throw TranscriptionError.networkError("Claude can't process audio directly. Pick a Gemini, OpenAI GPT-Audio, or local model for Dictate Prompt.")
    case .customOpenAI:
      throw TranscriptionError.networkError("Custom endpoint is for Chat only. Pick a Gemini, OpenAI GPT-Audio, or local model for Dictate Prompt.")
    }
  }

  // MARK: - Gemini Dictate Prompt Helpers

  /// Loads the user's Dictate Prompt system prompt (or the built-in default when empty)
  /// and appends the strict output rule. All Dictate Prompt paths (Gemini, OpenAI, text)
  /// use this composition.
  private func buildDictatePromptSystemPrompt(logPrefix: String) -> String {
    // Screenshot-selection mode (App Store build): use the screenshot-based prompt (edit the highlighted region).
    if AppConstants.dictatePromptUsesScreenshotSelection {
      DebugLogger.log("\(logPrefix): [SCREENSHOT-SELECTION] Using screenshot-based system prompt")
      return AppConstants.dictatePromptScreenshotSelectionSystemPrompt + AppConstants.promptModeOutputRule
    }
    let trimmed = SystemPromptsStore.shared
      .loadDictatePromptSystemPrompt()
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let base: String
    if trimmed.isEmpty {
      base = AppConstants.defaultPromptModeSystemPrompt
      DebugLogger.log("\(logPrefix): Using base system prompt")
    } else {
      base = trimmed
      DebugLogger.log("\(logPrefix): Using custom system prompt")
    }
    return base + AppConstants.promptModeOutputRule
  }

  /// Shown when screenshot-selection mode (App Store build) has no screenshot to send. Shared by
  /// the Gemini and OpenAI paths: the situation is identical, and only the Gemini copy of this
  /// check existed — the OpenAI path used to send a screenshot-mode system prompt with no image,
  /// which is exactly the "edit the highlighted region" instruction with nothing to look at.
  private static let screenshotSelectionCaptureFailedMessage =
    "Could not capture a screenshot of the current screen. Check Screen Recording permission in System Settings, then try again."

  /// One prior Dictate Prompt turn, flattened to text and stripped of any provider's message shape.
  struct PromptHistoryTurn {
    let isUser: Bool
    let text: String
  }

  /// The provider-independent content of one Dictate Prompt turn.
  ///
  /// The three provider paths each used to decide, in their own words, whether to attach a
  /// screenshot, what to label it, how to introduce the clipboard selection, and how to flatten the
  /// conversation history. Those decisions are identical — only the wire format differs. Deciding
  /// once here and rendering per provider is what stops the next screenshot-mode guard from landing
  /// in one path only, which is exactly what happened before (see R18: OpenAI shipped without the
  /// capture-failed check and sent "edit the highlighted region" with no image).
  ///
  /// Audio is deliberately **not** part of this. It is the one ingredient the providers genuinely
  /// disagree about: Gemini falls back to the Files API above 20 MB and uploads AAC, OpenAI can only
  /// inline wav/mp3 and must reject oversized input, and the local path never sends audio at all.
  struct DictatePromptEnvelope {
    /// Captured JPEG, or nil when no screenshot belongs in this request.
    let screenshot: Data?
    /// Introduces the screenshot. Only meaningful when `screenshot` is non-nil.
    let screenshotLabel: String
    /// Fully formatted, header included — nil when there is no selection to send.
    let clipboardText: String?
    let history: [PromptHistoryTurn]
    let systemPrompt: String

    var hadScreenshot: Bool { screenshot != nil }
  }

  /// Builds the envelope, applying every guard that used to be copied per provider.
  ///
  /// Throws when screenshot-selection mode can't produce a screenshot — in that mode the screenshot
  /// is the *only* source of the selected text, so a request without one carries an instruction to
  /// edit a highlight that isn't there, and the model invents one.
  private func buildPromptEnvelope(
    mode: PromptMode,
    clipboardContext: String?,
    modelAcceptsImages: Bool,
    supportsScreenshot: Bool,
    logPrefix: String
  ) async throws -> DictatePromptEnvelope {
    let screenshotSelectionMode = AppConstants.dictatePromptUsesScreenshotSelection

    // An audio-only model can't receive the screenshot at all, so in screenshot-selection mode the
    // request would carry neither the selection nor an image. Reject with something actionable.
    if screenshotSelectionMode && supportsScreenshot && !modelAcceptsImages {
      DebugLogger.logError("\(logPrefix): model can't accept images — incompatible with screenshot-selection Dictate Prompt")
      throw TranscriptionError.networkError(
        "This Dictate Prompt model can't read the on-screen selection. Pick a Gemini Dictate Prompt model instead.")
    }

    // In screenshot-selection mode the screenshot always goes, regardless of the user setting,
    // since it is the sole source of the selected text.
    let wantsScreenshot = supportsScreenshot
      && (screenshotSelectionMode || screenshotInPromptModeEnabled())
    var screenshot: Data?
    if wantsScreenshot && modelAcceptsImages {
      screenshot = await ChatWindowManager.shared.captureScreenForPromptMode()
      if screenshot == nil {
        if screenshotSelectionMode {
          DebugLogger.logError("\(logPrefix): Screenshot capture failed in screenshot-selection mode")
          throw TranscriptionError.networkError(Self.screenshotSelectionCaptureFailedMessage)
        }
        DebugLogger.logWarning("\(logPrefix): Screenshot capture returned nothing — sending without it")
      }
    } else if wantsScreenshot {
      DebugLogger.log("\(logPrefix): Screenshot dropped — model does not accept image input.")
    }

    let clipboardText: String?
    if let context = clipboardContext, !context.isEmpty {
      DebugLogger.log("\(logPrefix): Adding clipboard context (length: \(context.count) chars)")
      clipboardText = "\(AppConstants.clipboardSelectionHeader)\n\n\(context)"
    } else {
      DebugLogger.log("\(logPrefix): No clipboard context to add")
      clipboardText = nil
    }

    let historyContents = PromptConversationHistory.shared.getContentsForAPI(mode: mode)
    if historyContents.count / 2 > 0 {
      DebugLogger.log("\(logPrefix): Including \(historyContents.count / 2) previous turns from conversation history")
    }
    let history = historyContents.map {
      PromptHistoryTurn(isUser: $0.role != "model", text: $0.parts.compactMap { $0.text }.joined())
    }

    return DictatePromptEnvelope(
      screenshot: screenshot,
      screenshotLabel: screenshotSelectionMode
        ? "Screenshot of the current screen. The text to edit is the currently selected/highlighted region:"
        : "Current screen:",
      clipboardText: clipboardText,
      history: history,
      systemPrompt: buildDictatePromptSystemPrompt(logPrefix: logPrefix))
  }

  /// Renders the envelope's current-turn content as Gemini parts. Audio is appended by the caller.
  private func geminiUserParts(from envelope: DictatePromptEnvelope) -> [GeminiChatRequest.GeminiChatPart] {
    var parts: [GeminiChatRequest.GeminiChatPart] = []
    if let screenshot = envelope.screenshot {
      parts.append(GeminiChatRequest.GeminiChatPart(
        text: envelope.screenshotLabel, inlineData: nil, fileData: nil, url: nil))
      parts.append(GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: GeminiChatRequest.GeminiInlineData(
          mimeType: "image/jpeg", data: screenshot.base64EncodedString()),
        fileData: nil,
        url: nil))
    }
    if let clipboardText = envelope.clipboardText {
      parts.append(GeminiChatRequest.GeminiChatPart(
        text: clipboardText, inlineData: nil, fileData: nil, url: nil))
    }
    return parts
  }

  /// Renders the envelope's current-turn content as OpenAI content parts. Audio is appended by the
  /// caller. Replaces the hand-written history mapping that lived in the OpenAI path (R20).
  private func openAIUserContent(from envelope: DictatePromptEnvelope) -> [[String: Any]] {
    var content: [[String: Any]] = []
    if let screenshot = envelope.screenshot {
      content.append(["type": "text", "text": envelope.screenshotLabel])
      content.append([
        "type": "image_url",
        "image_url": ["url": "data:image/jpeg;base64,\(screenshot.base64EncodedString())"],
      ])
    }
    if let clipboardText = envelope.clipboardText {
      content.append(["type": "text", "text": clipboardText])
    }
    return content
  }

  /// Performs a Gemini Dictate Prompt request: prepends history, appends the caller-built
  /// user-turn parts, attaches the system instruction, sends the request with retry, and
  /// extracts + normalizes the text response.
  private func performGeminiPromptRequest(
    model: PromptModel,
    mode: PromptMode,
    userParts: [GeminiChatRequest.GeminiChatPart],
    systemPrompt: String,
    credential: GeminiCredential,
    logPrefix: String
  ) async throws -> String {
    guard let transcriptionModel = model.asTranscriptionModel else {
      throw TranscriptionError.networkError("Selected model is not a Gemini model")
    }
    let endpoint = transcriptionModel.apiEndpoint
    DebugLogger.log("\(logPrefix): Using model: \(model.displayName) (\(model.rawValue))")
    DebugLogger.log("\(logPrefix): Using endpoint: \(endpoint)")

    var request = try geminiClient.createRequest(endpoint: endpoint, credential: credential)

    let historyContents = PromptConversationHistory.shared.getContentsForAPI(mode: mode)
    let historyCount = historyContents.count / 2
    if historyCount > 0 {
      DebugLogger.log("\(logPrefix): Including \(historyCount) previous turns from conversation history")
    }
    var contents: [GeminiChatRequest.GeminiChatContent] = historyContents
    contents.append(GeminiChatRequest.GeminiChatContent(role: "user", parts: userParts))

    let systemInstruction = GeminiChatRequest.GeminiSystemInstruction(
      parts: [GeminiChatRequest.GeminiSystemPart(text: systemPrompt)]
    )
    let chatRequest = GeminiChatRequest(
      contents: contents,
      systemInstruction: systemInstruction,
      tools: nil,
      generationConfig: nil,
      model: nil
    )
    request.httpBody = try JSONEncoder().encode(chatRequest)

    let result = try await geminiClient.performRequest(
      request,
      responseType: GeminiChatResponse.self,
      mode: logPrefix,
      withRetry: true
    )

    guard let firstCandidate = result.candidates.first else {
      throw TranscriptionError.networkError("No candidates in Gemini response")
    }

    var textContent = ""
    for part in firstCandidate.content.parts {
      if let text = part.text {
        textContent += text
      }
    }

    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(textContent)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: logPrefix)
    return normalizedText
  }

  // MARK: - Dictate Prompt: shared tail

  /// Where a Dictate Prompt path gets the user's spoken instruction for the history record.
  /// The two cases are mutually exclusive by construction, so no path can accidentally supply
  /// both or neither.
  private enum PromptInstructionSource {
    /// Gemini / OpenAI: transcribed in parallel with the main request, resolved with a timeout.
    case parallelTranscription(Task<String, Never>)
    /// Local: the instruction was transcribed up front, so it is already in hand.
    case known(String)
  }

  /// The tail every Dictate Prompt path shares once it holds the model's answer: resolve the
  /// instruction, append the turn to the conversation history, log the interaction, and report
  /// success. Keeping it in one place means the history record and the interaction log can't
  /// drift apart per provider — they did before, and only the Gemini path's version was ever
  /// checked when either changed.
  private func recordPromptTurn(
    normalizedText: String,
    instruction: PromptInstructionSource,
    mode: PromptMode,
    clipboardContext: String?,
    model: String,
    hadScreenshot: Bool,
    logPrefix: String
  ) async {
    let userInstruction: String
    switch instruction {
    case .known(let text):
      userInstruction = text
    case .parallelTranscription(let task):
      // Budget the wait so a slow second transcription never holds up the paste.
      let result = await awaitWithTimeout(task, timeoutSeconds: 10)
      if result == nil {
        DebugLogger.logWarning("\(logPrefix): History transcription timed out, using placeholder")
      }
      userInstruction = result ?? Self.voiceInstructionPlaceholder
    }

    PromptConversationHistory.shared.append(
      mode: mode,
      selectedText: clipboardContext,
      userInstruction: userInstruction,
      modelResponse: normalizedText
    )
    ContextLogger.shared.logPrompt(
      mode: mode,
      selectedText: clipboardContext,
      userInstruction: userInstruction,
      modelResponse: normalizedText,
      model: model,
      hadScreenshot: hadScreenshot
    )
    DebugLogger.logSuccess("\(logPrefix): Completed successfully (\(normalizedText.count) chars)")
  }

  // MARK: - Gemini Prompt Mode
  /// Spawns a parallel `Task` that transcribes the recording for the chat-history record,
  /// running alongside the main Dictate Prompt request so it adds no latency. Failures fall back
  /// to `voiceInstructionPlaceholder` instead of throwing. Callers `defer { .cancel() }` it so the
  /// second API call is dropped if the main request throws first.
  private func transcribeForHistoryInParallel(
    logPrefix: String,
    _ transcribe: @escaping () async throws -> String
  ) -> Task<String, Never> {
    Task<String, Never> {
      do {
        let text = try await transcribe()
        DebugLogger.log("\(logPrefix): Transcribed voice instruction for history: \"\(text.prefix(50))...\"")
        return text
      } catch {
        DebugLogger.logWarning("\(logPrefix): Failed to transcribe instruction for history: \(error.localizedDescription)")
        return Self.voiceInstructionPlaceholder
      }
    }
  }

  private func executePromptWithGemini(audioURL: URL, clipboardContext: String?, mode: PromptMode, model: PromptModel) async throws -> String {
    guard let credential = await credentialProvider.getCredential() else {
      throw TranscriptionError.noGoogleAPIKey
    }

    DebugLogger.log("PROMPT-MODE-GEMINI: Starting execution")

    // Run transcription for history in parallel with main prompt (no extra latency)
    let transcriptionTask = transcribeForHistoryInParallel(logPrefix: "PROMPT-MODE-GEMINI") {
      try await self.transcribeAudioForHistory(audioURL: audioURL, credential: credential)
    }
    // If the main request throws before we await the task below, cancel the parallel
    // transcription so it doesn't keep burning a second API call in the background.
    defer { transcriptionTask.cancel() }

    let envelope = try await buildPromptEnvelope(
      mode: mode,
      clipboardContext: clipboardContext,
      modelAcceptsImages: true,
      supportsScreenshot: true,
      logPrefix: "PROMPT-MODE-GEMINI")
    var userParts = geminiUserParts(from: envelope)

    // Audio goes after context so the model has the surrounding intent before processing speech.
    let audioSize = getAudioFileSize(at: audioURL)
    if audioSize > AppConstants.maxFileSizeBytes {
      let mimeType = geminiClient.getMimeType(for: audioURL.pathExtension.lowercased())
      let fileURI = try await geminiClient.uploadFile(audioURL: audioURL, credential: credential)
      userParts.append(GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: nil,
        fileData: GeminiChatRequest.GeminiFileData(fileUri: fileURI, mimeType: mimeType),
        url: nil
      ))
    } else {
      let audioData: Data
      let mimeType: String
      if let aacData = AudioTranscoder.aacData(for: audioURL) {
        audioData = aacData
        mimeType = AudioTranscoder.aacMimeType
      } else {
        audioData = try Data(contentsOf: audioURL)
        mimeType = geminiClient.getMimeType(for: audioURL.pathExtension.lowercased())
      }
      userParts.append(GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: GeminiChatRequest.GeminiInlineData(mimeType: mimeType, data: audioData.base64EncodedString()),
        fileData: nil,
        url: nil
      ))
    }

    let normalizedText = try await performGeminiPromptRequest(
      model: model,
      mode: mode,
      userParts: userParts,
      systemPrompt: envelope.systemPrompt,
      credential: credential,
      logPrefix: "PROMPT-MODE-GEMINI"
    )

    await recordPromptTurn(
      normalizedText: normalizedText,
      instruction: .parallelTranscription(transcriptionTask),
      mode: mode,
      clipboardContext: clipboardContext,
      model: model.rawValue,
      hadScreenshot: envelope.hadScreenshot,
      logPrefix: "PROMPT-MODE-GEMINI")
    return normalizedText
  }

  // MARK: - OpenAI Prompt Mode

  /// Dictate Prompt via OpenAI's Chat Completions API with an inline `input_audio` content
  /// part. Mirrors the Gemini flow: system prompt + optional screenshot + clipboard context +
  /// audio, all in one request. Non-streaming, single-shot response.
  /// Reference: https://platform.openai.com/docs/guides/audio
  private func executePromptWithOpenAI(
    audioURL: URL,
    clipboardContext: String?,
    mode: PromptMode,
    model: PromptModel
  ) async throws -> String {
    let apiKey = try ProviderCredentials.require(.openAI)

    DebugLogger.log("PROMPT-MODE-OPENAI: Starting execution model=\(model.rawValue)")

    // Run transcription for history in parallel (mirrors the Gemini path). Uses the cheap
    // gpt-4o-mini-transcribe so it doesn't require a Gemini key.
    let transcriptionTask = transcribeForHistoryInParallel(logPrefix: "PROMPT-MODE-OPENAI") {
      try await self.transcribeWithOpenAI(audioURL: audioURL, modelID: "gpt-4o-mini-transcribe")
    }
    // If the main request throws before we await the task below, cancel the parallel
    // transcription so it doesn't keep burning a second API call in the background.
    defer { transcriptionTask.cancel() }

    // gpt-4o-audio-preview is audio-only and rejects image_url content parts with HTTP 400
    // ("This model does not support image_url content."), so the envelope is told what this model
    // can take and drops or rejects the screenshot accordingly.
    let envelope = try await buildPromptEnvelope(
      mode: mode,
      clipboardContext: clipboardContext,
      modelAcceptsImages: model.supportsImageInput,
      supportsScreenshot: true,
      logPrefix: "PROMPT-MODE-OPENAI")
    var userContent = openAIUserContent(from: envelope)

    // OpenAI's Chat Completions API embeds audio inline (base64). Reject oversized audio up
    // front with an actionable error — Gemini falls back to the Files API for >20 MB inputs,
    // but OpenAI's audio-preview endpoint has no equivalent here, so the request would simply
    // fail with a body-size error after a long upload.
    let audioFileSize = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int) ?? 0
    if audioFileSize > AppConstants.maxFileSizeBytes {
      let sizeMB = Double(audioFileSize) / 1_048_576.0
      let limitMB = Double(AppConstants.maxFileSizeBytes) / 1_048_576.0
      DebugLogger.logError("PROMPT-MODE-OPENAI: Audio too large (\(String(format: "%.1f", sizeMB)) MB > \(String(format: "%.1f", limitMB)) MB limit)")
      throw TranscriptionError.fileError("Audio is too long for OpenAI Dictate Prompt (\(String(format: "%.1f", sizeMB)) MB > \(String(format: "%.1f", limitMB)) MB limit). Switch to a Gemini Dictate Prompt model for longer recordings.")
    }

    let audioData: Data
    do {
      audioData = try Data(contentsOf: audioURL)
    } catch {
      throw TranscriptionError.networkError("Could not read audio file: \(error.localizedDescription)")
    }
    let fileExtension = audioURL.pathExtension.lowercased()
    let audioFormat = OpenAIChatProvider.openAIAudioFormat(forExtension: fileExtension)
    let base64Audio = audioData.base64EncodedString()
    userContent.append([
      "type": "input_audio",
      "input_audio": [
        "data": base64Audio,
        "format": audioFormat,
      ] as [String: Any],
    ])

    // Assemble messages: system → history → current user turn.
    var messages: [[String: Any]] = [["role": "system", "content": envelope.systemPrompt]]
    messages.append(contentsOf: envelope.history.map {
      ["role": $0.isUser ? "user" : "assistant", "content": $0.text]
    })
    messages.append(["role": "user", "content": userContent])

    let body: [String: Any] = [
      "model": model.rawValue,
      "modalities": ["text"],
      "messages": messages,
    ]

    guard let endpointURL = URL(string: "https://api.openai.com/v1/chat/completions") else {
      throw TranscriptionError.networkError("Invalid OpenAI endpoint URL")
    }
    var request = URLRequest(url: endpointURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = Constants.resourceTimeout
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    // Auto-retry on 429 with exponential backoff, matching the Gemini path (which gets this
    // for free via GeminiAPIClient.performRequest(withRetry: true)). Short rate-limit spikes
    // are common on busy keys; surfacing them immediately to the user is unnecessary churn.
    let (data, http) = try await Self.performWithRetryOn429(
      request: request,
      session: makeTranscriptionURLSession(),
      logPrefix: "PROMPT-MODE-OPENAI"
    )
    if http.statusCode < 200 || http.statusCode >= 300 {
      let bodyString = String(data: data, encoding: .utf8) ?? ""
      DebugLogger.logError("PROMPT-MODE-OPENAI: HTTP \(http.statusCode): \(bodyString.prefix(500))")
      switch http.statusCode {
      case 401:
        throw TranscriptionError.invalidAPIKey
      case 429:
        // "No credit on the API account" arrives as 429 insufficient_quota — a billing
        // problem, not a rate limit (same mapping as the transcription path).
        if bodyString.contains("insufficient_quota") {
          throw TranscriptionError.billingRequired()
        }
        throw TranscriptionError.rateLimited(retryAfter: nil)
      default:
        throw TranscriptionError.serverError(http.statusCode)
      }
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let choices = json["choices"] as? [[String: Any]],
          let firstChoice = choices.first,
          let message = firstChoice["message"] as? [String: Any] else {
      throw TranscriptionError.networkError("Unexpected OpenAI response shape")
    }

    // The audio-preview model returns plain string content for text-only output.
    let rawText: String
    if let str = message["content"] as? String {
      rawText = str
    } else if let arr = message["content"] as? [[String: Any]] {
      rawText = arr.compactMap { $0["text"] as? String }.joined()
    } else {
      throw TranscriptionError.networkError("OpenAI returned no text content")
    }

    // gpt-audio-1.5 sometimes answers an edit instruction with a JSON edit object rather than the
    // edited text. Unwrap it before anything else touches the string, or the JSON is what the user
    // pastes. No-op for the plain-text replies that are the norm.
    let unwrappedText = TextProcessingUtility.unwrappingJSONEditResponse(
      rawText, selectedText: clipboardContext)
    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(unwrappedText)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "PROMPT-MODE-OPENAI")

    await recordPromptTurn(
      normalizedText: normalizedText,
      instruction: .parallelTranscription(transcriptionTask),
      mode: mode,
      clipboardContext: clipboardContext,
      model: model.rawValue,
      hadScreenshot: envelope.hadScreenshot,
      logPrefix: "PROMPT-MODE-OPENAI")
    return normalizedText
  }

  // MARK: - Local Prompt Mode

  /// Dictate Prompt via a local OpenAI-compatible server (Ollama / LM Studio). Local LLMs are
  /// text-only, so this runs a two-step flow:
  ///   1. transcribe the spoken instruction with the user's selected Dictate transcription model
  ///      (pick offline Whisper there for a fully-offline experience), then
  ///   2. send `system prompt + clipboard context + instruction` to the local model and collect
  ///      the rewritten text via the streaming provider.
  /// No screenshot/image is sent (local text models can't read images in Phase 1).
  private func executePromptWithLocal(
    audioURL: URL,
    clipboardContext: String?,
    mode: PromptMode,
    model: PromptModel
  ) async throws -> String {
    let modelID = LocalLLMPreferences.modelID
    DebugLogger.log("PROMPT-MODE-LOCAL: Starting execution endpoint=\(LocalLLMPreferences.chatCompletionsURL) model=\(modelID)")

    // Step 1: transcribe the spoken instruction through the existing transcription pipeline.
    // Use `performTranscription` directly so we don't disturb the `currentTranscriptionTask` slot
    // that the public `transcribe` entry point manages.
    let instruction = try await performTranscription(audioURL: audioURL)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !instruction.isEmpty else {
      throw TranscriptionError.networkError("Could not transcribe the voice instruction for the local model.")
    }
    DebugLogger.log("PROMPT-MODE-LOCAL: Transcribed instruction (\(instruction.count) chars)")

    // Step 2: build the user turn (clipboard context + instruction) and prior history, in the
    // Gemini-format `contents` the provider expects. `supportsScreenshot: false` — local text
    // models can't read images in Phase 1 — which also means the screenshot-selection guards are
    // correctly skipped rather than re-decided here.
    let envelope = try await buildPromptEnvelope(
      mode: mode,
      clipboardContext: clipboardContext,
      modelAcceptsImages: false,
      supportsScreenshot: false,
      logPrefix: "PROMPT-MODE-LOCAL")

    var userText = ""
    if let clipboardText = envelope.clipboardText {
      userText += "\(clipboardText)\n\n"
    }
    userText += "VOICE INSTRUCTION:\n\(instruction)"

    var contents: [[String: Any]] = envelope.history.map {
      ["role": $0.isUser ? "user" : "model", "parts": [["text": $0.text]]]
    }
    contents.append(["role": "user", "parts": [["text": userText]]])

    let systemInstruction: [String: Any]? = envelope.systemPrompt.isEmpty
      ? nil : ["parts": [["text": envelope.systemPrompt]]]

    let stream = LocalLLMChatProvider.shared.sendChatStream(
      model: modelID,
      contents: contents,
      systemInstruction: systemInstruction,
      tools: [],
      options: .textTransform
    )
    var combined = ""
    for try await event in stream {
      try Task.checkCancellation()
      if case .textDelta(let delta) = event { combined += delta }
    }

    let normalizedText = TextProcessingUtility.normalizeTranscriptionText(combined)
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "PROMPT-MODE-LOCAL")

    await recordPromptTurn(
      normalizedText: normalizedText,
      instruction: .known(instruction),
      mode: mode,
      clipboardContext: clipboardContext,
      model: "local:\(modelID)",
      hadScreenshot: false,
      logPrefix: "PROMPT-MODE-LOCAL")
    return normalizedText
  }

  /// Transcribes audio to text for use in conversation history.
  /// Uses a lightweight transcription call to get the user's voice instruction as text.
  private func transcribeAudioForHistory(audioURL: URL, credential: GeminiCredential) async throws -> String {
    // Use the existing transcription logic but with a simpler prompt
    let audioData: Data
    let mimeType: String
    if let aacData = AudioTranscoder.aacData(for: audioURL) {
      audioData = aacData
      mimeType = AudioTranscoder.aacMimeType
    } else {
      audioData = try Data(contentsOf: audioURL)
      mimeType = geminiClient.getMimeType(for: audioURL.pathExtension.lowercased())
    }
    let base64Audio = audioData.base64EncodedString()

    // Audio input dominates the cost here, so track the default (cheapest-audio) Flash-Lite tier.
    let endpoint = SettingsDefaults.selectedTranscriptionModel.apiEndpoint
    var request = try geminiClient.createRequest(endpoint: endpoint, credential: credential)

    let userParts: [GeminiChatRequest.GeminiChatPart] = [
      GeminiChatRequest.GeminiChatPart(
        text: nil,
        inlineData: GeminiChatRequest.GeminiInlineData(mimeType: mimeType, data: base64Audio),
        fileData: nil,
        url: nil
      )
    ]

    let systemInstruction = GeminiChatRequest.GeminiSystemInstruction(
      parts: [GeminiChatRequest.GeminiSystemPart(text: "Transcribe this audio exactly. Return only the transcribed text, nothing else.")]
    )

    let chatRequest = GeminiChatRequest(
      contents: [GeminiChatRequest.GeminiChatContent(role: "user", parts: userParts)],
      systemInstruction: systemInstruction,
      tools: nil,
      generationConfig: nil,
      model: nil
    )

    request.httpBody = try JSONEncoder().encode(chatRequest)

    let result = try await geminiClient.performRequest(
      request,
      responseType: GeminiChatResponse.self,
      mode: "PROMPT-HISTORY-TRANSCRIBE",
      withRetry: true
    )

    guard let firstCandidate = result.candidates.first,
          let text = firstCandidate.content.parts.first?.text else {
      throw TranscriptionError.networkError("No transcription in response")
    }

    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  
  // MARK: - Text-to-Speech Mode

  /// Reads a user *selection* aloud. The text may be code, markdown, or log output, so it's
  /// first passed through Smart Rewrite (when the user has it on) to produce something more
  /// pleasant to listen to before TTS. Used by the global Read Aloud shortcut.
  func readSelectionAloud(
    _ text: String, voiceName: String? = nil,
    onChunkReady: ((Data, Int, Int) -> Void)? = nil
  ) async throws -> Data {
    try await runReadAloud(
      text, voiceName: voiceName, applySmartRewrite: true, onChunkReady: onChunkReady)
  }

  /// Reads LLM-generated *prose* aloud — already intended for human consumption, so the
  /// Smart Rewrite pre-pass is skipped. Used by the chat reply read-aloud path.
  func readProseAloud(
    _ text: String, voiceName: String? = nil,
    onChunkReady: ((Data, Int, Int) -> Void)? = nil
  ) async throws -> Data {
    try await runReadAloud(
      text, voiceName: voiceName, applySmartRewrite: false, onChunkReady: onChunkReady)
  }

  /// Runs the optional rewrite-then-TTS pipeline inside a single tracked `Task` stored on
  /// `currentTTSTask` so `cancelTTS()` can abort during the rewrite phase too (otherwise the
  /// rewrite would complete and TTS would start playing after the user already pressed Stop).
  private func runReadAloud(
    _ text: String, voiceName: String?, applySmartRewrite: Bool,
    onChunkReady: ((Data, Int, Int) -> Void)? = nil
  ) async throws -> Data {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw TranscriptionError.networkError("Text is empty") }

    let task = Task<Data, Error> {
      let spoken = applySmartRewrite ? try await self.maybeRewriteForSpeech(trimmed) : trimmed
      try Task.checkCancellation()
      // Always sanitize last, on whatever text is about to be synthesized: the chat path never
      // runs Smart Rewrite, and even the rewrite model can hand back Markdown.
      let textForTTS = Self.sanitizedForSpeech(spoken)
      return try await self.performTTS(
        text: textForTTS, voiceName: voiceName, onChunkReady: onChunkReady)
    }
    currentTTSTask = task
    // See `transcribe` for the identity-check rationale.
    defer { if currentTTSTask == task { currentTTSTask = nil } }
    return try await task.value
  }

  /// Markdown/URL-stripped form of the text, or the text unchanged when stripping would leave
  /// nothing to say (a selection that was entirely a code block or a link list). Silence is a
  /// worse outcome than a badly-formatted reading, so the fallback keeps the original.
  private static func sanitizedForSpeech(_ text: String) -> String {
    let sanitized = SpeechTextSanitizer.plainSpeech(from: text)
    guard !sanitized.isEmpty else {
      DebugLogger.logWarning("READ-ALOUD-SANITIZE: Stripping left no speakable text; using original \(text.count) chars")
      return text
    }
    if sanitized.count != text.count {
      DebugLogger.log("READ-ALOUD-SANITIZE: \(text.count) chars -> \(sanitized.count) chars after removing Markdown and URLs")
    }
    return sanitized
  }

  /// Runs the Smart Rewrite pass if enabled. Returns the original text on any non-cancellation
  /// failure — Read Aloud should still play in that case rather than fail outright. A
  /// cancellation (either Swift `CancellationError` or `URLError.cancelled` from the network
  /// layer when the surrounding Task is cancelled) is rethrown so the caller aborts.
  private func maybeRewriteForSpeech(_ text: String) async throws -> String {
    guard ReadAloudPreferences.smartRewriteEnabled else {
      DebugLogger.log("READ-ALOUD-REWRITE: Disabled by user, using original text")
      return text
    }
    do {
      let rewritten = try await rewriteForSpeech(text)
      DebugLogger.logSuccess("READ-ALOUD-REWRITE: Rewrote \(text.count) chars -> \(rewritten.count) chars")
      return rewritten
    } catch {
      // If the surrounding Task got cancelled, propagate that regardless of which concrete
      // error type bubbled up (URLSession surfaces cancellation as `URLError(.cancelled)`,
      // not `CancellationError`).
      try Task.checkCancellation()
      DebugLogger.logWarning("READ-ALOUD-REWRITE: Rewrite failed (\(error.localizedDescription)); falling back to original text")
      return text
    }
  }

  /// Single-shot "rewrite for speech" pass, provider-agnostic. Routes through the user's selected
  /// chat model (which `ModelSelectionReconciler` keeps on a provider that has a key), so Smart
  /// Rewrite works for Gemini / OpenAI / xAI alike — not just Gemini. Throws if no provider key is
  /// available; the caller (`maybeRewriteForSpeech`) then falls back to the original text.
  private func rewriteForSpeech(_ text: String) async throws -> String {
    // Exclude image-generation models (Nano Banana): their request path drops systemInstruction
    // entirely (see GeminiChatProvider), so the rewrite prompt never reaches the model and it
    // answers like a chat assistant — wildly expanding the text. Fall back to the default text
    // model instead; it shares the Gemini credential the image model already requires.
    let model = PromptModel.loadPromptModel(
      forKey: UserDefaultsKeys.selectedChatModel, default: SettingsDefaults.selectedChatModel,
      validate: { !$0.generatesImages })
    guard model.hasRequiredCredential else {
      throw TranscriptionError.noGoogleAPIKey
    }
    let systemPrompt = SystemPromptsStore.shared.loadReadAloudRewritePrompt()
    let provider = LLMProviderFactory.provider(for: model)
    let contents: [[String: Any]] = [["role": "user", "parts": [["text": text]]]]
    let systemInstruction: [String: Any]? = systemPrompt.isEmpty
      ? nil : ["parts": [["text": systemPrompt]]]

    // Pure text transform: no tools, no grounding, and crucially no built-in code_execution —
    // otherwise the model can run code and leak executable_code / code_execution_result parts
    // (or the system prompt itself) into the reply, which would then be read aloud.
    let stream = provider.sendChatStream(
      model: model.rawValue,
      contents: contents,
      systemInstruction: systemInstruction,
      tools: [],
      options: .textTransform  // one-shot rewrite transform, no conversation continuity
    )
    var combined = ""
    for try await event in stream {
      if case .textDelta(let delta) = event { combined += delta }
    }
    let cleaned = combined.trimmingCharacters(in: .whitespacesAndNewlines)
    // If the model returns nothing useful, fall back to the original text — empty TTS would
    // surface as a confusing "Text is empty" error to the user.
    return cleaned.isEmpty ? text : cleaned
  }

  /// Multi-provider Read Aloud. Dispatches by the selected model's provider. All three providers
  /// emit raw PCM (s16le 24kHz mono), which is exactly what `MenuBarController.playTTSAudio`
  /// expects, so the returned `Data` is provider-independent.
  private func performTTS(
    text: String, voiceName: String? = nil,
    onChunkReady: ((Data, Int, Int) -> Void)? = nil
  ) async throws -> Data {
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let model = ReadAloudPreferences.model
    // Caller override (nil for the Read Aloud shortcut) → the user's picked voice for this
    // provider, falling back to the provider's default when none is set.
    let voice = voiceName ?? ReadAloudPreferences.voice(for: model)

    DebugLogger.log("TTS: Starting text-to-speech (length: \(trimmedText.count) chars, voice: \(voice), model: \(model.displayName), provider: \(model.provider.displayName))")

    // ChunkTTSService handles splitting, parallelism, retry/rate-limit coordination, and
    // merging. Every provider returns raw PCM (s16le 24kHz mono), so the merged result feeds
    // `playTTSAudio` unchanged — we only supply a per-chunk synthesizer for the chosen provider.
    let synthesizeChunk: (String) async throws -> Data
    switch model.provider {
    case .gemini:
      guard let credential = await credentialProvider.getCredential() else {
        throw TranscriptionError.noGoogleAPIKey
      }
      synthesizeChunk = { [weak self] chunkText in
        guard let self else { throw TranscriptionError.networkError("Speech service was deallocated") }
        return try await self.synthesizeGeminiTTSChunk(text: chunkText, voice: voice, model: model, credential: credential)
      }
    case .openai:
      synthesizeChunk = { [weak self] chunkText in
        guard let self else { throw TranscriptionError.networkError("Speech service was deallocated") }
        return try await self.synthesizeOpenAITTS(text: chunkText, voice: voice, model: model)
      }
    case .xai:
      synthesizeChunk = { [weak self] chunkText in
        guard let self else { throw TranscriptionError.networkError("Speech service was deallocated") }
        return try await self.synthesizeXAITTS(text: chunkText, voice: voice, model: model)
      }
    }

    let chunkService = ChunkTTSService()
    chunkService.progressDelegate = chunkProgressDelegate
    return try await chunkService.synthesize(
      text: trimmedText, model: model, onChunkReady: onChunkReady,
      synthesizeText: synthesizeChunk)
  }

  // MARK: - Gemini TTS (Generative Language API) — synthesizes one chunk per call.
  private func synthesizeGeminiTTSChunk(text: String, voice: String, model: TTSModel, credential: GeminiCredential) async throws -> Data {
    let endpoint = model.apiEndpoint
    var request = try geminiClient.createRequest(endpoint: endpoint, credential: credential)

    let ttsRequest = GeminiTTSRequest(
      contents: [GeminiTTSRequest.GeminiTTSContent(parts: [GeminiTTSRequest.GeminiTTSPart(text: "Say the following: \(text)")])],
      generationConfig: GeminiTTSRequest.GeminiTTSGenerationConfig(
        responseModalities: ["AUDIO"],
        speechConfig: GeminiTTSRequest.GeminiTTSSpeechConfig(
          voiceConfig: GeminiTTSRequest.GeminiTTSVoiceConfig(
            prebuiltVoiceConfig: GeminiTTSRequest.GeminiTTSPrebuiltVoiceConfig(voiceName: voice)
          )
        )
      )
    )
    request.httpBody = try JSONEncoder().encode(ttsRequest)

    let result = try await geminiClient.performRequest(
      request,
      responseType: GeminiChatResponse.self,
      mode: "TTS",
      withRetry: true
    )

    guard let base64Audio = result.candidates.first?.content.parts.first(where: { $0.inlineData != nil })?.inlineData?.data,
          let decoded = Data(base64Encoded: base64Audio) else {
      DebugLogger.logError("TTS: Failed to decode base64 audio from Gemini response")
      throw TranscriptionError.networkError("Failed to decode base64 audio data")
    }
    return decoded
  }

  /// OpenAI TTS — `response_format:"pcm"` returns raw s16le 24kHz mono PCM (no header).
  private func synthesizeOpenAITTS(text: String, voice: String, model: TTSModel) async throws -> Data {
    let token = try ProviderCredentials.require(.openAI)
    guard let url = URL(string: AppConstants.openAISpeechEndpoint) else { throw TranscriptionError.invalidRequest }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let body: [String: Any] = [
      "model": model.rawValue,
      "input": text,
      "voice": voice,
      "response_format": "pcm",
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, http) = try await Self.performWithRetryOn429(
      request: request, session: makeTranscriptionURLSession(), logPrefix: "TTS-OPENAI")
    guard http.statusCode == 200 else {
      let bodyText = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
      throw TranscriptionError.networkError("OpenAI TTS failed (HTTP \(http.statusCode)): \(bodyText)")
    }
    return data
  }

  /// xAI Grok TTS — `output_format:{codec:"pcm",sample_rate:24000}` returns raw s16le 24kHz mono PCM.
  ///
  /// We deliberately send **no** `model` field: the voice (`voice_id`) is the only selector we need,
  /// and omitting the model keeps us off xAI's slug churn. `TTSModel.grokVoiceTTS`'s raw value
  /// (`grok-voice-tts-1.0`) is therefore a *display label only* — it never reaches the wire. Do not
  /// "fix" this by threading `model.rawValue` into the body: that slug now 404s. Verified
  /// 2026-08-05 — the live slug is `grok-tts`, and all five shipped voices return 200 without it.
  private func synthesizeXAITTS(text: String, voice: String, model: TTSModel) async throws -> Data {
    let token = try ProviderCredentials.require(.xAI)
    guard let url = URL(string: AppConstants.xaiTTSEndpoint) else { throw TranscriptionError.invalidRequest }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let body: [String: Any] = [
      "text": text,
      "voice_id": voice,
      "language": "auto",
      "output_format": ["codec": "pcm", "sample_rate": 24000] as [String: Any],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, http) = try await Self.performWithRetryOn429(
      request: request, session: makeTranscriptionURLSession(), logPrefix: "TTS-XAI")
    guard http.statusCode == 200 else {
      let bodyText = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
      throw TranscriptionError.networkError("xAI TTS failed (HTTP \(http.statusCode)): \(bodyText)")
    }
    return data
  }

  // MARK: - OpenAI Transcription (cloud)

  private func transcribeWithOpenAI(audioURL: URL, modelID: String, dictationHint: String? = nil) async throws -> String {
    let token = try ProviderCredentials.require(.openAI)
    guard let endpoint = URL(string: AppConstants.openAITranscriptionsEndpoint) else {
      throw TranscriptionError.invalidRequest
    }

    let audioData = try Data(contentsOf: audioURL)
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = mimeTypeForAudioExtension(fileExtension)

    let session = makeTranscriptionURLSession()
    return try await sendOpenAICompatibleTranscriptionRequest(
      url: endpoint,
      fieldName: "file",
      modelID: modelID,
      audioData: audioData,
      fileExtension: fileExtension,
      mimeType: mimeType,
      bearerToken: token,
      extraHeaders: [],
      session: session,
      logPrefix: "OPENAI-TRANSCRIPTION",
      dictationHint: dictationHint
    )
  }

  // MARK: - xAI Grok Transcription (cloud, /v1/stt)

  /// Transcribes audio via xAI's hosted Speech-to-Text endpoint. The wire format is the same
  /// OpenAI-style multipart (`model`/`language`/`file`) the OpenAI path uses, and xAI ignores the
  /// extra `prompt` field gracefully — verified live — so we reuse the shared helper.
  private func transcribeWithXAI(audioURL: URL, dictationHint: String? = nil) async throws -> String {
    let token = try ProviderCredentials.require(.xAI)
    guard let endpoint = URL(string: AppConstants.xaiSTTEndpoint) else {
      throw TranscriptionError.invalidRequest
    }

    let audioData = try Data(contentsOf: audioURL)
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = mimeTypeForAudioExtension(fileExtension)

    let session = makeTranscriptionURLSession()
    return try await sendOpenAICompatibleTranscriptionRequest(
      url: endpoint,
      fieldName: "file",
      modelID: "grok-stt",
      audioData: audioData,
      fileExtension: fileExtension,
      mimeType: mimeType,
      bearerToken: token,
      extraHeaders: [],
      session: session,
      logPrefix: "XAI-TRANSCRIPTION",
      dictationHint: dictationHint
    )
  }

  // MARK: - Self-hosted Transcription Endpoint

  private func transcribeWithSelfHostedEndpoint(audioURL: URL) async throws -> String {
    let configuredEndpoint = UserDefaults.standard.string(forKey: UserDefaultsKeys.customTranscriptionAPIURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !configuredEndpoint.isEmpty else {
      throw TranscriptionError.networkError("Self-hosted transcription endpoint URL is not configured. Set it in Settings → Dictate.")
    }
    guard let baseURL = URL(string: configuredEndpoint) else {
      throw TranscriptionError.invalidRequest
    }

    let bearerToken = (keychainManager.get(.customTranscriptionBearerToken) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let extraHeaders = keychainManager.getCustomTranscriptionHeaders()
    let audioData = try Data(contentsOf: audioURL)
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = mimeTypeForAudioExtension(fileExtension)

    let urlPath = baseURL.path
    let isBaseURL = urlPath.isEmpty || urlPath == "/"
    let base = configuredEndpoint.hasSuffix("/") ? String(configuredEndpoint.dropLast()) : configuredEndpoint

    // For a bare host, try the OpenAI layout first, then fall back to whisper-asr-webservice.
    // For a full path, try the same path with both field-name conventions.
    var attempts: [(URL, String)] = []
    if isBaseURL {
      if let u = URL(string: "\(base)/v1/audio/transcriptions") { attempts.append((u, "file")) }
      if let u = URL(string: "\(base)/asr") { attempts.append((u, "audio_file")) }
    } else {
      attempts.append((baseURL, "file"))
      attempts.append((baseURL, "audio_file"))
    }

    var lastError: Error = TranscriptionError.networkError("All request attempts failed")
    let session = makeTranscriptionURLSession()

    for (attemptURL, fieldName) in attempts {
      do {
        return try await sendOpenAICompatibleTranscriptionRequest(
          url: attemptURL,
          fieldName: fieldName,
          modelID: fieldName == "file" ? "whisper-1" : nil,
          audioData: audioData,
          fileExtension: fileExtension,
          mimeType: mimeType,
          bearerToken: bearerToken.isEmpty ? nil : bearerToken,
          extraHeaders: extraHeaders,
          session: session,
          logPrefix: "SELF-HOSTED-TRANSCRIPTION"
        )
      } catch TranscriptionError.serverError(let code) where code == 404 || code == 422 {
        DebugLogger.log("SELF-HOSTED-TRANSCRIPTION: \(code) on \(attemptURL.path) — trying next")
        lastError = TranscriptionError.serverError(code)
      }
    }
    throw lastError
  }

  // MARK: - OpenRouter Transcription (chat completions with an audio part)

  /// Transcribes through OpenRouter.
  ///
  /// OpenRouter has no `/v1/audio/transcriptions` — audio is a content part on a normal chat
  /// completion, base64-encoded, no URLs (https://openrouter.ai/docs/features/multimodal/audio).
  /// That is why this cannot reuse the multipart helper the OpenAI/self-hosted paths share, and why
  /// the dictation instruction goes in as the message text rather than a `prompt` field.
  ///
  /// The upside for the user is that one entry covers every audio-capable model OpenRouter routes
  /// to: switching from a Gemini tier to `openai/gpt-audio` is a model slug, not a new provider.
  private func transcribeWithOpenRouter(audioURL: URL, promptOverride: String?) async throws -> String {
    let apiKey = (keychainManager.get(.openRouter) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !apiKey.isEmpty else {
      throw TranscriptionError.networkError("OpenRouter API key is not configured. Add it in Settings → Dictate.")
    }
    guard let url = URL(string: AppConstants.openRouterChatCompletionsEndpoint) else {
      throw TranscriptionError.invalidRequest
    }

    // Same AAC transcode the Gemini path uses: a raw .wav recording is ~1.5 MB per minute, and this
    // body is JSON with the audio base64'd inside it.
    let audioData: Data
    let format: String
    if let aacData = AudioTranscoder.aacData(for: audioURL) {
      audioData = aacData
      format = "m4a"
    } else {
      audioData = try Data(contentsOf: audioURL)
      format = Self.openRouterAudioFormat(forExtension: audioURL.pathExtension.lowercased())
    }

    let modelID = TranscriptionTuning.openRouterModelID
    let instruction = geminiTranscriptionInstruction(promptOverride: promptOverride)
    DebugLogger.log("OPENROUTER-TRANSCRIPTION: model=\(modelID) format=\(format) bytes=\(audioData.count)")

    let body: [String: Any] = [
      "model": modelID,
      // Same reasoning as the Gemini path: this is a reproduce-what-was-said task, so don't let the
      // model sample alternatives. OpenRouter forwards `temperature` to the underlying provider.
      "temperature": TranscriptionTuning.temperature,
      "messages": [
        [
          "role": "user",
          "content": [
            ["type": "text", "text": instruction],
            ["type": "input_audio", "input_audio": ["data": audioData.base64EncodedString(), "format": format]],
          ],
        ]
      ],
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    // OpenRouter attributes traffic by these two headers; they are optional but make the app
    // identifiable on the user's OpenRouter dashboard instead of showing up as anonymous calls.
    request.setValue("https://github.com/mgsgde/whisper-shortcut", forHTTPHeaderField: "HTTP-Referer")
    request.setValue("WhisperShortcut", forHTTPHeaderField: "X-Title")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, http) = try await Self.performWithRetryOn429(
      request: request, session: makeTranscriptionURLSession(), logPrefix: "OPENROUTER-TRANSCRIPTION")

    guard (200...299).contains(http.statusCode) else {
      let message = Self.openRouterErrorMessage(from: data)
      DebugLogger.logError("OPENROUTER-TRANSCRIPTION: HTTP \(http.statusCode) — \(message ?? "no message")")
      switch http.statusCode {
      case 401, 403: throw TranscriptionError.invalidAPIKey
      // OpenRouter gates audio requests on account balance and answers 402 ("This request requires
      // at least $0.50 in balance for audio") — verified live. Mapping it to a generic server error
      // would tell the user "something went wrong" for a problem only they can fix, and only at
      // https://openrouter.ai/settings/credits.
      case 402: throw TranscriptionError.billingRequired(topUpURL: OpenRouterOAuthConfig.creditsURL)
      case 429:
        let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
        throw TranscriptionError.rateLimited(retryAfter: retryAfter)
      default: throw TranscriptionError.serverError(http.statusCode)
      }
    }

    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = json["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String
    else {
      throw TranscriptionError.networkError("OpenRouter returned no transcription text")
    }

    let normalized = TextProcessingUtility.normalizeTranscriptionText(content)
    try TextProcessingUtility.validateSpeechText(normalized, mode: "TRANSCRIPTION-MODE")
    return normalized
  }

  /// Maps a recording's file extension onto one of the format strings OpenRouter documents
  /// (wav, mp3, aiff, aac, ogg, flac, m4a, pcm16, pcm24). The app records `.wav`.
  private static func openRouterAudioFormat(forExtension ext: String) -> String {
    switch ext {
    case "mp3": return "mp3"
    case "m4a", "mp4": return "m4a"
    case "flac": return "flac"
    case "ogg": return "ogg"
    case "aiff", "aif": return "aiff"
    case "aac": return "aac"
    default: return "wav"
    }
  }

  private static func openRouterErrorMessage(from data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
      return message
    }
    return String(data: data, encoding: .utf8)?.prefix(200).description
  }

  // MARK: - OpenAI-Compatible Multipart Helper

  /// Shared multipart POST for both the OpenAI cloud path and the self-hosted endpoint path.
  /// Forwards Whisper Glossary as the `prompt` field and the language selection as the `language`
  /// field whenever the OpenAI layout (`file`) is used. The whisper-asr-webservice layout
  /// (`audio_file`) doesn't accept the same multipart fields, so those hints are skipped there.
  /// `dictationHint` is a longer instruction string (e.g. the dictation system prompt) that
  /// `gpt-4o-transcribe`/`gpt-4o-mini-transcribe` accept via the same `prompt` field —
  /// OpenAI docs: "similarly to how you would prompt other GPT-4o models". When set, it is
  /// combined with the glossary: instruction-wrapped for instructable models (gpt-4o-transcribe
  /// family, grok-stt), bare for whisper-1 priming. Callers must NOT pass `dictationHint` for
  /// `whisper-1` (224-token limit).
  ///
  /// `gpt-transcribe` is the exception both ways — see `isContextFieldStyle` below: it takes
  /// vocabulary through a dedicated `keywords` field and `dictationHint` is dropped for it.
  private func sendOpenAICompatibleTranscriptionRequest(
    url: URL, fieldName: String,
    modelID: String?,
    audioData: Data, fileExtension: String, mimeType: String,
    bearerToken: String?, extraHeaders: [[String: String]],
    session: URLSession,
    logPrefix: String,
    dictationHint: String? = nil
  ) async throws -> String {
    var requestURL = url
    if fieldName == "audio_file",
       var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      var items = comps.queryItems ?? []
      if !items.contains(where: { $0.name == "output" }) {
        items.append(URLQueryItem(name: "output", value: "json"))
      }
      comps.queryItems = items
      requestURL = comps.url ?? url
    }

    let glossary = SystemPromptsStore.shared.loadWhisperGlossary().trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedDictationHint = (dictationHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    // Whisper-style backends (whisper-1, whisper-asr-webservice) treat `prompt` as raw priming
    // text: a bare term list IS the native conditioning format, and an instruction sentence
    // would pollute the priming. Instructable STT models (gpt-4o-transcribe family, grok-stt)
    // follow instructions in `prompt`, so they get the same explicit Glossary instruction block
    // as the Gemini paths — a bare list is too weak a signal there (see appendGlossaryHint).
    let isWhisperStyle = modelID == "whisper-1" || fieldName == "audio_file"
    // `gpt-transcribe` is a pure ASR model with dedicated context fields, not an instructable
    // LLM: it takes vocabulary through repeated `keywords` fields and ignores instructions in
    // `prompt`. Verified live against the API (2026-08-02, German dictation with the domain
    // terms below):
    //   - a formatting instruction gpt-4o-transcribe honoured ("write numbers as digits") was
    //     silently dropped, so `dictationHint` buys nothing here;
    //   - worse, sending it *hurts* the keyword hints — with the dictation prompt in `prompt`,
    //     "WhisperShortcut" came back as "Whisper Shortcut" in 2 of 3 runs; keywords alone was
    //     correct in 5 of 5. Hence the dictation prompt is deliberately not forwarded.
    //   - the same trait is the reason to prefer it: on silence it returns "", where both
    //     gpt-4o-transcribe and -mini echo the prompt back as a fake transcript (glossary echo).
    // Docs: https://developers.openai.com/api/docs/guides/transcription — "Use these inputs only
    // for context relevant to the audio; don't restate the transcription task."
    // Resolved through the enum rather than a literal so this and `honorsSystemPrompt`, which
    // tells the user the same fact in Settings, cannot drift apart.
    let isContextFieldStyle = modelID == TranscriptionModel.openAIGPTTranscribe.openAIAPIModelID
    let contextKeywords = isContextFieldStyle ? glossaryKeywords() : []
    let combinedPrompt: String? = {
      if isContextFieldStyle { return nil }
      if isWhisperStyle {
        switch (trimmedDictationHint.isEmpty, glossary.isEmpty) {
        case (true, true): return nil
        case (true, false): return glossary
        case (false, true): return trimmedDictationHint
        case (false, false): return trimmedDictationHint + "\n\n" + glossary
        }
      }
      let combined = appendGlossaryHint(to: trimmedDictationHint)
      return combined.isEmpty ? nil : combined
    }()
    let savedLanguageString = UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperLanguage)
    let savedLanguage = WhisperLanguage(rawValue: savedLanguageString ?? WhisperLanguage.auto.rawValue) ?? WhisperLanguage.auto
    let languageCode = savedLanguage.languageCode

    let promptLogValue = isContextFieldStyle
      ? "n/a (context fields: \(contextKeywords.count) keyword(s))"
      : (combinedPrompt == nil
        ? "none"
        : "\(combinedPrompt!.count) chars\(trimmedDictationHint.isEmpty ? "" : " (dictation+glossary)")")
    DebugLogger.log("\(logPrefix): POST \(loggableURL(requestURL)) (field: \(fieldName), model: \(modelID ?? "-"), language: \(languageCode ?? "auto"), prompt: \(promptLogValue))")

    let boundary = "Boundary-\(UUID().uuidString)"
    var body = Data()

    func appendField(_ name: String, _ value: String) {
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }

    if fieldName == "file" {
      if let modelID = modelID {
        appendField("model", modelID)
      }
      if let language = languageCode {
        appendField("language", language)
      }
      // `keywords` is a repeated field — one part per term, not a comma-joined string.
      for keyword in contextKeywords {
        appendField("keywords", keyword)
      }
      if let prompt = combinedPrompt {
        appendField("prompt", prompt)
      }
    }
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"audio.\(fileExtension)\"\r\nContent-Type: \(mimeType)\r\n\r\n"
        .data(using: .utf8)!)
    body.append(audioData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    var request = URLRequest(url: requestURL)
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    // Idle timeout: 60s, not the 300s resourceTimeout this used to copy. Setting
    // URLRequest.timeoutInterval to 300 overrode the session's 60s request timer
    // and, combined with HTTP/2 keep-alive, let GPT-Transcribe sit in
    // `transcribing` for minutes (I2). The Task deadline below is the real
    // backstop — URLSession timers do not reliably fire on this path.
    request.timeoutInterval = NetworkDeadline.transcriptionRequestTimeout
    for header in extraHeaders {
      if let k = header["key"], let v = header["value"], !k.isEmpty {
        request.setValue(v, forHTTPHeaderField: k)
      }
    }
    if let token = bearerToken {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = body

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await NetworkDeadline.data(
        for: request,
        session: session,
        timeout: NetworkDeadline.transcriptionRequestTimeout)
    } catch TranscriptionError.requestTimeout {
      DebugLogger.logError(
        "\(logPrefix): stalled round-trip aborted after \(Int(NetworkDeadline.transcriptionRequestTimeout))s (NetworkDeadline)")
      ContextLogger.shared.logSignal(
        .requestTimedOut, mode: "transcription",
        detail: [
          "phase": "transcribing",
          "timeoutSeconds": "\(Int(NetworkDeadline.transcriptionRequestTimeout))",
          "logPrefix": logPrefix
        ])
      throw TranscriptionError.requestTimeout
    }
    guard let httpResponse = response as? HTTPURLResponse else {
      throw TranscriptionError.networkError("Invalid response")
    }

    DebugLogger.log("\(logPrefix): HTTP \(httpResponse.statusCode)")

    switch httpResponse.statusCode {
    case 200: break
    case 401: throw TranscriptionError.invalidAPIKey
    case 404: throw TranscriptionError.serverError(404)
    case 422: throw TranscriptionError.serverError(422)
    case 429:
      // OpenAI reports "no credit on the API account" as a 429 with code insufficient_quota.
      // Surface that as a billing problem, not a rate limit — the fix is topping up, not waiting.
      if let bodyString = String(data: data, encoding: .utf8), bodyString.contains("insufficient_quota") {
        throw TranscriptionError.billingRequired()
      }
      throw TranscriptionError.rateLimited(retryAfter: nil)
    default:
      let bodyString = String(data: data, encoding: .utf8) ?? ""
      DebugLogger.logError("\(logPrefix): HTTP \(httpResponse.statusCode): \(bodyString.prefix(200))")
      throw TranscriptionError.serverError(httpResponse.statusCode)
    }

    struct WhisperResponse: Decodable { let text: String }
    if let parsed = try? JSONDecoder().decode(WhisperResponse.self, from: data) {
      let result = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if result.isEmpty {
        DebugLogger.log("\(logPrefix): empty transcription (no speech detected)")
        throw TranscriptionError.noSpeechDetected
      }
      DebugLogger.logSuccess("\(logPrefix): \(result.count) chars")
      return result
    }
    if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
      DebugLogger.logSuccess("\(logPrefix): \(text.count) chars (plain text)")
      return text
    }
    throw TranscriptionError.noSpeechDetected
  }

  /// Shared session used for OpenAI-compatible multipart transcription and the
  /// OpenAI Dictate Prompt path. Reuses the same connection pool as the chat
  /// providers (`LLMHTTPSession.shared`). Transcription POSTs do not rely on
  /// those 60s/300s timers — see `NetworkDeadline` — because they do not fire
  /// reliably on reused HTTP/2 connections.
  private func makeTranscriptionURLSession() -> URLSession {
    LLMHTTPSession.shared
  }

  /// POSTs `request` and retries once on HTTP 429 with exponential backoff. Returns the
  /// final response (data + HTTPURLResponse) without interpreting the status code —
  /// callers map non-2xx codes themselves. Mirrors the retry shape Gemini gets for free
  /// via `GeminiAPIClient.performRequest(withRetry: true)`.
  private static func performWithRetryOn429(
    request: URLRequest,
    session: URLSession,
    logPrefix: String
  ) async throws -> (Data, HTTPURLResponse) {
    var lastResponse: (Data, HTTPURLResponse)?
    for attempt in 1...Constants.maxRetryAttempts {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw TranscriptionError.networkError("Invalid response from server")
      }
      lastResponse = (data, http)
      if http.statusCode == 429, attempt < Constants.maxRetryAttempts {
        // A spend-cap 429 never clears on its own, so retrying only delays the billing error the
        // user has to act on. This rule lived in the three other retry loops and was missing here.
        let body = String(data: data, encoding: .utf8) ?? ""
        if RetryBackoff.isPermanentRateLimit(responseBody: body) {
          DebugLogger.logWarning("\(logPrefix): HTTP 429 is a quota/billing block — not retrying")
          return (data, http)
        }
        let delay = RetryBackoff.delay(
          attempt: attempt, retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init),
          base: Constants.retryDelaySeconds, exponential: true)
        DebugLogger.logWarning("\(logPrefix): HTTP 429 (attempt \(attempt)/\(Constants.maxRetryAttempts)), retrying in \(String(format: "%.1f", delay))s")
        await RetryBackoff.sleep(delay)
        continue
      }
      return (data, http)
    }
    // Unreachable when `maxRetryAttempts >= 1` — the loop always returns or continues.
    if let lastResponse { return lastResponse }
    throw TranscriptionError.networkError("Exhausted retry attempts without a response")
  }

  private func loggableURL(_ url: URL) -> String {
    guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.path
    }
    comps.query = nil
    comps.fragment = nil
    return comps.url?.absoluteString ?? url.path
  }

  private func mimeTypeForAudioExtension(_ ext: String) -> String {
    switch ext {
    case "mp3": return "audio/mpeg"
    case "m4a": return "audio/mp4"
    case "wav": return "audio/wav"
    case "flac": return "audio/flac"
    case "ogg": return "audio/ogg"
    case "webm": return "audio/webm"
    case "aiff", "aif": return "audio/aiff"
    case "aac": return "audio/aac"
    default: return "audio/mpeg"
    }
  }

  // MARK: - Gemini API Helpers (delegated to GeminiAPIClient)

  // MARK: - Gemini Transcription
  private func transcribeWithGemini(audioURL: URL, model: TranscriptionModel, promptOverride: String? = nil, reportsProgress: Bool = true) async throws -> String {
    let apiStartTime = CFAbsoluteTimeGetCurrent()

    guard let credential = await credentialProvider.getCredential() else {
      DebugLogger.log("GEMINI-TRANSCRIPTION: ERROR - No Gemini credential (set API key in Settings)")
      throw TranscriptionError.noGoogleAPIKey
    }

    switch credential {
    case .apiKey(let key):
      DebugLogger.log("GEMINI-TRANSCRIPTION: Using API key (prefix: \(key.prefix(8))..., length: \(key.count) chars)")
    case .bearer:
      DebugLogger.log("GEMINI-TRANSCRIPTION: Using Proxy (Bearer)")
    }

    // Only validate format, not size - Gemini handles large files via:
    // 1. Chunking for long audio (>45s)
    // 2. Files API for large files (>20MB)
    try validateAudioFileFormat(at: audioURL)

    let audioSize = getAudioFileSize(at: audioURL)
    DebugLogger.log("GEMINI-TRANSCRIPTION: Starting transcription, file size: \(audioSize) bytes")

    // Check audio duration for chunking decision
    let audioDuration = try await getAudioDuration(audioURL)
    DebugLogger.log("GEMINI-TRANSCRIPTION: Audio duration: \(String(format: "%.1f", audioDuration))s")

    let result: String

    // Use chunking for long audio (>45s by default)
    if audioDuration > AppConstants.chunkingThresholdSeconds {
      DebugLogger.log("GEMINI-TRANSCRIPTION: Using chunked transcription (duration > \(AppConstants.chunkingThresholdSeconds)s)")
      result = try await transcribeWithChunking(audioURL: audioURL, audioDuration: audioDuration, credential: credential, model: model, promptOverride: promptOverride, reportsProgress: reportsProgress)
    }
    // For files >20MB, use Files API (resumable upload); inline base64 otherwise.
    else if audioSize > AppConstants.maxFileSizeBytes {
      result = try await transcribeWithGeminiFilesAPI(audioURL: audioURL, credential: credential, model: model, promptOverride: promptOverride, audioDuration: audioDuration)
    } else {
      result = try await transcribeWithGeminiInline(audioURL: audioURL, credential: credential, model: model, promptOverride: promptOverride, audioDuration: audioDuration)
    }

    let apiElapsedTime = CFAbsoluteTimeGetCurrent() - apiStartTime
    DebugLogger.logSpeech("SPEED: [\(model.displayName)] API call completed in \(String(format: "%.3f", apiElapsedTime))s (\(String(format: "%.0f", apiElapsedTime * 1000))ms)")

    return result
  }

  // MARK: - Chunked Transcription
  private func transcribeWithChunking(audioURL: URL, audioDuration: TimeInterval, credential: GeminiCredential, model: TranscriptionModel, promptOverride: String? = nil, reportsProgress: Bool = true) async throws -> String {
    let chunkService = ChunkTranscriptionService(geminiClient: geminiClient)
    chunkService.progressDelegate = reportsProgress ? chunkProgressDelegate : nil

    let prompt = geminiTranscriptionInstruction(promptOverride: promptOverride)

    return try await chunkService.transcribe(
      fileURL: audioURL,
      audioDuration: audioDuration,
      credential: credential,
      model: model,
      prompt: prompt,
      glossaryTerms: glossaryTermsForEchoCheck()
    )
  }

  // MARK: - Audio Duration Helper
  private func getAudioDuration(_ url: URL) async throws -> TimeInterval {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    return CMTimeGetSeconds(duration)
  }
  
  /// - Parameter suppressGlossary: set by the internal retry below. Callers leave it false.
  private func transcribeWithGeminiInline(audioURL: URL, credential: GeminiCredential, model: TranscriptionModel, promptOverride: String? = nil, audioDuration: TimeInterval, suppressGlossary: Bool = false) async throws -> String {
    let inlineStartTime = CFAbsoluteTimeGetCurrent()
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using inline audio (file ≤20MB)")

    // Read audio (as compact AAC when possible) and convert to base64
    let encodeStartTime = CFAbsoluteTimeGetCurrent()
    let audioData: Data
    let mimeType: String
    if let aacData = AudioTranscoder.aacData(for: audioURL) {
      audioData = aacData
      mimeType = AudioTranscoder.aacMimeType
    } else {
      audioData = try Data(contentsOf: audioURL)
      mimeType = geminiClient.getMimeType(for: audioURL.pathExtension.lowercased())
    }
    let base64Audio = audioData.base64EncodedString()
    let encodeTime = CFAbsoluteTimeGetCurrent() - encodeStartTime
    DebugLogger.logSpeech("SPEED: Audio encoding took \(String(format: "%.3f", encodeTime))s (\(String(format: "%.0f", encodeTime * 1000))ms)")

    // Build the transcription instruction (dictation prompt or default, plus the Glossary).
    let instruction = geminiTranscriptionInstruction(
      promptOverride: promptOverride, suppressGlossary: suppressGlossary)

    DebugLogger.log("GEMINI-TRANSCRIPTION: Using prompt: \(instruction.prefix(100))...")

    // Create request with dynamic endpoint based on selected model
    let endpoint = model.apiEndpoint
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using model: \(model.displayName) (\(model.rawValue))")
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using endpoint: \(endpoint)")

    let transcriptionRequest = GeminiTranscriptionRequest(
      contents: [
        GeminiTranscriptionRequest.GeminiTranscriptionContent(
          parts: [
            .text(instruction),
            .inline(mimeType: mimeType, data: base64Audio)
          ]
        )
      ],
      generationConfig: model.geminiTranscriptionGenerationConfig
    )

    var request = try geminiClient.createRequest(endpoint: endpoint, credential: credential)
    request.httpBody = try JSONEncoder().encode(transcriptionRequest)

    // Make request with retry logic
    let networkStartTime = CFAbsoluteTimeGetCurrent()
    let geminiResponse = try await geminiClient.performRequest(
      request,
      responseType: GeminiResponse.self,
      mode: "GEMINI-TRANSCRIPTION",
      withRetry: true
    )
    let networkTime = CFAbsoluteTimeGetCurrent() - networkStartTime
    DebugLogger.logSpeech("SPEED: [\(model.displayName)] API network request took \(String(format: "%.3f", networkTime))s (\(String(format: "%.0f", networkTime * 1000))ms)")

    let transcript = geminiClient.extractText(from: geminiResponse)
    // Very short recordings can be imperceptible to Flash-tier models, which then confabulate
    // from the prompt context — gate on chars-per-second plausibility in both directions:
    // impossibly long output (invented paragraphs) and near-empty output that is pure glossary
    // vocabulary (a 6.3 s tail chunk once yielded exactly "sabaki.dance").
    let afterLengthGate = TextProcessingUtility.discardingImplausibleTranscript(
      TextProcessingUtility.normalizeTranscriptionText(transcript),
      audioDurationSeconds: audioDuration, mode: "GEMINI-TRANSCRIPTION")
    let normalizedText = TextProcessingUtility.discardingGlossaryEchoTranscript(
      afterLengthGate,
      audioDurationSeconds: audioDuration,
      glossaryTerms: glossaryTermsForEchoCheck(),
      mode: "GEMINI-TRANSCRIPTION")

    // The glossary-echo gate is right to drop this — 12 characters from 11 s of audio is not
    // speech — but "right" still left the user with nothing to paste. Seven days of real usage
    // showed 34 dictations discarded this way, once nine in a row inside two minutes: the user
    // simply re-recorded by hand until it worked. Do that one retry for them, without the
    // vocabulary block, so the model is not handed back the very words it just confabulated.
    if normalizedText.isEmpty, !afterLengthGate.isEmpty, !suppressGlossary {
      DebugLogger.logWarning(
        "GEMINI-TRANSCRIPTION: Glossary echo discarded — retrying once without the glossary")
      return try await transcribeWithGeminiInline(
        audioURL: audioURL, credential: credential, model: model,
        promptOverride: promptOverride, audioDuration: audioDuration, suppressGlossary: true)
    }
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")

    let inlineElapsedTime = CFAbsoluteTimeGetCurrent() - inlineStartTime
    DebugLogger.logSpeech("SPEED: [\(model.displayName)] inline transcription total: \(String(format: "%.3f", inlineElapsedTime))s (\(String(format: "%.0f", inlineElapsedTime * 1000))ms)")

    return normalizedText
  }

  private func transcribeWithGeminiFilesAPI(audioURL: URL, credential: GeminiCredential, model: TranscriptionModel, promptOverride: String? = nil, audioDuration: TimeInterval) async throws -> String {
    let filesAPIStartTime = CFAbsoluteTimeGetCurrent()
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using Files API (file >20MB)")

    // Step 1: Upload file using resumable upload
    let uploadStartTime = CFAbsoluteTimeGetCurrent()
    let fileURI = try await geminiClient.uploadFile(audioURL: audioURL, credential: credential)
    let uploadTime = CFAbsoluteTimeGetCurrent() - uploadStartTime
    DebugLogger.logSpeech("SPEED: File upload took \(String(format: "%.3f", uploadTime))s (\(String(format: "%.0f", uploadTime * 1000))ms)")

    // Step 2: Use file URI for transcription. Forward the original MIME type so the
    // server doesn't misinterpret non-WAV uploads (e.g. mp3/m4a/flac) as WAV.
    let fileExtension = audioURL.pathExtension.lowercased()
    let mimeType = geminiClient.getMimeType(for: fileExtension)
    let result = try await transcribeWithGeminiFileURI(fileURI: fileURI, mimeType: mimeType, credential: credential, model: model, promptOverride: promptOverride, audioDuration: audioDuration)
    
    let filesAPIElapsedTime = CFAbsoluteTimeGetCurrent() - filesAPIStartTime
    DebugLogger.logSpeech("SPEED: Gemini Files API transcription total time: \(String(format: "%.3f", filesAPIElapsedTime))s (\(String(format: "%.0f", filesAPIElapsedTime * 1000))ms)")
    
    return result
  }
  
  // File upload is now handled by GeminiAPIClient
  
  private func transcribeWithGeminiFileURI(fileURI: String, mimeType: String, credential: GeminiCredential, model: TranscriptionModel, promptOverride: String? = nil, audioDuration: TimeInterval) async throws -> String {
    let fileURIStartTime = CFAbsoluteTimeGetCurrent()

    // Build the transcription instruction (dictation prompt or default, plus the Glossary).
    let instruction = geminiTranscriptionInstruction(promptOverride: promptOverride)

    DebugLogger.log("GEMINI-TRANSCRIPTION: Using prompt: \(instruction.prefix(100))...")

    // Create request with dynamic endpoint based on selected model
    let endpoint = model.apiEndpoint
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using model: \(model.displayName) (\(model.rawValue))")
    DebugLogger.log("GEMINI-TRANSCRIPTION: Using endpoint: \(endpoint)")

    let transcriptionRequest = GeminiTranscriptionRequest(
      contents: [
        GeminiTranscriptionRequest.GeminiTranscriptionContent(
          parts: [
            .text(instruction),
            .file(uri: fileURI, mimeType: mimeType)
          ]
        )
      ],
      generationConfig: model.geminiTranscriptionGenerationConfig
    )

    var request = try geminiClient.createRequest(endpoint: endpoint, credential: credential)
    request.httpBody = try JSONEncoder().encode(transcriptionRequest)

    // Make request with retry logic
    let networkStartTime = CFAbsoluteTimeGetCurrent()
    let geminiResponse = try await geminiClient.performRequest(
      request,
      responseType: GeminiResponse.self,
      mode: "GEMINI-TRANSCRIPTION",
      withRetry: true
    )
    let networkTime = CFAbsoluteTimeGetCurrent() - networkStartTime
    DebugLogger.logSpeech("SPEED: Gemini API network request (FileURI) took \(String(format: "%.3f", networkTime))s (\(String(format: "%.0f", networkTime * 1000))ms)")

    let transcript = geminiClient.extractText(from: geminiResponse)
    let normalizedText = TextProcessingUtility.discardingGlossaryEchoTranscript(
      TextProcessingUtility.discardingImplausibleTranscript(
        TextProcessingUtility.normalizeTranscriptionText(transcript),
        audioDurationSeconds: audioDuration, mode: "GEMINI-TRANSCRIPTION"),
      audioDurationSeconds: audioDuration,
      glossaryTerms: glossaryTermsForEchoCheck(),
      mode: "GEMINI-TRANSCRIPTION")
    try TextProcessingUtility.validateSpeechText(normalizedText, mode: "TRANSCRIPTION-MODE")

    let fileURIElapsedTime = CFAbsoluteTimeGetCurrent() - fileURIStartTime
    DebugLogger.logSpeech("SPEED: Gemini FileURI transcription took \(String(format: "%.3f", fileURIElapsedTime))s (\(String(format: "%.0f", fileURIElapsedTime * 1000))ms)")
    
    return normalizedText
  }
  
  // MIME type, text extraction, and error parsing are now handled by GeminiAPIClient

  // MARK: - Prompt Mode Helpers

  /// Reads the "include screenshot in Dictate Prompt" toggle, falling back to the
  /// default when the user hasn't explicitly set it.
  private func screenshotInPromptModeEnabled() -> Bool {
    if UserDefaults.standard.object(forKey: UserDefaultsKeys.screenshotInPromptMode) != nil {
      return UserDefaults.standard.bool(forKey: UserDefaultsKeys.screenshotInPromptMode)
    }
    return SettingsDefaults.screenshotInPromptMode
  }

  private func getClipboardContext() -> String? {
    guard let clipboardManager = clipboardManager else {
      DebugLogger.log("PROMPT-MODE: Clipboard manager is nil")
      return nil
    }
    guard let clipboardText = clipboardManager.getCleanedClipboardText() else {
      DebugLogger.log("PROMPT-MODE: No clipboard text found")
      return nil
    }

    let trimmedText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      DebugLogger.log("PROMPT-MODE: Clipboard text is empty after trimming")
      return nil
    }
    DebugLogger.log("PROMPT-MODE: Clipboard context found (length: \(trimmedText.count) chars)")
    return trimmedText
  }

  // MARK: - Shared Infrastructure Helpers
  
  private func getAudioFileSize(at url: URL) -> Int64 {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return attributes[.size] as? Int64 ?? 0
    } catch {
      return 0
    }
  }
  
  private func validateAudioFileFormat(at url: URL) throws {
    let fileExtension = url.pathExtension.lowercased()
    // Gemini supports: wav, mp3, aiff, aac, ogg, flac
    let supportedExtensions = ["wav", "mp3", "m4a", "flac", "ogg", "webm", "aiff", "aac"]
    if !supportedExtensions.contains(fileExtension) {
      throw TranscriptionError.fileError("Unsupported audio format: \(fileExtension)")
    }
  }
  
  /// Returns audio duration in seconds, or nil if duration could not be determined.
  /// Used by isAudioLikelyEmpty and by recording safeguard (confirm above duration).
  func getAudioDuration(url: URL) -> TimeInterval? {
    do {
      let audioFile = try AVAudioFile(forReading: url)
      let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
      DebugLogger.logDebug("AUDIO-CHECK: getAudioDuration \(String(format: "%.2f", duration))s at \(url.lastPathComponent)")
      return duration
    } catch {
      DebugLogger.logWarning("AUDIO-CHECK: Could not get audio duration: \(error.localizedDescription)")
      return nil
    }
  }

  func isAudioLikelyEmpty(at url: URL) -> Bool {
    guard let duration = getAudioDuration(url: url) else { return false }
    let isEmpty = duration < 0.5
    if isEmpty {
      DebugLogger.log("AUDIO-CHECK: Audio too short (\(String(format: "%.2f", duration))s < 0.5s), treating as empty")
    }
    return isEmpty
  }

  // Status code error parsing is now handled by GeminiAPIClient
}


