import Foundation

// The vocabulary of opt-in usage statistics (plans/active/opt-in-telemetry.md).
//
// Every key a ping can carry is built from the closed enums in this file — never from a string a
// call site passes in. That is what makes "never your words" structural rather than a promise: no
// type here can hold user text. `server/telemetry/schema.json` lists the same sets, the server
// drops anything outside them, and `TelemetryTests` fails if the two drift apart.

/// Which part of the app a count belongs to.
enum TelemetryArea: String, CaseIterable, Codable {
  case dictation
  case prompt
  case chat
  case readAloud
  case meeting
  case smartImprovement
  case other
  case mcp
  case screenshot
  case copyLastTranscription
  case glossaryAdd
  case quickPrompt
  case writingStyle
  case googleTool
  case trelloTool
  case mailTool
  case youtube

  /// Maps `InteractionLogEntry.mode` / `SignalLogEntry.mode` strings onto an area.
  /// `smartImprovement` was a `RequestOrigin`, not an interaction mode: timeouts on that
  /// background path were logged with it. The feature is gone (2026-11-02), but a ping queued by
  /// an older build may still carry the spelling, and the area stays in the server schema. An
  /// unknown spelling stays `.other`.
  init(logMode: String?) {
    if logMode == "smartImprovement" {
      self = .smartImprovement
      return
    }
    switch logMode.flatMap(InteractionMode.init(rawValue:)) {
    case .transcription: self = .dictation
    case .prompt: self = .prompt
    case .chat: self = .chat
    case .readAloud: self = .readAloud
    case nil: self = .other
    }
  }
}

/// What happened, per area. `OutcomeSignal` raw values are included verbatim so every existing
/// and future signal is counted without a second list — adding a signal case without adding it
/// here fails to compile (see `init(signal:)`).
enum TelemetryCountName: String, CaseIterable, Codable {
  case started
  case completed
  case failed
  case pasted
  case dictationRestart
  case cancelledWhileProcessing
  case chatStopped
  case chatRetry
  case chatAbandoned
  case promptRetry
  case promptFollowUp
  case promptNoSelection
  case requestTimedOut
  case noSpeechDetected
  case noInputSignal
  case glossaryEchoRemoved
  /// Feature use that is not an `OutcomeSignal`. `init(signal:)` stays exhaustive over signals only.
  case used
  case meetingRead
  case liveTranscriptRead
  case configRead
  case configChange
  case settingsChange
  case problemReport
  case meetingChat
  case viaOpenRouter
  case viaChatGPTPlan
  case viaOwnServer
  case viaLocal

  init(signal: OutcomeSignal) {
    switch signal {
    case .pasted: self = .pasted
    case .dictationRestart: self = .dictationRestart
    case .cancelledWhileProcessing: self = .cancelledWhileProcessing
    case .chatStopped: self = .chatStopped
    case .chatRetry: self = .chatRetry
    case .chatAbandoned: self = .chatAbandoned
    case .promptRetry: self = .promptRetry
    case .promptFollowUp: self = .promptFollowUp
    case .promptNoSelection: self = .promptNoSelection
    case .requestTimedOut: self = .requestTimedOut
    case .noSpeechDetected: self = .noSpeechDetected
    case .noInputSignal: self = .noInputSignal
    case .glossaryEchoRemoved: self = .glossaryEchoRemoved
    // No new count name: the schema on the server is closed. Stopping Read Aloud is a user
    // cancel, which the area (`readAloud`) already tells apart.
    case .readAloudStopped: self = .cancelledWhileProcessing
    }
  }
}

/// Why something failed, as a class — never the error's message, because provider error bodies
/// can echo the request (and so the user's text) back.
enum TelemetryErrorClass: String, CaseIterable, Codable {
  case noAPIKey
  case invalidKey
  case permissionDenied
  case countryNotSupported
  case invalidRequest
  case modelUnavailable
  case rateLimited
  case quotaExceeded
  case billingRequired
  case serverError
  case network
  case timeout
  case file
  case noSpeech
  case noSelection
  case offlineModelMissing
  case other

  init(_ error: Error) {
    if let error = error as? TranscriptionError {
      self.init(error)
    } else if let urlError = error as? URLError {
      self = urlError.code == .timedOut ? .timeout : .network
    } else {
      self = .other
    }
  }

