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
  /// `smartImprovement` is a `RequestOrigin`, not an interaction mode: timeouts on that
  /// path are logged with it, and an unknown spelling stays `.other`.
  init(logMode: String?) {
    if logMode == RequestOrigin.smartImprovement.rawValue {
      self = .smartImprovement
      return
    }
    switch logMode.flatMap(InteractionMode.init(rawValue:)) {
    case .transcription: self = .dictation
    case .prompt: self = .prompt
    case .chat: self = .chat
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
  /// Retired with the five-step tour, like `onboardingPrivacy`.
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
    // Same milestone as the old API-key step, so the setup funnel stays comparable across versions.
    case .dictationSetup: self = .onboardingAPIKeys
    case .permissions: self = .onboardingPermissions
    case .tryIt: self = .onboardingTryIt
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

/// Which heading a `TelemetryFeature` sits under. The UI owns display names; this is only the group.
enum TelemetryFeatureGroup: String, CaseIterable {
  case core
  case dictatePrompt
  case dictation
  case readAloud
  case providers
  case chatCommands
  case chatContent
  case chatTools
  case meetings
  case aiApps
  case smartImprovement
  case support
}

/// One countable feature. Raw values are the keys in the local store and in a ping's `features` map.
/// A call site can only pass a case, so user text cannot become a key.
enum TelemetryFeature: String, CaseIterable, Codable {
  /// One finished dictation.
  case dictation
  /// One finished Dictate Prompt.
  case dictatePrompt
  /// One finished chat turn.
  case chat
  /// One Read Aloud start.
  case readAloud
  /// One live meeting start.
  case meeting

  /// Dictate Prompt ran on selected text.
  case dictatePromptWithSelection
  /// Dictate Prompt ran with a screenshot.
  case dictatePromptWithScreenshot
  /// A Dictate Prompt quick prompt was used.
  case dictatePromptQuickPrompt
  /// A Dictate Prompt instruction was typed.
  case dictatePromptTypedInstruction
  /// A Dictate Prompt lookup ran.
  case dictatePromptLookup
  /// Writing Style was applied to a Dictate Prompt.
  case writingStyleApplied

  /// The selection was added to the glossary.
  case glossaryAddSelection
  /// The last transcription was copied.
  case copyLastTranscription
  /// A recent transcription was copied.
  case recentTranscriptionCopied
  /// Offline Mode was switched on.
  case offlineMode
  /// A screenshot was taken from the menu.
  case screenshotMenu

  /// Read Aloud rewrote the text before speaking.
  case readAloudSmartRewrite

  /// A request was sent to the user's own server.
  case ownServer
  /// A request was sent through OpenRouter.
  case openRouter
  /// A request used the user's ChatGPT plan.
  case chatGPTPlan

  /// The /new command was used.
  case chatCommandNew
  /// The screenshot command was used.
  case chatCommandScreenshot
  /// The attach command was used.
  case chatCommandAttach
  /// The folder command was used.
  case chatCommandFolder
  /// The workspace command was used.
  case chatCommandWorkspace
  /// The chat model was switched.
  case chatCommandModelSwitch
  /// The /think command was used.
  case chatCommandThink
  /// The /x command was used.
  case chatCommandX
  /// Settings were opened from chat.
  case chatCommandSettings
  /// A chat was pinned.
  case chatCommandPin
  /// The meeting command was used.
  case chatCommandMeeting
  /// The copy command was used.
  case chatCommandCopy
  /// The feedback command was used.
  case chatCommandFeedback
  /// A user-defined chat command was used.
  case chatUserCommand

  /// An image was attached in chat.
  case chatImageAttachment
  /// Chat used web search.
  case chatWebSearch
  /// Chat included a YouTube video.
  case chatYouTube

  /// A chat turn used a Google tool.
  case chatToolGoogle
  /// A chat turn used a Trello tool.
  case chatToolTrello
  /// A chat turn used a mail tool.
  case chatToolMail
  /// A chat turn read a folder.
  case chatToolFolderRead
  /// A chat turn wrote a folder.
  case chatToolFolderWrite
  /// A chat turn generated an image.
  case chatToolImageGeneration
  /// A chat turn used memory.
  case chatToolMemory
  /// A chat turn used a meeting tool.
  case chatToolMeeting

  /// Live notes were taken during a meeting.
  case meetingLiveNotes
  /// A meeting summary was written.
  case meetingSummary
  /// Meeting transcription was retried.
  case meetingRetryTranscription

  /// An AI app read data through MCP.
  case mcpRead
  /// An AI app changed data through MCP.
  case mcpChange

  /// A Smart Improvement run finished.
  case smartImprovementRun
  /// A Smart Improvement suggestion was accepted.
  case smartImprovementAccepted

  /// Feedback was sent.
  case sendFeedback
  /// A problem was reported for the last dictation.
  case reportProblemLastDictation
  /// A usage report was shared.
  case shareUsageReport
  /// The welcome tour was opened again.
  case welcomeTourReopened
  /// Check for Updates was used.
  case checkForUpdatesManual

  private static let folderReadTools: Set<String> = [
    "list_workspace_folders", "list_directory", "read_text_file", "search_files",
  ]
  private static let folderWriteTools: Set<String> = [
    "write_text_file", "append_to_file", "edit_text_file",
  ]

  /// The feature a chat tool belongs to, or nil for tools that are not one of the counted groups.
  /// Names are the ones declared in `ChatTools` / `ChatToolSteps`. `gmail_*` is mail (the Google
  /// account's inbox); `google_*` is the rest of the Google account tools.
  init?(chatToolName name: String) {
    if name.hasPrefix("google_") {
      self = .chatToolGoogle
    } else if name.hasPrefix("trello_") {
      self = .chatToolTrello
    } else if name.hasPrefix("gmail_") || name.hasPrefix("mail_") || name == "connect_mail_account" {
      self = .chatToolMail
    } else if Self.folderReadTools.contains(name) {
      self = .chatToolFolderRead
    } else if Self.folderWriteTools.contains(name) {
      self = .chatToolFolderWrite
    } else if name == "generate_image" {
      self = .chatToolImageGeneration
    } else if name == "remember_about_user" || name == "forget_about_user" {
      self = .chatToolMemory
    } else if name == "refine_meeting_summary" || name == "correct_transcript_term" || name.contains("meeting") {
      self = .chatToolMeeting
    } else {
      return nil
    }
  }

  var group: TelemetryFeatureGroup {
    switch self {
    case .dictation, .dictatePrompt, .chat, .readAloud, .meeting:
      return .core
    case .dictatePromptWithSelection, .dictatePromptWithScreenshot, .dictatePromptQuickPrompt,
      .dictatePromptTypedInstruction, .dictatePromptLookup, .writingStyleApplied:
      return .dictatePrompt
    case .glossaryAddSelection, .copyLastTranscription, .recentTranscriptionCopied, .offlineMode,
      .screenshotMenu:
      return .dictation
    case .readAloudSmartRewrite:
      return .readAloud
    case .ownServer, .openRouter, .chatGPTPlan:
      return .providers
    case .chatCommandNew, .chatCommandScreenshot, .chatCommandAttach, .chatCommandFolder,
      .chatCommandWorkspace, .chatCommandModelSwitch, .chatCommandThink, .chatCommandX,
      .chatCommandSettings, .chatCommandPin, .chatCommandMeeting, .chatCommandCopy,
      .chatCommandFeedback, .chatUserCommand:
      return .chatCommands
    case .chatImageAttachment, .chatWebSearch, .chatYouTube:
      return .chatContent
    case .chatToolGoogle, .chatToolTrello, .chatToolMail, .chatToolFolderRead, .chatToolFolderWrite,
      .chatToolImageGeneration, .chatToolMemory, .chatToolMeeting:
      return .chatTools
    case .meetingLiveNotes, .meetingSummary, .meetingRetryTranscription:
      return .meetings
    case .mcpRead, .mcpChange:
      return .aiApps
    case .smartImprovementRun, .smartImprovementAccepted:
      return .smartImprovement
    case .sendFeedback, .reportProblemLastDictation, .shareUsageReport, .welcomeTourReopened,
      .checkForUpdatesManual:
      return .support
    }
  }
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
  /// `TelemetryFeature` raw value → count. Omitted when the day had none.
  var features: [String: Int]?
}

/// One calendar day of counts, persisted until it is sent.
struct TelemetryDay: Codable, Equatable {
  var counts: [String: Int] = [:]
  var models: [String: [String: Int]] = [:]
  var errors: [String: Int] = [:]
  /// `TelemetryFeature` raw value → count for this day.
  var features: [String: Int] = [:]

  var isEmpty: Bool { counts.isEmpty && models.isEmpty && errors.isEmpty && features.isEmpty }

  private enum CodingKeys: String, CodingKey {
    case counts, models, errors, features
  }

  init() {}

  /// Older builds persisted a day with no `features` key. A missing key is an empty map, not an error.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    counts = try container.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
    models = try container.decodeIfPresent([String: [String: Int]].self, forKey: .models) ?? [:]
    errors = try container.decodeIfPresent([String: Int].self, forKey: .errors) ?? [:]
    features = try container.decodeIfPresent([String: Int].self, forKey: .features) ?? [:]
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(counts, forKey: .counts)
    try container.encode(models, forKey: .models)
    try container.encode(errors, forKey: .errors)
    try container.encode(features, forKey: .features)
  }

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
