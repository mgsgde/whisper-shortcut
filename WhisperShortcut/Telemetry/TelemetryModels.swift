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

  /// Maps `InteractionLogEntry.mode` / `SignalLogEntry.mode` strings onto an area.
  init(logMode: String?) {
    switch logMode {
    case "transcription": self = .dictation
    case "prompt": self = .prompt
    case "geminiChat": self = .chat
    case "smartImprovement": self = .smartImprovement
    default: self = .other
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
  case promptNoSelection
  case requestTimedOut
  case noSpeechDetected
  case noInputSignal

  init(signal: OutcomeSignal) {
    switch signal {
    case .pasted: self = .pasted
    case .dictationRestart: self = .dictationRestart
    case .cancelledWhileProcessing: self = .cancelledWhileProcessing
    case .chatStopped: self = .chatStopped
    case .chatRetry: self = .chatRetry
    case .chatAbandoned: self = .chatAbandoned
    case .promptRetry: self = .promptRetry
    case .promptNoSelection: self = .promptNoSelection
    case .requestTimedOut: self = .requestTimedOut
    case .noSpeechDetected: self = .noSpeechDetected
    case .noInputSignal: self = .noInputSignal
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
    case .serverError, .serviceUnavailable: self = .serverError
    case .networkError: self = .network
    case .requestTimeout, .resourceTimeout, .localProcessingTimeout: self = .timeout
    case .fileError, .fileTooLarge, .emptyFile: self = .file
    case .noSpeechDetected, .textTooShort: self = .noSpeech
    case .noSelectedText: self = .noSelection
    case .modelNotAvailable: self = .offlineModelMissing
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
  case onboardingPrivacy = "onboarding.step.privacy"
  case onboardingAPIKeys = "onboarding.step.apiKeys"
  case onboardingPermissions = "onboarding.step.permissions"
  case onboardingTryIt = "onboarding.step.tryIt"
  case onboardingAutoPaste = "onboarding.step.autoPaste"
  case onboardingSmartImprovement = "onboarding.step.smartImprovement"
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
    case .privacy: self = .onboardingPrivacy
    case .apiKeys: self = .onboardingAPIKeys
    case .permissions: self = .onboardingPermissions
    case .tryIt: self = .onboardingTryIt
    case .autoPaste: self = .onboardingAutoPaste
    case .smartImprovement: self = .onboardingSmartImprovement
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
struct TelemetrySetup: Codable, Equatable {
  var providers: [TelemetryProvider]
  var offlineWhisperModel: Bool
  var smartImprovement: Bool
  var autoPaste: Bool
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