  init(_ error: TranscriptionError) {
    switch error {
    case .noGoogleAPIKey, .voiceRequiresAPIKey: self = .noAPIKey
    case .invalidAPIKey, .incorrectAPIKey: self = .invalidKey
    case .permissionDenied: self = .permissionDenied
    case .countryNotSupported: self = .countryNotSupported
    case .invalidRequest, .promptLeakDetected: self = .invalidRequest
    case .notFound, .modelDeprecated: self = .modelUnavailable
    case .rateLimited, .slowDown: self = .rateLimited
    case .quotaExceeded: self = .quotaExceeded
    case .billingRequired, .subscriptionRequired: self = .billingRequired
    case .serverError, .serviceUnavailable, .emptyModelReply: self = .serverError
    case .networkError: self = .network
    case .requestTimeout, .resourceTimeout, .localProcessingTimeout: self = .timeout
    case .fileError, .fileTooLarge, .emptyFile: self = .file
    case .noSpeechDetected, .textTooShort: self = .noSpeech
    case .noSelectedText: self = .noSelection
    case .modelNotAvailable, .localModelFailed: self = .offlineModelMissing
    }
  }
}

/// Events sent once per install, the moment they happen. Onboarding and first use are exactly the
/// sessions that end with the app quit for good, so a daily batch would never deliver them.
enum TelemetryMilestone: String, CaseIterable, Codable {
  /// Sent once when the user turns sharing on. Every opted-in install sends it exactly once, so it
  /// is the cohort denominator for retention.
  case telemetryEnabled = "telemetry.enabled"
  case onboardingIntro = "onboarding.step.intro"
  /// Retired with the five-step tour (no longer sent). Kept so queues persisted by older builds
  /// still decode and the case list still matches `server/telemetry/schema.json`.
  case onboardingPrivacy = "onboarding.step.privacy"
  case onboardingAPIKeys = "onboarding.step.apiKeys"
  case onboardingPermissions = "onboarding.step.permissions"
  case onboardingTryIt = "onboarding.step.tryIt"
  /// Retired with the five-step tour, like `onboardingPrivacy`.
  case onboardingAutoPaste = "onboarding.step.autoPaste"
  /// Retired with the five-step tour, like `onboardingPrivacy` (the Smart Improvement step).
  case onboardingLearningStep = "onboarding.step.smartImprovement"
  case onboardingDone = "onboarding.step.done"
  case onboardingCompleted = "onboarding.completed"
  case firstDictation = "activation.firstDictation"
  /// Carries `errorClass`. Only sent when no dictation had succeeded before.
  case firstDictationFailed = "activation.firstDictationFailed"
  case firstPrompt = "activation.firstPrompt"
  case firstChat = "activation.firstChat"

  init(step: WelcomeStep) {
    switch step {
    case .intro: self = .onboardingIntro
    // Same milestone as the old API-key step, so the setup funnel stays comparable across versions.
    case .dictationSetup: self = .onboardingAPIKeys
    case .permissions: self = .onboardingPermissions
    case .tryIt: self = .onboardingTryIt
    case .done: self = .onboardingDone
    }
  }

  /// "Dictation only" reports onto the same funnel, so both paths stay in one comparison:
  /// setting up dictation, permissions, the first try, done.
  init(dictationStep: DictationOnlyStep) {
    switch dictationStep {
    case .globeKey, .language, .download: self = .onboardingAPIKeys
    case .permissions: self = .onboardingPermissions
    case .test, .glossary: self = .onboardingTryIt
    case .done: self = .onboardingDone
    }
  }
}

/// Which model list a model count belongs to.
enum TelemetryModelKind: String, CaseIterable, Codable {
  case transcription
  case prompt
  case chat
}

/// Configured providers — whether a key exists, never the key.
enum TelemetryProvider: String, CaseIterable, Codable {
  case gemini
  case openai
  case xai
  case anthropic
  case openrouter
}

// MARK: - Wire format

/// Setup snapshot sent with each daily ping. Booleans and provider names only.
/// Flags added after the first release decode as `false` when an older queued ping omits them.
struct TelemetrySetup: Codable, Equatable {
  var providers: [TelemetryProvider]
  var offlineWhisperModel: Bool
  /// "Save usage data" is on. The wire name is from Smart Improvement (removed 2026-11-02), which
  /// was the only reader of that log at the time; renaming it would break `server/telemetry/schema.json`.
  var smartImprovement: Bool
  var autoPaste: Bool
  var writingStyle: Bool
  var mcpEnabled: Bool
  var googleConnected: Bool
  var trelloConnected: Bool
  var mailConnected: Bool
  var chatGPTPlanConnected: Bool

  init(
    providers: [TelemetryProvider],
    offlineWhisperModel: Bool,
    smartImprovement: Bool,
    autoPaste: Bool,
    writingStyle: Bool = false,
    mcpEnabled: Bool = false,
    googleConnected: Bool = false,
    trelloConnected: Bool = false,
    mailConnected: Bool = false,
    chatGPTPlanConnected: Bool = false
  ) {
    self.providers = providers
    self.offlineWhisperModel = offlineWhisperModel
    self.smartImprovement = smartImprovement
    self.autoPaste = autoPaste
    self.writingStyle = writingStyle
    self.mcpEnabled = mcpEnabled
    self.googleConnected = googleConnected
    self.trelloConnected = trelloConnected
    self.mailConnected = mailConnected
    self.chatGPTPlanConnected = chatGPTPlanConnected
  }

