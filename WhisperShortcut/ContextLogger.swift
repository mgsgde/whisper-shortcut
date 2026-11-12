import CryptoKit
import Foundation

// MARK: - Interaction Log Entry
/// One JSONL row in `interactions-YYYY-MM-DD.jsonl`.
///
/// Every field after `mode` is optional and has no default on the property, so rows written by
/// older builds still decode (a missing key is nil) and rows written by newer builds decode here
/// too (an unknown key is ignored). Older rows may carry `audioRef`, the name of a dictation WAV
/// kept for Smart Improvement's audio verification; that feature is gone (2026-11-02), the key is
/// no longer written and is simply ignored on read.
struct InteractionLogEntry: Codable {
  let ts: String
  let mode: String
  let model: String?
  let result: String?
  let selectedText: String?
  let userInstruction: String?
  let modelResponse: String?
  let text: String?
  let voice: String?
  /// Stable rawValue of the TranscriptionModel used for this entry (e.g. "whisper-base", "gemini-3.5-flash").
  /// Distinct from `model` (display name), which changes with the UI copy.
  let transcriptionModel: String?
  /// Whether a screenshot was attached to a `prompt`-mode request. Lets analysis distinguish
  /// screenshot-grounded output from fabrication when `selectedText` is empty. Nil for other modes.
  let hadScreenshot: Bool?
  /// End-to-end Dictate Prompt time, from `performPrompt` entry until the turn is logged; for
  /// `transcription`, from job start until the transcript is ready. Nil for other modes.
  let latencyMs: Int?
  /// Dictate Prompt provider: "gemini", "openai", "local", or "mlx". Nil for other modes.
  let provider: String?
  /// Milliseconds spent loading the in-process MLX model for this prompt. 0 when it was already
  /// in memory. Nil for other providers and other modes.
  let loadMs: Int?
  /// Display name of the dictation template this prompt turn applied. Nil for Dictate Prompt
  /// (⌘2) and for every other mode. `mode` stays `prompt` so older readers keep working.
  /// No default on the property: a default would keep synthesized `Codable` from reading it.
  let template: String?
  /// Bundle id of the app that was frontmost when the recording started — where the result was
  /// meant to go (e.g. "com.apple.mail"). Dictation and Dictate Prompt only; nil for chat, for
  /// WhisperShortcut's own windows and for rows from before 2026-11.
  let appBundleId: String?
  /// That app's display name ("Mail"), for a reader that does not know bundle ids.
  let appName: String?
  /// Length of the recorded audio in milliseconds. Dictation and Dictate Prompt only.
  let durationMs: Int?
  /// The dictation language setting at the time (`WhisperLanguage` rawValue: "auto", "de", …).
  /// Dictation and Dictate Prompt only.
  let language: String?
  /// Which version of the mode's system prompt section was in effect: the first 8 hex characters
  /// of the SHA-256 of the section text, or "default" when the section is empty and the built-in
  /// default applied. Lets a reader tell whether a mistake came before or after a prompt change
  /// (`system-prompts-history.jsonl` holds the texts). See `InteractionContext.promptVersion`.
  let promptVersion: String?
  /// Chat rows only: the tools the model called in this turn, in order — name and outcome, never
  /// arguments or results (those can hold mail, files, calendar data). Nil when no tool ran and
  /// on rows from before 2026-11. See `InteractionToolCall`.
  let toolCalls: [InteractionToolCall]?

  init(
    ts: String, mode: String, model: String?, result: String?, selectedText: String?,
    userInstruction: String?, modelResponse: String?, text: String?, voice: String?,
    transcriptionModel: String?, hadScreenshot: Bool?, latencyMs: Int?,
    provider: String?, loadMs: Int?, template: String? = nil,
    toolCalls: [InteractionToolCall]? = nil,
    context: InteractionContext = InteractionContext()
  ) {
    self.ts = ts
    self.mode = mode
    self.model = model
    self.result = result
    self.selectedText = selectedText
    self.userInstruction = userInstruction
    self.modelResponse = modelResponse
    self.text = text
    self.voice = voice
    self.transcriptionModel = transcriptionModel
    self.hadScreenshot = hadScreenshot
    self.latencyMs = latencyMs
    self.provider = provider
    self.loadMs = loadMs
    self.template = template
    self.toolCalls = toolCalls?.isEmpty == false ? toolCalls : nil
    self.appBundleId = context.appBundleId
    self.appName = context.appName
    self.durationMs = context.durationMs
    self.language = context.language
    self.promptVersion = context.promptVersion
  }

  /// Known mode, or nil when an older row used a spelling this build does not list.
  /// `mode` stays a `String` so that unknown spelling still decodes: a strict enum would
  /// drop the whole JSONL line.
  var interactionMode: InteractionMode? { InteractionMode(rawValue: mode) }
}

// MARK: - Chat tool calls

/// One tool call a chat turn made, as the usage log keeps it: which tool, whether it worked, and
/// on failure a short error. Never the arguments or the result: both can carry the user's mail,
/// files or calendar. Lets a model tuning the app see that a turn failed because a tool did.
struct InteractionToolCall: Codable, Equatable {
  let name: String
  let ok: Bool
  /// Only on failure, at most `maxErrorCharacters`.
  let error: String?

  static let maxErrorCharacters = 200

