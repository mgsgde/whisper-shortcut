import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Opt-in usage statistics (plans/active/opt-in-telemetry.md).
///
/// The first two suites are the reason the file exists: a ping must never carry user text, and
/// nothing may leave the Mac — or be written to it — unless the user turned sharing on. Both are
/// invisible when they break, so they are pinned here.
@Suite("Telemetry", .serialized)
struct TelemetryTests {

  // MARK: - Harness

  final class FakeTransport: TelemetryTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [Data] = []
    var result: TelemetrySendResult = .delivered
    /// Runs inside each send, before it returns — to change state mid-flush.
    var onSend: (() -> Void)?

    var bodies: [Data] {
      lock.lock(); defer { lock.unlock() }
      return _bodies
    }

    var pings: [[String: Any]] {
      bodies.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    var text: String { bodies.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") }

    func send(_ body: Data) async -> TelemetrySendResult {
      lock.lock(); _bodies.append(body); lock.unlock()
      onSend?()
      return result
    }
  }

  final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(days: Int) { now = now.addingTimeInterval(TimeInterval(days) * 86_400) }
  }

  struct Harness {
    let service: TelemetryService
    let transport: FakeTransport
    let clock: Clock
    let defaults: UserDefaults
    let storeURL: URL
    let featureUsage: FeatureUsageStore
    let offline: Box

    final class Box: @unchecked Sendable { var value = false }

    func enable() {
      defaults.set(true, forKey: UserDefaultsKeys.telemetryEnabled)
      service.consentChanged(true)
    }
  }