  private enum CodingKeys: String, CodingKey {
    case providers, offlineWhisperModel, smartImprovement, autoPaste
    case writingStyle, mcpEnabled, googleConnected, trelloConnected, mailConnected, chatGPTPlanConnected
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    providers = try c.decode([TelemetryProvider].self, forKey: .providers)
    offlineWhisperModel = try c.decode(Bool.self, forKey: .offlineWhisperModel)
    smartImprovement = try c.decode(Bool.self, forKey: .smartImprovement)
    autoPaste = try c.decode(Bool.self, forKey: .autoPaste)
    writingStyle = try c.decodeIfPresent(Bool.self, forKey: .writingStyle) ?? false
    mcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .mcpEnabled) ?? false
    googleConnected = try c.decodeIfPresent(Bool.self, forKey: .googleConnected) ?? false
    trelloConnected = try c.decodeIfPresent(Bool.self, forKey: .trelloConnected) ?? false
    mailConnected = try c.decodeIfPresent(Bool.self, forKey: .mailConnected) ?? false
    chatGPTPlanConnected = try c.decodeIfPresent(Bool.self, forKey: .chatGPTPlanConnected) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(providers, forKey: .providers)
    try c.encode(offlineWhisperModel, forKey: .offlineWhisperModel)
    try c.encode(smartImprovement, forKey: .smartImprovement)
    try c.encode(autoPaste, forKey: .autoPaste)
    try c.encode(writingStyle, forKey: .writingStyle)
    try c.encode(mcpEnabled, forKey: .mcpEnabled)
    try c.encode(googleConnected, forKey: .googleConnected)
    try c.encode(trelloConnected, forKey: .trelloConnected)
    try c.encode(mailConnected, forKey: .mailConnected)
    try c.encode(chatGPTPlanConnected, forKey: .chatGPTPlanConnected)
  }
}

/// One ping, exactly as it is POSTed. `schemaVersion` 1 is `server/telemetry/schema.json`.
struct TelemetryPing: Codable, Equatable {
  static let schemaVersion = 1

  enum Kind: String, Codable {
    case daily
    case milestone
  }

  var v: Int = TelemetryPing.schemaVersion
  var app: String
  /// `appstore` or `direct`.
  var build: String
  /// macOS major version only.
  var os: String
  var cohortWeek: String
  var dayIndex: Int
  var kind: Kind
  var milestone: TelemetryMilestone?
  var errorClass: TelemetryErrorClass?
  var setup: TelemetrySetup?
  /// `"<area>.<countName>"` → count. Keys are built only by `TelemetryCounts.key`.
  var counts: [String: Int]?
  /// `TelemetryModelKind` raw value → model id → count. Model ids pass `TelemetryModelID`.
  var models: [String: [String: Int]]?
  /// `"<area>.<errorClass>"` → count.
  var errors: [String: Int]?
}

/// One calendar day of counts, persisted until it is sent.
struct TelemetryDay: Codable, Equatable {
  var counts: [String: Int] = [:]
  var models: [String: [String: Int]] = [:]
  var errors: [String: Int] = [:]

  var isEmpty: Bool { counts.isEmpty && models.isEmpty && errors.isEmpty }

  static func key(_ area: TelemetryArea, _ name: TelemetryCountName) -> String {
    "\(area.rawValue).\(name.rawValue)"
  }

  static func key(_ area: TelemetryArea, _ error: TelemetryErrorClass) -> String {
    "\(area.rawValue).\(error.rawValue)"
  }
}

/// Reduces a model string to something safe to send: a model id the app itself ships, or
/// `custom`. Custom-endpoint, OpenRouter and local server model names are typed by the user and
/// may say anything, so they never leave the Mac as written.
enum TelemetryModelID {
  static let custom = "custom"
  static let maxLength = 48

  private static let known: Set<String> = {
    var ids = Set(TranscriptionModel.allCases.map(\.rawValue))
    ids.formUnion(PromptModel.allCases.map(\.rawValue))
    ids.formUnion(TTSModel.allCases.map(\.rawValue))
    return ids
  }()

  static func normalize(_ raw: String?) -> String? {
    guard let raw, !raw.isEmpty else { return nil }
    guard known.contains(raw), isWireSafe(raw) else { return custom }
    return raw
  }

  /// Mirrors `modelIdPattern` in `server/telemetry/schema.json`.
  static func isWireSafe(_ id: String) -> Bool {
    guard (1...maxLength).contains(id.count), let first = id.unicodeScalars.first else { return false }
    let lowerDigits = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
    guard lowerDigits.contains(first) else { return false }
    let allowed = lowerDigits.union(CharacterSet(charactersIn: "._:-"))
    return id.unicodeScalars.allSatisfy { allowed.contains($0) }
  }
}