  init(name: String, ok: Bool, error: String? = nil) {
    self.name = name
    self.ok = ok
    let trimmed = error?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.error = ok || trimmed?.isEmpty != false ? nil : String(trimmed!.prefix(Self.maxErrorCharacters))
  }

  /// Log form of a finished call. A call the user denied did not work either; the log says so
  /// rather than leaving the model to guess why the turn changed course.
  init(record: ChatToolCallRecord) {
    switch record.status {
    case .failed: self.init(name: record.name, ok: false, error: record.summary ?? "failed")
    case .denied: self.init(name: record.name, ok: false, error: "denied by the user")
    case .done: self.init(name: record.name, ok: true)
    case nil:
      // Written before the display fields: judge from the stored result, like the transcript does.
      let response = (try? JSONSerialization.jsonObject(with: Data(record.resultJSON.utf8))) as? [String: Any] ?? [:]
      if let error = ChatToolRegistry.resultError(response) {
        self.init(name: record.name, ok: false, error: error)
      } else {
        self.init(name: record.name, ok: true)
      }
    }
  }
}

// MARK: - Interaction Context

/// The circumstances of one interaction that are not its text: where the result was meant to go,
/// how long the recording was, the language setting and which prompt version ran. All optional;
/// a caller that does not know one leaves it nil.
struct InteractionContext: Equatable {
  var appBundleId: String?
  var appName: String?
  var durationMs: Int?
  var language: String?
  var promptVersion: String?

  /// See `InteractionLogEntry.promptVersion`. Pure, so tests can pin it.
  static func promptVersion(of sectionText: String?) -> String {
    let trimmed = sectionText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty else { return "default" }
    let digest = SHA256.hash(data: Data(trimmed.utf8))
    return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
  }

  /// The dictation language setting, as stored.
  static var currentLanguage: String {
    UserDefaults.standard.string(forKey: UserDefaultsKeys.whisperLanguage) ?? WhisperLanguage.auto.rawValue
  }
}

/// The app a recording was meant for, noted when the recording starts (`MenuBarController`).
struct InteractionTargetApp: Equatable {
  let bundleId: String?
  let name: String?
}

// MARK: - Outcome Signal Entry

/// What a user did *after* an interaction, when that action is a verdict on it.
///
/// This is a second, separate stream (`signals-YYYY-MM-DD.jsonl`) rather than a field on
/// `InteractionLogEntry` for two reasons:
///
/// 1. **The verdict arrives later.** A restart or a cancellation happens seconds to minutes after
///    the interaction row was already appended, and JSONL is append-only. Correlation runs through
///    `refTs` instead of a rewrite.
/// 2. **It stays content-free.** Signals carry timings and counts, never transcripts or replies.
///    That is the property that makes the stream safe to aggregate, summarise, and attach to a bug
///    report — do not put user text in `detail`.
struct SignalLogEntry: Codable {
  let ts: String
  /// `OutcomeSignal.rawValue`.
  let kind: String
  /// `ts` of the interaction this judges; nil when no interaction was logged this launch.
  let refTs: String?
  /// `InteractionLogEntry.mode`. Nil when the signal is not tied to one interaction.
  /// An unknown spelling stays in `mode` and `interactionMode` is nil.
  let mode: String?

  var interactionMode: InteractionMode? { mode.flatMap(InteractionMode.init(rawValue:)) }
  /// Milliseconds between `refTs` and `ts`, when both are known.
  let gapMs: Int?
  /// Small kind-specific facts. Strings only, and never user content.
  let detail: [String: String]?
}