  static let berlin: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return c
  }()

  static func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 10) -> Date {
    berlin.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
  }

  func makeHarness(
    start: Date = date(2026, 10, 5), existingInstall: Bool = false
  ) -> Harness {
    let suite = "telemetry-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let storeURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("telemetry-tests-\(UUID().uuidString)")
      .appendingPathComponent("telemetry-pending.json")
    let transport = FakeTransport()
    let clock = Clock(start)
    let offline = Harness.Box()
    let featureUsageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("feature-usage-tests-\(UUID().uuidString)")
      .appendingPathComponent("feature-usage.json")
    let featureUsage = FeatureUsageStore(fileURL: featureUsageURL, now: { clock.now })
    let env = TelemetryEnvironment(
      defaults: defaults,
      now: { clock.now },
      calendar: Self.berlin,
      storeURL: storeURL,
      transport: transport,
      offlineMode: { offline.value },
      setup: { TelemetrySetup(providers: [.gemini], offlineWhisperModel: false, smartImprovement: false, autoPaste: false) },
      isExistingInstall: { existingInstall },
      appVersion: "9.99",
      build: "direct",
      osMajor: "26",
      featureUsage: featureUsage,
      autoFlush: false
    )
    let service = TelemetryService(environment: env)
    service.recordFirstLaunchIfNeeded()
    return Harness(
      service: service, transport: transport, clock: clock, defaults: defaults, storeURL: storeURL,
      featureUsage: featureUsage, offline: offline)
  }

  /// A model id the app ships that is also wire-safe.
  static let knownModel: String = TranscriptionModel.allCases.map(\.rawValue)
    .first { TelemetryModelID.isWireSafe($0) }!

  static let sentinel = "SENTINEL-USER-TEXT-7Q1Z"

  /// Drives every recording entry point, feeding the sentinel wherever a caller could.
  func exerciseEverything(_ s: TelemetryService) {
    s.completed(.dictation, modelKind: .transcription, model: Self.knownModel)
    s.completed(.prompt, modelKind: .prompt, model: "my private model \(Self.sentinel)")
    s.completed(.chat, modelKind: .chat, model: Self.sentinel)
    s.failed(.dictation, error: TranscriptionError.networkError(Self.sentinel))
    s.failed(.chat, error: TranscriptionError.fileError(Self.sentinel))
    s.failed(.readAloud, error: NSError(domain: Self.sentinel, code: 1, userInfo: [NSLocalizedDescriptionKey: Self.sentinel]))
    s.signal(.pasted, mode: "transcription")
    s.signal(.chatRetry, mode: "geminiChat")
    s.signal(.noSpeechDetected, mode: Self.sentinel)
    s.started(.readAloud)
    s.started(.meeting)
    s.onboardingStepReached(.dictationSetup)
  }

  // MARK: - No user text, ever

  @Test("A ping never contains user text, whatever the call sites pass")
  func leak() async throws {
    let h = makeHarness()
    h.enable()
    exerciseEverything(h.service)

    let preview = h.service.previewJSON()
    #expect(!preview.isEmpty)
    #expect(!preview.contains(Self.sentinel))

    h.clock.advance(days: 1)
    await h.service.flush()
    #expect(!h.transport.pings.isEmpty)
    #expect(!h.transport.text.contains(Self.sentinel))
    let stored = try String(contentsOf: h.storeURL, encoding: .utf8)
    #expect(!stored.contains(Self.sentinel))

    let daily = try #require(h.transport.pings.first { $0["kind"] as? String == "daily" })
    let models = try #require(daily["models"] as? [String: [String: Int]])
    #expect(models["transcription"] == [Self.knownModel: 1])
    #expect(models["prompt"] == ["custom": 1])
    #expect(models["chat"] == ["custom": 1])
    let errors = try #require(daily["errors"] as? [String: Int])
    #expect(errors == ["dictation.network": 1, "chat.file": 1, "readAloud.other": 1])
    let counts = try #require(daily["counts"] as? [String: Int])
    #expect(counts["other.noSpeechDetected"] == 1)
    #expect(counts["dictation.pasted"] == 1)
  }

  // MARK: - Off means silent

  @Test("Off by default: nothing is sent and nothing is written")
  func offByDefault() async {
    let h = makeHarness()
    exerciseEverything(h.service)
    h.service.milestone(.onboardingCompleted)
    h.clock.advance(days: 2)
    await h.service.flush()
    #expect(h.transport.bodies.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: h.storeURL.path))
    #expect(h.service.previewJSON().isEmpty)
  }

  @Test("Offline Mode and the admin key force sharing off even when the user turned it on")
  func forcedOff() async {
    for force in ["offline", "admin"] {
      let h = makeHarness()
      h.enable()
      if force == "offline" { h.offline.value = true }
      else { h.defaults.set(true, forKey: UserDefaultsKeys.telemetryForceDisabled) }
      let bodiesBefore = h.transport.bodies.count
      exerciseEverything(h.service)
      h.clock.advance(days: 1)
      await h.service.flush()
      #expect(h.transport.bodies.count == bodiesBefore, "\(force)")
      #expect(!h.service.isEnabled, "\(force)")
    }
  }

  @Test("Onboarding steps before consent stay in memory and are sent only after opting in")
  func preConsentBuffer() async {
    let h = makeHarness()
    h.service.onboardingStepReached(.intro)
    h.service.onboardingStepReached(.dictationSetup)
    await h.service.flush()
    #expect(h.transport.bodies.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: h.storeURL.path))

    h.enable()
    await h.service.flush()
    let milestones = h.transport.pings.compactMap { $0["milestone"] as? String }
    #expect(milestones == ["telemetry.enabled", "onboarding.step.intro", "onboarding.step.apiKeys"])
  }

  @Test("Turning sharing off deletes everything queued")
  func turnOffDeletes() async {
    let h = makeHarness()
    h.enable()
    exerciseEverything(h.service)
    #expect(FileManager.default.fileExists(atPath: h.storeURL.path))

    h.defaults.set(false, forKey: UserDefaultsKeys.telemetryEnabled)
    h.service.consentChanged(false)
    #expect(!FileManager.default.fileExists(atPath: h.storeURL.path))
    #expect(h.service.previewJSON().isEmpty)

    // Back on: none of the deleted counts come back, but `telemetry.enabled` — queued the first
    // time and never delivered — is queued again, or the cohort denominator would lose this install.
    h.defaults.set(true, forKey: UserDefaultsKeys.telemetryEnabled)
    h.service.consentChanged(true)
    h.clock.advance(days: 1)
    await h.service.flush()
    #expect(h.transport.pings.compactMap { $0["milestone"] as? String } == ["telemetry.enabled"])
    #expect(!h.transport.pings.contains { $0["kind"] as? String == "daily" })
  }

  @Test("A delivered milestone is not sent again after turning sharing off and on")
  func deliveredMilestoneStaysSent() async {
    let h = makeHarness()
    h.enable()
    await h.service.flush()
    h.defaults.set(false, forKey: UserDefaultsKeys.telemetryEnabled)
    h.service.consentChanged(false)
    h.enable()
    await h.service.flush()
    #expect(h.transport.pings.compactMap { $0["milestone"] as? String } == ["telemetry.enabled"])
  }

  @Test("Opting in from Settings after onboarding does not replay steps walked with the switch off")
  func noReplayAfterOnboarding() async {
    let h = makeHarness()
    h.service.onboardingStepReached(.intro)
    h.service.onboardingStepReached(.dictationSetup)
    h.service.milestone(.onboardingCompleted)
    h.defaults.set(true, forKey: UserDefaultsKeys.hasCompletedOnboarding)
    h.enable()
    await h.service.flush()
    #expect(h.transport.pings.compactMap { $0["milestone"] as? String } == ["telemetry.enabled"])
  }

  @Test("Turning sharing off mid-flush stops the sends that have not gone out yet")
  func turnOffMidFlush() async {
    let h = makeHarness()
    h.enable()
    for day in 0..<3 {
      h.service.count(.dictation, .completed)
      if day < 2 { h.clock.advance(days: 1) }
    }
    h.clock.advance(days: 1)
    h.transport.onSend = {
      h.defaults.set(false, forKey: UserDefaultsKeys.telemetryEnabled)
    }
    await h.service.flush()
    #expect(h.transport.bodies.count == 1, "only the send already in flight")
  }

  // MARK: - Schedule

  @Test("At most one daily ping per calendar day, and never for today")
  func oneDailyPerDay() async {
    let h = makeHarness()
    h.enable()
    await h.service.flush()  // telemetry.enabled
    let afterConsent = h.transport.bodies.count

    h.service.count(.dictation, .pasted)
    h.service.count(.dictation, .pasted)
    await h.service.flush()
    #expect(h.transport.bodies.count == afterConsent, "today is still filling up")

    h.clock.advance(days: 1)
    await h.service.flush()
    await h.service.flush()
    let dailies = h.transport.pings.filter { $0["kind"] as? String == "daily" }
    #expect(dailies.count == 1)
    #expect((dailies.first?["counts"] as? [String: Int]) == ["dictation.pasted": 2])
    #expect(dailies.first?["dayIndex"] as? Int == 0)
  }

  @Test("A failed send is kept and retried; a rejected one is dropped")
  func retryAndReject() async {
    let h = makeHarness()
    h.enable()
    h.service.count(.chat, .completed)
    h.clock.advance(days: 1)
    h.transport.result = .failed
    await h.service.flush()
    let attempts = h.transport.bodies.count
    #expect(attempts >= 1)

    h.transport.result = .rejected(400)
    await h.service.flush()
    #expect(h.transport.bodies.count > attempts)
    let afterReject = h.transport.bodies.count
    await h.service.flush()
    #expect(h.transport.bodies.count == afterReject)
  }

  @Test("Days older than the retention window are dropped unsent")
  func staleDaysDropped() async {
    let h = makeHarness()
    h.enable()
    await h.service.flush()
    h.transport.result = .failed
    h.service.count(.dictation, .completed)
    h.clock.advance(days: TelemetryService.maxPendingDays + 2)
    h.transport.result = .delivered
    let before = h.transport.bodies.count
    await h.service.flush()
    #expect(h.transport.bodies.count == before)
  }

  // MARK: - Cohorts

  @Test("dayIndex and cohortWeek across a DST change and an ISO week-53 year boundary")
  func cohortMath() {
    let dst = makeHarness(start: Self.date(2026, 3, 28, hour: 23))
    #expect(dst.service.dayIndex(of: Self.date(2026, 3, 30, hour: 1)) == 2)

    let yearEnd = makeHarness(start: Self.date(2026, 12, 31))
    #expect(yearEnd.service.cohortWeek() == "2026-W53")
    #expect(yearEnd.service.dayIndex(of: Self.date(2027, 1, 2)) == 2)

    let existing = makeHarness(existingInstall: true)
    #expect(existing.service.cohortWeek() == "pre-telemetry")
  }

  @Test("Activation firsts are sent once, and a first failure only before any success")
  func activation() async {
    let h = makeHarness()
    h.enable()
    h.service.failed(.dictation, error: TranscriptionError.invalidAPIKey)
    h.service.failed(.dictation, error: TranscriptionError.networkError("x"))
    h.service.completed(.dictation, modelKind: .transcription, model: nil)
    h.service.completed(.dictation, modelKind: .transcription, model: nil)
    h.service.failed(.dictation, error: TranscriptionError.invalidAPIKey)
    await h.service.flush()
    let milestones = h.transport.pings.compactMap { ping -> String? in
      guard let m = ping["milestone"] as? String else { return nil }
      return m + ((ping["errorClass"] as? String).map { ":\($0)" } ?? "")
    }
    #expect(milestones == ["telemetry.enabled", "activation.firstDictationFailed:invalidKey", "activation.firstDictation"])
  }

  @Test("A first dictation made before opting in is not reported as a first later")
  func activationBeforeConsent() async {
    let h = makeHarness()
    h.service.completed(.dictation, modelKind: .transcription, model: nil)
    h.enable()
    h.service.completed(.dictation, modelKind: .transcription, model: nil)
    await h.service.flush()
    let milestones = h.transport.pings.compactMap { $0["milestone"] as? String }
    #expect(milestones == ["telemetry.enabled"])
  }

  // MARK: - Wire format

  @Test("Oversized pings shed models, then errors, and stay under the server limit")
  func sizeCap() throws {
    var counts: [String: Int] = [:]
    var errors: [String: Int] = [:]
    for area in TelemetryArea.allCases {
      for name in TelemetryCountName.allCases { counts[TelemetryDay.key(area, name)] = 99_999 }
      for e in TelemetryErrorClass.allCases { errors[TelemetryDay.key(area, e)] = 99_999 }
    }
    let models = Dictionary(uniqueKeysWithValues: TelemetryModelKind.allCases.map { kind in
      (kind.rawValue, Dictionary(uniqueKeysWithValues: (0..<20).map { ("model-\($0)-\(String(repeating: "x", count: 30))", 99_999) }))
    })
    let ping = TelemetryPing(
      app: "9.99", build: "direct", os: "26", cohortWeek: "2026-W40", dayIndex: 3, kind: .daily,
      setup: TelemetrySetup(providers: TelemetryProvider.allCases, offlineWhisperModel: true, smartImprovement: true, autoPaste: true),
      counts: counts, models: models, errors: errors)
    let data = try #require(TelemetryService.encodeWithinLimit(ping))
    #expect(data.count <= TelemetryService.maxPingBytes)

    var realistic = ping
    realistic.counts = Dictionary(uniqueKeysWithValues: TelemetryCountName.allCases.map { (TelemetryDay.key(.dictation, $0), 500) })
    realistic.errors = ["dictation.network": 3, "chat.timeout": 1]
    realistic.models = ["transcription": [Self.knownModel: 400], "chat": ["custom": 12]]
    let realisticData = try #require(TelemetryService.encodeWithinLimit(realistic))
    let decoded = try JSONDecoder().decode(TelemetryPing.self, from: realisticData)
    #expect(decoded.models != nil, "a realistic day keeps its model breakdown")
  }

  @Test("Model ids: shipped ids pass, anything typed by the user becomes custom")
  func modelBucketing() {
    #expect(TelemetryModelID.normalize(Self.knownModel) == Self.knownModel)
    #expect(TelemetryModelID.normalize("llama3:8b-instruct") == "custom")
    #expect(TelemetryModelID.normalize("anthropic/claude via my proxy") == "custom")
    #expect(TelemetryModelID.normalize(nil) == nil)
  }

  @Test("The Swift vocabulary matches the server's schema.json exactly")
  func schemaParity() throws {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("server/telemetry/schema.json")
    let schema = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    func set(_ key: String) -> Set<String> { Set(schema[key] as? [String] ?? []) }

    #expect(schema["version"] as? Int == TelemetryPing.schemaVersion)
    #expect(schema["maxBytes"] as? Int == TelemetryService.maxPingBytes)
    #expect(set("areas") == Set(TelemetryArea.allCases.map(\.rawValue)))
    #expect(set("countNames") == Set(TelemetryCountName.allCases.map(\.rawValue)))
    #expect(set("errorClasses") == Set(TelemetryErrorClass.allCases.map(\.rawValue)))
    #expect(set("milestones") == Set(TelemetryMilestone.allCases.map(\.rawValue)))
    #expect(set("providers") == Set(TelemetryProvider.allCases.map(\.rawValue)))
    #expect(set("modelKinds") == Set(TelemetryModelKind.allCases.map(\.rawValue)))
    #expect(set("features") == Set(TelemetryFeature.allCases.map(\.rawValue)))
    #expect(set("setupFlags") == ["offlineWhisperModel", "smartImprovement", "autoPaste"])
    #expect(schema["modelIdPattern"] as? String == "^[a-z0-9][a-z0-9._:-]{0,47}$")
    #expect(TelemetryModelID.maxLength == 48)
  }

  @Test("A day saved before feature counts still loads")
  func dayDecodesWithoutFeatures() throws {
    let json = """
    {"counts":{"dictation.completed":2},"errors":{"chat.network":1},"models":{"chat":{"custom":1}}}
    """
    let day = try JSONDecoder().decode(TelemetryDay.self, from: Data(json.utf8))
    #expect(day.counts == ["dictation.completed": 2])
    #expect(day.errors == ["chat.network": 1])
    #expect(day.models == ["chat": ["custom": 1]])
    #expect(day.features.isEmpty)
    #expect(!day.isEmpty)
  }

  @Test("used() counts locally with sharing off and adds nothing to the day")
  func featureCountsStayLocalWhenOff() async {
    let h = makeHarness()
    h.service.used(.chat)
    h.service.used(.chat)
    h.service.completed(.dictation, modelKind: nil, model: nil)
    h.service.started(.readAloud)
    let entries = h.featureUsage.snapshot().entries
    #expect(entries[.chat]?.count == 2)
    #expect(entries[.dictation]?.count == 1)
    #expect(entries[.readAloud]?.count == 1)

    h.clock.advance(days: 1)
    await h.service.flush()
    #expect(h.transport.bodies.isEmpty)
    #expect(h.service.previewJSON().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: h.storeURL.path))
  }

  @Test("used() with sharing on is in the daily ping's features")
  func featureCountsInDailyPing() async throws {
    let h = makeHarness()
    h.enable()
    h.service.used(.glossaryAddSelection)
    h.service.completed(.prompt, modelKind: nil, model: nil)
    h.service.started(.meeting)
    h.clock.advance(days: 1)
    await h.service.flush()
    let daily = try #require(h.transport.pings.first { $0["kind"] as? String == "daily" })
    let features = try #require(daily["features"] as? [String: Int])
    #expect(features["glossaryAddSelection"] == 1)
    #expect(features["dictatePrompt"] == 1)
    #expect(features["meeting"] == 1)
    let local = h.featureUsage.snapshot().entries
    #expect(local[.glossaryAddSelection]?.count == 1)
    #expect(local[.dictatePrompt]?.count == 1)
    #expect(local[.meeting]?.count == 1)
  }

  @Test("Oversized pings shed models, then errors, then features")
  func featureCountsShedLast() throws {
    func bulk(_ prefix: String) -> [String: Int] {
      Dictionary(uniqueKeysWithValues: (0..<200).map {
        ("\(prefix)-\($0)-\(String(repeating: "k", count: 24))", 1)
      })
    }
    func decode(_ ping: TelemetryPing) throws -> TelemetryPing {
      let data = try #require(TelemetryService.encodeWithinLimit(ping))
      #expect(data.count <= TelemetryService.maxPingBytes)
      return try JSONDecoder().decode(TelemetryPing.self, from: data)
    }

    let base = TelemetryPing(
      app: "9.99", build: "direct", os: "26", cohortWeek: "2026-W40", dayIndex: 1, kind: .daily,
      counts: ["dictation.completed": 4])

    var modelsOnly = base
    modelsOnly.models = ["transcription": bulk("model")]
    modelsOnly.errors = ["dictation.network": 1]
    modelsOnly.features = ["dictation": 2]
    let shedModels = try decode(modelsOnly)
    #expect(shedModels.models == nil)
    #expect(shedModels.errors == ["dictation.network": 1])
    #expect(shedModels.features == ["dictation": 2])
    #expect(shedModels.counts == ["dictation.completed": 4])

    var errorsOnly = base
    errorsOnly.errors = bulk("error")
    errorsOnly.features = ["chat": 3]
    let shedErrors = try decode(errorsOnly)
    #expect(shedErrors.models == nil)
    #expect(shedErrors.errors == nil)
    #expect(shedErrors.features == ["chat": 3])
    #expect(shedErrors.counts == ["dictation.completed": 4])

    var featuresOnly = base
    featuresOnly.features = bulk("feature")
    let shedFeatures = try decode(featuresOnly)
    #expect(shedFeatures.models == nil)
    #expect(shedFeatures.errors == nil)
    #expect(shedFeatures.features == nil)
    #expect(shedFeatures.counts == ["dictation.completed": 4])
  }

  @Test("Feature groups follow the vocabulary headings")
  func featureGroups() {
    #expect(TelemetryFeature.chat.group == .core)
    #expect(TelemetryFeature.writingStyleApplied.group == .dictatePrompt)
    #expect(TelemetryFeature.offlineMode.group == .dictation)
    #expect(TelemetryFeature.readAloudSmartRewrite.group == .readAloud)
    #expect(TelemetryFeature.chatGPTPlan.group == .providers)
    #expect(TelemetryFeature.chatUserCommand.group == .chatCommands)
    #expect(TelemetryFeature.chatYouTube.group == .chatContent)
    #expect(TelemetryFeature.chatToolMeeting.group == .chatTools)
    #expect(TelemetryFeature.meetingSummary.group == .meetings)
    #expect(TelemetryFeature.mcpChange.group == .aiApps)
    #expect(TelemetryFeature.smartImprovementAccepted.group == .smartImprovement)
    #expect(TelemetryFeature.checkForUpdatesManual.group == .support)
    #expect(Set(TelemetryFeature.allCases.map(\.group)) == Set(TelemetryFeatureGroup.allCases))
  }
}