/// The behaviours that count as a verdict. Slices 1–2 cover the dictation loop and chat;
/// `modelSwitched` follows in a later slice.
enum OutcomeSignal: String {
  /// The synthetic ⌘V was actually posted — the result was delivered where the user wanted it.
  case pasted
  /// A new dictation started right after one that was never pasted: the transcript was unusable.
  case dictationRestart
  /// The user killed a job before a result existed.
  case cancelledWhileProcessing
  /// A chat response was cancelled mid-stream. Carries `reason`, because the watchdog
  /// (`StallCancellationRegistry`) cancels through the same path and that is not a user verdict —
  /// merging the two would turn every main-thread stall into evidence against the model.
  case chatStopped
  /// The user re-sent the same message: an explicit "that answer was not good enough", and the
  /// strongest negative signal the app can observe.
  case chatRetry
  /// The user left a chat (new chat, switched tab, closed tab) after exactly one turn. The only
  /// chat verdict that fires on ordinary use — without it a good chat week and a quietly abandoned
  /// one produce identical signal streams (gap #12). `detail.reason` is `newChat` / `switched` /
  /// `closed`. Not retracted if the user comes back later.
  case chatAbandoned
  /// A Dictate Prompt ran again over the *same* selection with a different instruction — the
  /// user rephrasing because the first edit missed. The chained case (feeding one result into
  /// the next instruction) is deliberately excluded: that is normal iterative editing, not a
  /// verdict. Without this, retry chains are only visible by eyeballing timestamps.
  case promptRetry
  /// The user selected the previous Dictate Prompt output (word-Jaccard > 0.6, < 5 min) and gave
  /// a new instruction: iterative refinement, the edit trace a tuning model reads style from.
  /// Kept apart from `promptRetry` on purpose (`promptRetry` stays a verdict on a missed edit).
  /// `detail.kind` = `style` / `transform` / `other` (keyword class, never the instruction text),
  /// `detail.secondsSincePrevious`.
  case promptFollowUp
  /// Dictate Prompt ran as a compose turn: nothing was selected for this recording, so the model
  /// wrote new text instead of editing a selection (`detail.reason` = `composeTurn`, `detail.model`).
  /// `detail.reason` = `bareEditCommandBlocked` is the exception: the instruction was only an edit
  /// command, so the turn was refused instead of pasting invented text.
  /// Until 2026-10 this meant the request was refused (`reason` `emptySelection` /
  /// `clipboardUnavailable`); the raw value is kept so the telemetry schema and older logs still
  /// line up.
  case promptNoSelection
  /// A network round-trip (or local processing step) hit the client deadline instead of returning.
  /// Distinct from `cancelledWhileProcessing`: the app gave up, the user did not. `mode` is the
  /// caller's `RequestOrigin` (nil = unattributed shared helper); `detail.phase` / `timeoutSeconds`
  /// / `logPrefix` identify which path stalled.
  case requestTimedOut
  /// No usable speech: either the local silence gate skipped the API, or the API
  /// returned empty. `detail.source` is `localSilenceGate` or `apiEmptyResult`;
  /// `peakDb`, `durationMs`, and `logPrefix` are required so meeting chunks can
  /// be split from dictation (instrumentation gap #8 / ledger I3).
  case noSpeechDetected
  /// The microphone delivered digital zero for a whole recording (peak ≤ −100 dB, ≥ 2 s) — TCC
  /// denial for a stale binary path, a dead or unplugged input device. Never a quiet user, so it
  /// is counted apart from `noSpeechDetected` (queue #11). `detail`: `peakDb`, `durationMs`,
  /// `logPrefix`.
  case noInputSignal
  /// A transcript lost an appended glossary list, or was discarded as a pure glossary echo.
  /// Text-free count: the signal carries no transcript text.
  case glossaryEchoRemoved
  /// The user stopped Read Aloud (✕, Stop, the shortcut again) before it finished. Judges the
  /// `readAloud` row it follows: the read was not wanted, or went wrong.
  case readAloudStopped
}

/// Who asked for the transcription whose result came back empty (instrumentation gap #9 /
/// queue #5). Without it 139 of 182 `noSpeechDetected` records could not say whether a streaming
/// chunk, a whole dictation or a background history transcription heard nothing — and a silent
/// streaming chunk inflated the dictation no-speech rate.
enum NoSpeechOrigin: String, Sendable {
  case streamingChunk
  case dictation
  case meetingSegment
  case liveMeetingChunk
  case promptHistory
}

/// What the caller knew about the audio when it started the request. Carried as a task-local
/// rather than threaded through every provider path: the empty result is detected a dozen
/// frames down (per-provider parsers, `TextProcessingUtility.validateSpeechText`), and only the
/// caller at the top knows which interaction it is and how long the recording was. Child tasks
/// (`Task {}`, task groups) inherit it; `Task.detached` does not, and none of the transcription
/// paths use one.
struct NoSpeechContext: Sendable {
  let origin: NoSpeechOrigin
  let durationMs: Int?
  let peakDb: Float?

  @TaskLocal static var current: NoSpeechContext?

  /// Runs `body` with this context attached, reading the duration from the file when it can.
  static func run<T>(
    _ origin: NoSpeechOrigin, audioURL: URL, peakDb: Float? = nil,
    _ body: () async throws -> T
  ) async rethrows -> T {
    let durationMs = AudioDuration.milliseconds(audioURL)
    let context = NoSpeechContext(origin: origin, durationMs: durationMs, peakDb: peakDb)
    return try await $current.withValue(context) { try await body() }
  }
}

/// Which interaction a network/processing deadline belongs to. Raw values are the `mode` keys the
/// interaction log uses. (`smartImprovement`, the background derivation origin, went with that
/// feature on 2026-11-02; older signal rows may still carry it.)
enum RequestOrigin: String {
  case transcription
  case prompt
  case geminiChat

  var phase: String {
    switch self {
    case .transcription: return "transcribing"
    case .prompt: return "prompting"
    case .geminiChat: return "chatting"
    }
  }
}

// MARK: - System Prompt History Entry
/// Single history file entry for any system prompt section (system-prompts-history.jsonl).
struct UnifiedSystemPromptHistoryEntry: Codable {
  let ts: String
  let section: String
  let source: String
  let previousLength: Int
  let newLength: Int
  let content: String
  let model: String?
  // Rows written before 2026-11-02 may also carry `scorecard` (a Smart Improvement metrics
  // snapshot). It is ignored on read.
}

// MARK: - Context Logger
/// Singleton service for opt-in JSONL interaction logging.
/// All public methods check the logging toggle and return early if disabled.
class ContextLogger {

  static let shared = ContextLogger()

  private let queue = DispatchQueue(label: "com.whisper-shortcut.contextlogger", qos: .utility)
  /// Directory name on disk; kept as "UserContext" for compatibility with existing installs.
  private let contextDirectoryName = "UserContext"
  /// Subdirectory where Smart Improvement kept dictation WAVs for audio verification (up to 200 MB).
  /// Nothing writes it any more; `performRotation` ages out what an older build left behind.
  private let legacyAudioSamplesDirectoryName = "audio-samples"
  /// Retention for streams that hold user text (interactions). See `retentionDays(for:)`.
  static let contentRetentionDays = 90
  /// Retention for the content-free outcome-signal stream. Signals carry timings and counts, never
  /// text, so keeping them twice as long costs no privacy and a few hundred KB, and lets a trend
  /// (paste rate, restart rate) be compared across a release cycle longer than three months.
  static let signalRetentionDays = 180
  /// Maximum number of lines kept in history JSONL files that have no date-based rotation
  /// (system-prompts-history.jsonl, user-context-history.jsonl). Oldest lines are trimmed.
  private let historyFileMaxLines = 500

  /// The most recent logged interaction per mode, so a signal can name what it is judging.
  ///
  /// Deliberately in-memory only: after a relaunch there is nothing to judge, and a signal with
  /// `refTs: nil` is more honest than one pointing at a session the user has long left behind.
  private struct LastInteractionMarker {
    let ts: String
    let date: Date
    /// Set by the `pasted` signal. A result that reached the user's cursor was not a failure,
    /// so a dictation started afterwards is a new thought rather than a retry.
    var pasted: Bool
  }
  private var lastInteractions: [String: LastInteractionMarker] = [:]
  /// `lastInteractions` is written from the serial write queue and read from the main thread.
  private let lastInteractionLock = NSLock()

  /// The selection the previous Dictate Prompt ran against, for `promptRetry` detection. Guarded
  /// by `lastInteractionLock`. Hashed rather than stored: this only ever answers "same text?",
  /// and keeping user content in a long-lived property is needless exposure.
  private var lastPromptSelectionHash: Int?
  private var lastPromptAt: Date?
  /// Hashed words of the previous Dictate Prompt response, for `promptFollowUp`.
  /// Hashes, not words — same exposure rule as `lastPromptSelectionHash`: this only ever
  /// answers "how similar?", and keeping the user's text in a long-lived property is
  /// needless exposure. Guarded by `lastInteractionLock`.
  private var lastPromptResponseWordHashes: Set<Int>?
  /// When the previous Dictate Prompt response was recorded. Separate from `lastPromptAt`, which
  /// the retry detection clears whenever a run has no selection (compose) — that cleared it
  /// before the follow-up that selects the composed text could be compared.
  private var lastPromptResponseAt: Date?
  /// Two runs over the same selection further apart than this are a user returning to a document,
  /// not rephrasing a failed instruction.
  private static let promptRetryWindow: TimeInterval = 120

  /// The app the current Dictate / Dictate Prompt recording is meant for. Set when the recording
  /// starts, read when its interaction is logged. Guarded by `lastInteractionLock`.
  private var targetApp: InteractionTargetApp?

  /// Under the XCTest host this is a per-process temp directory: the test target shares the app's
  /// bundle id, so the real directory would collect the suite's signals and interactions and skew
  /// every usage analysis. Tests that read back what they logged keep working — every reader goes
  /// through `directoryURL`.
  private lazy var contextDirectoryURL: URL = {
    if TestHost.isActive {
      return FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperShortcutTests-\(ProcessInfo.processInfo.processIdentifier)")
        .appendingPathComponent(contextDirectoryName)
    }
    return AppSupportPaths.whisperShortcutApplicationSupportURL()
      .appendingPathComponent(contextDirectoryName)
  }()

  private init() {
    ensureDirectoryExists()
    performRotation()
  }

  // MARK: - Directory Management

  private func ensureDirectoryExists() {
    let fm = FileManager.default
    if !fm.fileExists(atPath: contextDirectoryURL.path) {
      do {
        try fm.createDirectory(at: contextDirectoryURL, withIntermediateDirectories: true)
        DebugLogger.log("USER-CONTEXT: Created context directory at \(contextDirectoryURL.path)")
      } catch {
        DebugLogger.logError("USER-CONTEXT: Failed to create context directory: \(error.logDescription)")
      }
    }
  }

  /// Removes the entire UserContext directory (user-context.md, suggested prompts, interaction logs).
  /// The directory will be recreated on next use. Use for "Reset to Defaults".
  func deleteAllContextData() throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: contextDirectoryURL.path) else { return }
    try fm.removeItem(at: contextDirectoryURL)
    DebugLogger.closeContextErrorLogHandles()
    DebugLogger.log("USER-CONTEXT: Deleted all context data at \(contextDirectoryURL.path)")
  }

  // MARK: - Logging Guard

  /// The stored "Save usage data" preference, plus Offline Mode, which overrides it — see
  /// `ContextLoggingPreference`.
  private var isLoggingEnabled: Bool { ContextLoggingPreference.isEnabled }

  // MARK: - Interaction context

  /// Notes the app a Dictate / Dictate Prompt recording is meant for, at the moment it starts.
  /// `nil` (nothing frontmost, or WhisperShortcut's own window) clears it, so a later row never
  /// names an app from an earlier recording.
  func noteRecordingTarget(_ app: InteractionTargetApp?) {
    lastInteractionLock.lock()
    targetApp = app
    lastInteractionLock.unlock()
  }

  /// Context for a dictation or Dictate Prompt row: the noted target app, the language setting,
  /// the prompt version of `section`, and the recording length when the caller knows it.
  func recordingContext(section: SystemPromptSection, durationMs: Int?) -> InteractionContext {
    lastInteractionLock.lock()
    let app = targetApp
    lastInteractionLock.unlock()
    return InteractionContext(
      appBundleId: app?.bundleId, appName: app?.name, durationMs: durationMs,
      language: InteractionContext.currentLanguage,
      promptVersion: InteractionContext.promptVersion(of: SystemPromptsStore.shared.loadSection(section)))
  }

  // MARK: - Public Logging Methods

  func logTranscription(
    result: String, model: String?, transcriptionModel: String? = nil, durationMs: Int? = nil,
    latencyMs: Int? = nil
  ) {
    // Before the guard: opt-in usage statistics are independent of "Save usage data". Only the
    // model id goes in — never `result`.
    TelemetryService.shared.completed(.dictation, modelKind: .transcription, model: transcriptionModel)
    guard isLoggingEnabled else { return }
    let entry = InteractionLogEntry(
      ts: UserContextLog.nowString(),
      mode: InteractionMode.transcription.rawValue,
      model: model,
      result: result,
      selectedText: nil,
      userInstruction: nil,
      modelResponse: nil,
      text: nil,
      voice: nil,
      transcriptionModel: transcriptionModel,
      hadScreenshot: nil,
      latencyMs: latencyMs,
      provider: nil,
      loadMs: nil,
      context: recordingContext(section: .dictation, durationMs: durationMs)
    )
    writeEntry(entry)
  }

  func logPrompt(
    mode: PromptMode, selectedText: String?, userInstruction: String, modelResponse: String,
    model: String? = nil, hadScreenshot: Bool? = nil, latencyMs: Int? = nil, provider: String? = nil,
    loadMs: Int? = nil, template: String? = nil, durationMs: Int? = nil
  ) {
    TelemetryService.shared.completed(.prompt, modelKind: .prompt, model: model)
    guard isLoggingEnabled else { return }
    let modeString = InteractionMode.prompt.rawValue
    // Response time, not `lastPromptAt`: retry detection resets that on a compose run.
    lastInteractionLock.lock()
    let previousPromptAt = lastPromptResponseAt
    lastInteractionLock.unlock()
    noteSelectionForRetryDetection(selectedText)
    noteFollowUp(selectedText: selectedText, userInstruction: userInstruction, previousPromptAt: previousPromptAt)
    let responseHashes = Set(PromptFollowUp.words(modelResponse).map(\.hashValue))
    lastInteractionLock.lock()
    lastPromptResponseWordHashes = responseHashes
    lastPromptResponseAt = Date()
    lastInteractionLock.unlock()
    let entry = InteractionLogEntry(
      ts: UserContextLog.nowString(),
      mode: modeString,
      model: model,
      result: nil,
      selectedText: selectedText,
      userInstruction: userInstruction,
      modelResponse: modelResponse,
      text: nil,
      voice: nil,
      transcriptionModel: nil,
      hadScreenshot: hadScreenshot,
      latencyMs: latencyMs,
      provider: provider,
      loadMs: loadMs,
      template: template,
      context: recordingContext(section: .promptMode, durationMs: durationMs)
    )
    writeEntry(entry)
  }

  /// Emits `promptRetry` when this Dictate Prompt targets the same selection as the previous one
  /// within `promptRetryWindow`, then records the current selection for the next comparison.
  private func noteSelectionForRetryDetection(_ selectedText: String?) {
    let trimmed = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty else {
      lastInteractionLock.lock()
      lastPromptSelectionHash = nil
      lastPromptAt = nil
      lastInteractionLock.unlock()
      return
    }

    let hash = trimmed.hashValue
    lastInteractionLock.lock()
    let isRetry =
      lastPromptSelectionHash == hash
      && (lastPromptAt.map { Date().timeIntervalSince($0) < Self.promptRetryWindow } ?? false)
    let gap = lastPromptAt.map { Int(Date().timeIntervalSince($0)) }
    lastPromptSelectionHash = hash
    lastPromptAt = Date()
    lastInteractionLock.unlock()

    guard isRetry else { return }
    // Logged before the interaction entry it refers to, so `refTs` still points at the attempt
    // being retried rather than at this one.
    logSignal(.promptRetry, mode: InteractionMode.prompt.rawValue, detail: ["secondsSincePrevious": "\(gap ?? 0)"])
  }

  /// Emits `promptFollowUp` when this selection is the previous Dictate Prompt output.
  /// `previousPromptAt` is the previous response's timestamp, read before this call records the
  /// new one. An empty selection emits nothing and clears nothing — the response hashes
  /// are replaced by the caller either way.
  private func noteFollowUp(selectedText: String?, userInstruction: String, previousPromptAt: Date?) {
    let trimmed = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty, let previousPromptAt else { return }
    let selectionHashes = Set(PromptFollowUp.words(trimmed).map(\.hashValue))
    lastInteractionLock.lock()
    let previousHashes = lastPromptResponseWordHashes
    lastInteractionLock.unlock()
    guard let previousHashes else { return }
    let gap = Date().timeIntervalSince(previousPromptAt)
    guard PromptFollowUp.isFollowUp(
      selectionWords: selectionHashes, previousResponseWords: previousHashes, gap: gap
    ) else { return }
    logSignal(.promptFollowUp, mode: InteractionMode.prompt.rawValue, detail: [
      "kind": PromptFollowUp.classify(instruction: userInstruction).rawValue,
      "secondsSincePrevious": "\(Int(gap))",
    ])
  }

  /// Logs one chat turn (user message + model response) when "Save usage data" is enabled.
  func logChat(
    userMessage: String, modelResponse: String, model: String?, toolCalls: [InteractionToolCall]? = nil
  ) {
    TelemetryService.shared.completed(.chat, modelKind: .chat, model: model)
    guard isLoggingEnabled else { return }
    // Generated-image responses embed the full base64 JPEG inline as a ⟦GEMINI_IMG:…⟧
    // marker (~1 MB+ each). Replace it with a short placeholder before writing so the JSONL
    // log never persists image bytes or balloons to megabytes — mirrors the strip ChatView
    // already does before copy/TTS.
    let sanitizedResponse = GeminiAPIClient.stripImageMarkers(modelResponse, placeholder: "[generated image]")
    let entry = InteractionLogEntry(
      ts: UserContextLog.nowString(),
      mode: InteractionMode.chat.rawValue,
      model: model,
      result: nil,
      selectedText: nil,
      userInstruction: userMessage,
      modelResponse: sanitizedResponse,
      text: nil,
      voice: nil,
      transcriptionModel: nil,
      hadScreenshot: nil,
      latencyMs: nil,
      provider: nil,
      loadMs: nil,
      toolCalls: toolCalls,
      // No target app (the user typed in WhisperShortcut's own window) and no recording.
      context: InteractionContext(
        promptVersion: InteractionContext.promptVersion(of: SystemPromptsStore.shared.loadSection(.chat)))
    )
    writeEntry(entry)
  }

  /// Longest Read Aloud text kept in a row. Longer texts are cut with an ellipsis, the way the
  /// other texts in the log are when they are read back.
  static let readAloudTextCap = 2_000

  /// Logs one Read Aloud request (not one per chunk) when "Save usage data" is enabled: the text
  /// that was read, the voice model and voice, and the app that was frontmost. A later
  /// `readAloudStopped` signal names this row through `refTs`.
  func logReadAloud(text: String, model: String?, voice: String?, app: InteractionTargetApp?) {
    guard isLoggingEnabled else { return }
    let capped = text.count > Self.readAloudTextCap ? String(text.prefix(Self.readAloudTextCap)) + "…" : text
    let entry = InteractionLogEntry(
      ts: UserContextLog.nowString(),
      mode: InteractionMode.readAloud.rawValue,
      model: model,
      result: nil,
      selectedText: nil,
      userInstruction: nil,
      modelResponse: nil,
      text: capped,
      voice: voice,
      transcriptionModel: nil,
      hadScreenshot: nil,
      latencyMs: nil,
      provider: nil,
      loadMs: nil,
      context: InteractionContext(appBundleId: app?.bundleId, appName: app?.name))
    writeEntry(entry)
  }

  // MARK: - Outcome Signals

  /// Appends one behavioural verdict to `signals-YYYY-MM-DD.jsonl`.
  ///
  /// `refTs` and `gapMs` are filled in from the last interaction logged in `mode`, so callers only
  /// have to say what the user did. Keep `detail` free of user content — see `SignalLogEntry`.
  func logSignal(_ kind: OutcomeSignal, mode: String?, detail: [String: String]? = nil) {
    // `detail` deliberately stays here: it is free-form and has no path into a telemetry ping.
    TelemetryService.shared.signal(kind, mode: mode)
    guard isLoggingEnabled else { return }

    var refTs: String?
    var gapMs: Int?
    if let mode {
      lastInteractionLock.lock()
      if let marker = lastInteractions[mode] {
        refTs = marker.ts
        gapMs = Int(Date().timeIntervalSince(marker.date) * 1000)
      }
      // A delivered result closes the book on that interaction: nothing that follows should be
      // read as a retry of it.
      if kind == .pasted { lastInteractions[mode]?.pasted = true }
      lastInteractionLock.unlock()
    }

    let entry = SignalLogEntry(
      ts: UserContextLog.nowString(),
      kind: kind.rawValue,
      refTs: refTs,
      mode: mode,
      gapMs: gapMs,
      detail: detail
    )
    writeSignal(entry)
  }

  /// Deadline signal. `origin` is the caller's interaction mode — never inferred here, because
  /// `GeminiAPIClient.performRequest` serves every Gemini mode and a hardcoded `transcription` made
  /// background (since removed) Smart Improvement aborts read as dictation stalls (gap #11 / ledger I15). `nil`
  /// means "unattributed shared helper", which is honest where a wrong mode would not be.
  /// `stage` and `model` are emitted only when supplied, so the local paths keep their extra keys.
  func logRequestTimedOut(
    timeoutSeconds: Int, logPrefix: String, origin: RequestOrigin?, stage: String? = nil, model: String? = nil
  ) {
    var detail: [String: String] = ["phase": origin?.phase ?? "unattributed"]
    if let processingMs = processingElapsedMs() { detail["processingMs"] = "\(processingMs)" }
    if let stage { detail["stage"] = stage }
    detail["timeoutSeconds"] = "\(timeoutSeconds)"
    detail["logPrefix"] = logPrefix
    if let model { detail["model"] = model }
    logSignal(.requestTimedOut, mode: origin?.rawValue, detail: detail)
  }

  /// Gap #8: every `noSpeechDetected` path must hit the outcome-signal stream with the
  /// four fields usage-review needs to grade I3.

  ///
  /// `origin`, and `peakDb`/`durationMs` when the call site cannot know them (the API-empty
  /// paths pass "n/a"), come from `NoSpeechContext.current` — set by whoever started the
  /// request (gap #9 / queue #5). `origin` is "unattributed" only if no caller set a context.
  func logNoSpeechDetected(
    source: String, peakDb: String, durationMs: String, logPrefix: String,
    origin: NoSpeechOrigin? = nil
  ) {
    let context = NoSpeechContext.current
    let resolvedPeak = peakDb != "n/a" ? peakDb : context?.peakDb.map { String(format: "%.1f", $0) } ?? peakDb
    let resolvedDuration = durationMs != "n/a" ? durationMs : context?.durationMs.map { "\($0)" } ?? durationMs
    logSignal(
      .noSpeechDetected,
      mode: InteractionMode.transcription.rawValue,
      detail: [
        "source": source,
        "origin": (origin ?? context?.origin)?.rawValue ?? "unattributed",
        "peakDb": resolvedPeak,
        "durationMs": resolvedDuration,
        "logPrefix": logPrefix,
      ])
  }

  func logNoInputSignal(peakDb: String, durationMs: String, logPrefix: String) {
    logSignal(
      .noInputSignal,
      mode: InteractionMode.transcription.rawValue,
      detail: [
        "peakDb": peakDb,
        "durationMs": durationMs,
        "logPrefix": logPrefix,
      ])
  }

  // MARK: - Processing duration (gap #10 / queue #8)

  private var processingStartedAt: Date?

  /// Marks the moment a transcription/prompt job entered processing, so a later cancel or
  /// deadline can say how long processing had run. `gapMs` measures from the previous
  /// *interaction*, which can be hours earlier (baseline: 419 s – 3 h on the cancels it was
  /// meant to explain). Pass nil when processing ends.
  func noteProcessingStart(_ date: Date? = Date()) {
    lastInteractionLock.lock()
    processingStartedAt = date
    lastInteractionLock.unlock()
  }

  /// Milliseconds since `noteProcessingStart`, or nil when nothing is processing.
  func processingElapsedMs() -> Int? {
    lastInteractionLock.lock()
    let start = processingStartedAt
    lastInteractionLock.unlock()
    guard let start else { return nil }
    return Int(Date().timeIntervalSince(start) * 1000)
  }

  /// Emits `dictationRestart` when a dictation begins so soon after an unpasted transcript that the
  /// only plausible reading is "that one was wrong, say it again".
  ///
  /// Call this at the moment recording starts, not when it finishes — the restart *is* the verdict.
  ///
  /// `autoPasteAvailable` is recorded rather than acted on. In the App Store build auto-paste is
  /// compiled out, so `pasted` never fires and every back-to-back dictation would look like a
  /// retry; analysis needs to know which builds it can trust this signal from. Detecting a manual
  /// ⌘V is not an option — `NSPasteboard.changeCount` reveals that something was *written* to the
  /// pasteboard, never that the user pasted from it, and a wrong signal is worse than no signal.
  func noteDictationStart(autoPasteAvailable: Bool) {
    guard isLoggingEnabled else { return }

    lastInteractionLock.lock()
    let marker = lastInteractions[InteractionMode.transcription.rawValue]
    lastInteractionLock.unlock()

    guard let marker, !marker.pasted else { return }
    let gap = Date().timeIntervalSince(marker.date)
    guard gap >= 0, gap <= AppConstants.outcomeSignalRestartWindow else { return }

    logSignal(
      .dictationRestart,
      mode: InteractionMode.transcription.rawValue,
      detail: ["autoPasteAvailable": autoPasteAvailable ? "true" : "false"]
    )
  }

  // MARK: - Data Management

  func performRotation() {
    queue.async { [weak self] in
      guard let self else { return }
      let fm = FileManager.default
      self.pruneLegacyAudioSamples()

      do {
        let contents = try fm.contentsOfDirectory(at: self.contextDirectoryURL, includingPropertiesForKeys: nil)
        for fileURL in contents {
          let filename = fileURL.lastPathComponent

          if let stream = UserContextLog.Stream.allCases.first(where: { filename.hasPrefix($0.rawValue) }),
             let fileDate = UserContextLog.fileDay(in: filename, stream: stream),
             fileDate < Self.retentionCutoff(for: stream) {
            try fm.removeItem(at: fileURL)
            DebugLogger.log("USER-CONTEXT: Rotated old log file: \(filename)")
          } else if filename == "system-prompts-history.jsonl" || filename == "user-context-history.jsonl" {
            // Line-count rotation for history files that have no date in their name
            Self.trimJSONLFile(at: fileURL, maxLines: self.historyFileMaxLines)
          }
        }
      } catch {
        DebugLogger.logError("USER-CONTEXT: Rotation error: \(error.logDescription)")
      }
    }
  }

  /// Days a date-stamped stream is kept: user text for `contentRetentionDays`, content-free
  /// signals for `signalRetentionDays`.
  static func retentionDays(for stream: UserContextLog.Stream) -> Int {
    switch stream {
    case .interactions: return contentRetentionDays
    case .signals: return signalRetentionDays
    }
  }

  private static func retentionCutoff(for stream: UserContextLog.Stream, now: Date = Date()) -> Date {
    Calendar.current.date(byAdding: .day, value: -retentionDays(for: stream), to: now) ?? now
  }

  /// Days a leftover `audio-samples/` WAV is kept: the retention Smart Improvement promised
  /// (`audioSampleRetentionDays`) while it still pruned the pool on each run.
  static let legacyAudioSampleRetentionDays = 30

  /// Ages out `UserContext/audio-samples/`, where Smart Improvement kept copies of dictation audio
  /// (up to 500 WAVs / 200 MB) for its audio verification. Nothing writes it since that feature
  /// was removed (2026-11-02), and nothing pruned it any more either, so recordings would have
  /// stayed for good. Deletes WAVs older than `legacyAudioSampleRetentionDays` (capture time is
  /// in the name, `yyyyMMdd'T'HHmmssSSS-XXXXXX.wav`, UTC), then the folder once it is empty.
  /// Not all at once on purpose: the opt-in offline benchmarks read the same folder, and the
  /// promise users were given was "30 days", not "until the next update". Runs on `queue`.
  private func pruneLegacyAudioSamples(now: Date = Date()) {
    let fm = FileManager.default
    let dir = contextDirectoryURL.appendingPathComponent(legacyAudioSamplesDirectoryName)
    guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
    let formatter = UserContextLog.makeFileNameDateFormatter(dateFormat: "yyyyMMdd'T'HHmmssSSS")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    let cutoff = now.addingTimeInterval(-Double(Self.legacyAudioSampleRetentionDays) * 86_400)
    var deleted = 0
    var remaining = 0
    for url in contents {
      let stamp = url.deletingPathExtension().lastPathComponent.components(separatedBy: "-").first ?? ""
      // An unreadable name is kept, as before: never delete what we cannot date.
      if let captured = formatter.date(from: stamp), captured < cutoff, (try? fm.removeItem(at: url)) != nil {
        deleted += 1
      } else {
        remaining += 1
      }
    }
    if remaining == 0 { try? fm.removeItem(at: dir) }
    if deleted > 0 || remaining == 0 {
      DebugLogger.log("USER-CONTEXT: legacy audio-samples pruned=\(deleted) remaining=\(remaining)")
    }
  }

  /// Keeps only the last `maxLines` non-empty lines in a JSONL file, discarding the oldest entries.
  /// Called on the serial queue already; no further synchronisation needed.
  private static func trimJSONLFile(at url: URL, maxLines: Int) {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
    let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard lines.count > maxLines else { return }
    let trimmed = lines.suffix(maxLines).joined(separator: "\n") + "\n"
    do {
      try trimmed.write(to: url, atomically: true, encoding: .utf8)
      DebugLogger.log("USER-CONTEXT: Trimmed \(url.lastPathComponent) to \(maxLines) lines (was \(lines.count))")
    } catch {
      DebugLogger.logError("USER-CONTEXT: Failed to trim \(url.lastPathComponent): \(error.logDescription)")
    }
  }

  // MARK: - File Listing

  /// Runs `work` after interaction-log appends already queued on the write queue.
  /// Dictate Prompt uses this so the quick-action cache rebuilds once the new row is on disk.
  func performAfterInteractionWrites(_ work: @escaping () -> Void) {
    queue.async(execute: work)
  }

  /// Returns URLs of all interaction log files from the last N days, sorted by date ascending.
  func interactionLogFiles(lastDays: Int = 30) -> [URL] {
    UserContextLog.files(stream: .interactions, in: contextDirectoryURL, lastDays: lastDays, now: Date())
  }

  /// Returns URLs of all signal log files from the last N days, sorted by date ascending.
  func signalLogFiles(lastDays: Int = 30) -> [URL] {
    UserContextLog.files(stream: .signals, in: contextDirectoryURL, lastDays: lastDays, now: Date())
  }

  /// Returns the URL of the context directory.
  var directoryURL: URL {
    contextDirectoryURL
  }

  // MARK: - Private Helpers

  private func writeEntry(_ entry: InteractionLogEntry) {
    // Remember what was just logged so a later signal can name the interaction it judges.
    // A fresh entry starts unpasted; `logSignal(.pasted)` is what marks it delivered.
    //
    // Set synchronously, not inside the async block: callers log `pasted` right after the
    // interaction (`runAudioJob` does so after `afterCopy`), and if the marker were still queued
    // behind disk I/O the `pasted` flag could land on nothing — which would turn the user's next
    // dictation into a phantom `dictationRestart`.
    lastInteractionLock.lock()
    lastInteractions[entry.mode] = LastInteractionMarker(ts: entry.ts, date: Date(), pasted: false)
    lastInteractionLock.unlock()

    queue.async { [weak self] in
      guard let self else { return }
      self.append(entry, toDailyFileWithPrefix: "interactions-", logDescription: "interaction (mode: \(entry.mode))")
    }
  }

  private func writeSignal(_ entry: SignalLogEntry) {
    queue.async { [weak self] in
      guard let self else { return }
      self.append(entry, toDailyFileWithPrefix: "signals-", logDescription: "signal (\(entry.kind))")
    }
  }

  /// Appends one JSON line to today's file for a date-stamped stream. Runs on `queue`.
  private func append<T: Encodable>(_ entry: T, toDailyFileWithPrefix prefix: String, logDescription: String) {
    let filename = "\(prefix)\(UserContextLog.fileNameDayString(from: Date())).jsonl"
    let fileURL = contextDirectoryURL.appendingPathComponent(filename)

    do {
      let data = try JSONEncoder().encode(entry)
      try UserContextLog.appendLine(data, to: fileURL)
      DebugLogger.log("USER-CONTEXT: Logged \(logDescription)")
    } catch {
      DebugLogger.logError("USER-CONTEXT: Failed to write log entry: \(error.logDescription)")
    }
  }
}
