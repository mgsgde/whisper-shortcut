import Foundation

/// Opt-in anonymous usage statistics — off unless the user turns them on.
///
/// Design and rationale: `plans/active/opt-in-telemetry.md`. The short version:
///
/// - **Nothing is sent or stored unless `isEnabled`.** Declining leaves no trace. The only thing
///   recorded regardless is local bookkeeping that never leaves the Mac on its own: the first-launch
///   date (so an opt-in on day 5 reports day 5, not day 0) and which activation "firsts" already
///   happened (so a first dictation after opting in late is not reported as a first).
/// - **Counts only, built from closed enums** (`TelemetryModels.swift`). No call site can hand
///   this type a string that ends up in a ping, except model ids, which pass `TelemetryModelID`.
/// - **No identifier.** Retention is computed server-side from `cohortWeek` + `dayIndex`, and each
///   install sends at most one daily ping per calendar day.
/// - Independent of "Save usage data": `ContextLogger` feeds this *before* its own logging guard,
///   otherwise only users who also opted into Smart Improvement would ever be counted.
final class TelemetryService: @unchecked Sendable {

  static let shared = TelemetryService(environment: .live)

  /// Where pings go. Source of the receiving service: `server/telemetry/`.
  static let endpoint = URL(string: "https://t.whispershortcut.com/v1/ping")!

  /// Completed days older than this that were never delivered are dropped, not piled up.
  static let maxPendingDays = 7
  private static let flushInterval: TimeInterval = 60 * 60

  private let env: TelemetryEnvironment
  private let lock = NSLock()

  // All state below is guarded by `lock`.
  private var loaded = false
  private var days: [String: TelemetryDay] = [:]
  private var pendingMilestones: [TelemetryPing] = []
  /// Onboarding steps reached before the user decided. Memory only: sent if they turn sharing on
  /// during onboarding, discarded otherwise.
  private var preConsentMilestones: [TelemetryMilestone] = []
  private var isFlushing = false
  private var timer: Timer?

  init(environment: TelemetryEnvironment) {
    self.env = environment
  }

  // MARK: - State

  /// Blocked by Offline Mode or by an administrator — the switch is hidden and forced off.
  var isAvailable: Bool {
    !env.offlineMode() && !env.defaults.bool(forKey: UserDefaultsKeys.telemetryForceDisabled)
  }

  /// The user's own choice, ignoring Offline Mode and the admin key. Off unless set.
  var storedFlag: Bool {
    env.defaults.bool(forKey: UserDefaultsKeys.telemetryEnabled)
  }

  var isEnabled: Bool { storedFlag && isAvailable }

  // MARK: - Lifecycle

  /// Call once at launch, on the main thread.
  func start() {
    recordFirstLaunchIfNeeded()
    guard timer == nil else { return }
    let timer = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
      guard let self else { return }
      Task { await self.flush() }
    }
    timer.tolerance = 5 * 60
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    Task { await flush() }
  }

  /// Persists the first-launch date the first time this build runs. An install that finished
  /// onboarding before telemetry existed is marked pre-existing: its real install date is
  /// unknown, so it reports `cohortWeek: "pre-telemetry"` instead of distorting a new cohort.
  func recordFirstLaunchIfNeeded() {
    let defaults = env.defaults
    guard defaults.object(forKey: UserDefaultsKeys.telemetryFirstLaunchDate) == nil else { return }
    defaults.set(env.now(), forKey: UserDefaultsKeys.telemetryFirstLaunchDate)
    defaults.set(env.isExistingInstall(), forKey: UserDefaultsKeys.telemetryPreExistingInstall)
  }

  /// Called by the toggles in onboarding and Settings after they write the stored flag.
  func consentChanged(_ enabled: Bool) {
    if enabled {
      guard isEnabled else { return }
      DebugLogger.log("TELEMETRY: sharing turned on")
      lock.lock()
      // The buffer only stands for consent given *during* onboarding. Opting in later from
      // Settings must not replay steps walked through with the switch off.
      let buffered = env.defaults.bool(forKey: UserDefaultsKeys.hasCompletedOnboarding) ? [] : preConsentMilestones
      preConsentMilestones = []
      lock.unlock()
      milestone(.telemetryEnabled)
      buffered.forEach { milestone($0) }
    } else {
      DebugLogger.log("TELEMETRY: sharing turned off — pending data deleted")
      lock.lock()
      loadIfNeeded()
      // Milestones that were queued but never delivered are "unsent" again, so a later opt-in
      // still reports them — above all `telemetry.enabled`, the cohort denominator.
      var sent = Set(env.defaults.stringArray(forKey: UserDefaultsKeys.telemetrySentMilestones) ?? [])
      pendingMilestones.compactMap { $0.milestone?.rawValue }.forEach { sent.remove($0) }
      env.defaults.set(sent.sorted(), forKey: UserDefaultsKeys.telemetrySentMilestones)
      days = [:]
      pendingMilestones = []
      preConsentMilestones = []
      lock.unlock()
      try? FileManager.default.removeItem(at: env.storeURL)
      env.defaults.removeObject(forKey: UserDefaultsKeys.telemetryLastSentPayload)
    }
  }

  // MARK: - Recording

  func started(_ area: TelemetryArea) {
    count(area, .started)
  }

  /// A finished dictation / prompt / chat turn. `model` is normalised by `TelemetryModelID`.
  func completed(_ area: TelemetryArea, modelKind: TelemetryModelKind?, model: String?) {
    switch area {
    case .dictation: noteActivation(.firstDictation)
    case .prompt: noteActivation(.firstPrompt)
    case .chat: noteActivation(.firstChat)
    default: break
    }
    guard isEnabled else { return }
    mutateToday { day in
      day.counts[TelemetryDay.key(area, .completed), default: 0] += 1
      if let modelKind, let id = TelemetryModelID.normalize(model) {
        day.models[modelKind.rawValue, default: [:]][id, default: 0] += 1
      }
    }
  }

  func failed(_ area: TelemetryArea, error: Error) {
    let errorClass = TelemetryErrorClass(error)
    if area == .dictation, !activationSeen(.firstDictation) {
      noteActivation(.firstDictationFailed, errorClass: errorClass)
    }
    guard isEnabled else { return }
    mutateToday { day in
      day.counts[TelemetryDay.key(area, .failed), default: 0] += 1
      day.errors[TelemetryDay.key(area, errorClass), default: 0] += 1
    }
  }

  /// Every `OutcomeSignal` — fed by `ContextLogger.logSignal`. The signal's `detail` is not
  /// accepted here at all: it is free-form, so it has no path into a ping.
  func signal(_ signal: OutcomeSignal, mode: String?) {
    count(TelemetryArea(logMode: mode), TelemetryCountName(signal: signal))
  }

  func count(_ area: TelemetryArea, _ name: TelemetryCountName) {
    guard isEnabled else { return }
    mutateToday { $0.counts[TelemetryDay.key(area, name), default: 0] += 1 }
  }

  func onboardingStepReached(_ step: WelcomeStep) {
    milestone(TelemetryMilestone(step: step))
  }

  /// Queues a once-per-install milestone and sends it right away.
  func milestone(_ milestone: TelemetryMilestone, errorClass: TelemetryErrorClass? = nil) {
    guard isEnabled else {
      bufferBeforeConsent(milestone)
      return
    }
    var ping = envelope(kind: .milestone, dayIndex: dayIndex(of: env.now()))
    ping.milestone = milestone
    ping.errorClass = errorClass
    lock.lock()
    var sent = Set(env.defaults.stringArray(forKey: UserDefaultsKeys.telemetrySentMilestones) ?? [])
    guard !sent.contains(milestone.rawValue) else {
      lock.unlock()
      return
    }
    sent.insert(milestone.rawValue)
    env.defaults.set(sent.sorted(), forKey: UserDefaultsKeys.telemetrySentMilestones)
    loadIfNeeded()
    pendingMilestones.append(ping)
    persist()
    lock.unlock()
    if env.autoFlush { Task { await flush() } }
  }

  // MARK: - Sending

  /// Sends queued milestones and every completed day that has counts. Today is never sent — it is
  /// still filling up — which is what keeps it to one daily ping per calendar day.
  func flush() async {
    guard isEnabled else { return }
    // Keychain and model-folder reads, done before taking the lock that recording calls wait on.
    let setup = env.setup()
    lock.lock()
    guard !isFlushing else {
      lock.unlock()
      return
    }
    isFlushing = true
    loadIfNeeded()
    dropStaleDays()
    let milestones = pendingMilestones
    let todayKey = dayKey(env.now())
    var due: [(key: String, ping: TelemetryPing)] = []
    for key in days.keys.filter({ $0 < todayKey }).sorted() {
      if let day = days[key], let ping = dailyPing(key: key, day: day, setup: setup) {
        due.append((key, ping))
      } else {
        days[key] = nil
      }
    }
    persist()
    lock.unlock()

    // `isEnabled` is re-checked before every send: turning the switch off or Offline Mode on
    // mid-flush (sends can take seconds each) must stop what has not gone out yet.
    var deliveredMilestones: [TelemetryPing] = []
    for ping in milestones {
      guard isEnabled, await deliver(ping) else { break }
      deliveredMilestones.append(ping)
    }
    var deliveredDays: [String] = []
    for item in due {
      guard isEnabled, await deliver(item.ping) else { break }
      deliveredDays.append(item.key)
    }

    lock.lock()
    // A turn-off during the await already cleared everything; do not resurrect it.
    if storedFlag {
      // By identity, not by count: a turn-off/on during the await may have queued new ones.
      for ping in deliveredMilestones {
        if let index = pendingMilestones.firstIndex(of: ping) { pendingMilestones.remove(at: index) }
      }
      deliveredDays.forEach { days[$0] = nil }
      persist()
    }
    isFlushing = false
    lock.unlock()
  }

  /// `true` when the ping is done with — delivered, or refused by the server (a malformed ping is
  /// not retried forever). `false` only for transport failures, which are retried next flush.
  private func deliver(_ ping: TelemetryPing) async -> Bool {
    guard let body = Self.encodeWithinLimit(ping) else { return true }
    switch await env.transport.send(body) {
    case .delivered:
      env.defaults.set(String(decoding: body, as: UTF8.self), forKey: UserDefaultsKeys.telemetryLastSentPayload)
      DebugLogger.log("TELEMETRY: sent \(ping.kind.rawValue) ping (\(body.count) bytes)")
      return true
    case .rejected(let status):
      DebugLogger.logWarning("TELEMETRY: server rejected \(ping.kind.rawValue) ping (HTTP \(status)) — dropped")
      return true
    case .failed:
      DebugLogger.log("TELEMETRY: send failed — will retry on the next flush")
      return false
    }
  }

  // MARK: - Transparency

  /// Everything that is queued, as the exact JSON that would be sent — including today's counts
  /// so far. Shown verbatim in Settings → "Show what's sent".
  func previewJSON() -> String {
    let setup = env.setup()
    lock.lock()
    loadIfNeeded()
    var pings = pendingMilestones
    for key in days.keys.sorted() {
      if let day = days[key], let ping = dailyPing(key: key, day: day, setup: setup) { pings.append(ping) }
    }
    lock.unlock()
    guard !pings.isEmpty else { return "" }
    return pings.compactMap { try? Self.prettyEncoder.encode($0) }
      .map { String(decoding: $0, as: UTF8.self) }
      .joined(separator: "\n\n")
  }

  var lastSentJSON: String? {
    guard let raw = env.defaults.string(forKey: UserDefaultsKeys.telemetryLastSentPayload),
      let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
      let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else { return nil }
    return String(decoding: pretty, as: UTF8.self)
  }

  // MARK: - Internals

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
  }()

  /// Mirrors `maxBytes` in `server/telemetry/schema.json`; the server answers 413 above it.
  static let maxPingBytes = 4096

  /// Encodes the ping, shedding the least important detail if it would exceed the server's limit:
  /// model breakdown first, then error classes. Counts and the envelope always survive.
  static func encodeWithinLimit(_ ping: TelemetryPing) -> Data? {
    var ping = ping
    for step in 0...2 {
      if step == 1 { ping.models = nil }
      if step == 2 { ping.errors = nil }
      if let data = try? encoder.encode(ping), data.count <= maxPingBytes { return data }
    }
    return nil
  }

  private static let prettyEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .prettyPrinted]
    return e
  }()

  private func bufferBeforeConsent(_ milestone: TelemetryMilestone) {
    // Only an onboarding still in progress can still end with the user opting in.
    guard milestone.rawValue.hasPrefix("onboarding."),
      !env.defaults.bool(forKey: UserDefaultsKeys.hasCompletedOnboarding),
      isAvailable
    else { return }
    lock.lock()
    if !preConsentMilestones.contains(milestone) { preConsentMilestones.append(milestone) }
    lock.unlock()
  }

  private func activationSeen(_ milestone: TelemetryMilestone) -> Bool {
    (env.defaults.stringArray(forKey: UserDefaultsKeys.telemetryActivationSeen) ?? []).contains(milestone.rawValue)
  }

  /// Records a "first" locally whether or not sharing is on, and sends it only if it is — so a
  /// user who opts in on day 10 does not report their 50th dictation as their first.
  private func noteActivation(_ milestone: TelemetryMilestone, errorClass: TelemetryErrorClass? = nil) {
    lock.lock()
    var seen = env.defaults.stringArray(forKey: UserDefaultsKeys.telemetryActivationSeen) ?? []
    guard !seen.contains(milestone.rawValue) else {
      lock.unlock()
      return
    }
    seen.append(milestone.rawValue)
    env.defaults.set(seen, forKey: UserDefaultsKeys.telemetryActivationSeen)
    lock.unlock()
    if isEnabled { self.milestone(milestone, errorClass: errorClass) }
  }

  private func mutateToday(_ change: (inout TelemetryDay) -> Void) {
    let key = dayKey(env.now())
    lock.lock()
    loadIfNeeded()
    change(&days[key, default: TelemetryDay()])
    persist()
    lock.unlock()
  }

  private func dailyPing(key: String, day: TelemetryDay, setup: TelemetrySetup) -> TelemetryPing? {
    guard !day.isEmpty, let date = date(fromDayKey: key) else { return nil }
    var ping = envelope(kind: .daily, dayIndex: dayIndex(of: date))
    ping.setup = setup
    ping.counts = day.counts.isEmpty ? nil : day.counts
    ping.errors = day.errors.isEmpty ? nil : day.errors
    ping.models = day.models.isEmpty ? nil : day.models
    return ping
  }

  private func envelope(kind: TelemetryPing.Kind, dayIndex: Int) -> TelemetryPing {
    TelemetryPing(
      app: env.appVersion, build: env.build, os: env.osMajor,
      cohortWeek: cohortWeek(), dayIndex: dayIndex, kind: kind)
  }

  private var firstLaunchDate: Date {
    env.defaults.object(forKey: UserDefaultsKeys.telemetryFirstLaunchDate) as? Date ?? env.now()
  }

  func cohortWeek() -> String {
    if env.defaults.bool(forKey: UserDefaultsKeys.telemetryPreExistingInstall) { return "pre-telemetry" }
    var iso = Calendar(identifier: .iso8601)
    iso.timeZone = env.calendar.timeZone
    let c = iso.dateComponents([.yearForWeekOfYear, .weekOfYear], from: firstLaunchDate)
    return String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
  }

  func dayIndex(of date: Date) -> Int {
    let start = env.calendar.startOfDay(for: firstLaunchDate)
    let end = env.calendar.startOfDay(for: date)
    return max(0, env.calendar.dateComponents([.day], from: start, to: end).day ?? 0)
  }

  private func dayKey(_ date: Date) -> String {
    let c = env.calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  private func date(fromDayKey key: String) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return env.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
  }

  /// Caller holds `lock`.
  private func dropStaleDays() {
    guard let cutoff = env.calendar.date(byAdding: .day, value: -Self.maxPendingDays, to: env.now()) else { return }
    let cutoffKey = dayKey(cutoff)
    for key in days.keys where key < cutoffKey { days[key] = nil }
  }

  // MARK: - Persistence (caller holds `lock`)

  private struct StoreFile: Codable {
    var days: [String: TelemetryDay]
    var pendingMilestones: [TelemetryPing]
  }

  private func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true
    guard let data = try? Data(contentsOf: env.storeURL),
      let file = try? JSONDecoder().decode(StoreFile.self, from: data)
    else { return }
    days = file.days
    pendingMilestones = file.pendingMilestones
  }

  private func persist() {
    guard storedFlag else { return }
    let file = StoreFile(days: days, pendingMilestones: pendingMilestones)
    guard let data = try? Self.encoder.encode(file) else { return }
    do {
      try FileManager.default.createDirectory(
        at: env.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: env.storeURL, options: .atomic)
    } catch {
      DebugLogger.logWarning("TELEMETRY: could not save pending counts: \(error.localizedDescription)")
    }
  }
}

// MARK: - Environment

enum TelemetrySendResult: Equatable {
  case delivered
  case rejected(Int)
  case failed
}

protocol TelemetryTransport: Sendable {
  func send(_ body: Data) async -> TelemetrySendResult
}

/// Ephemeral session: no cookies, no cache, nothing that could tie two pings together.
struct URLSessionTelemetryTransport: TelemetryTransport {
  let endpoint: URL

  private static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.urlCache = nil
    config.timeoutIntervalForRequest = 10
    config.timeoutIntervalForResource = 15
    // Belt and braces: `isEnabled` already refuses while Offline Mode is on, but every session the
    // app builds carries the Offline Mode guard, so this one does too.
    OfflineModeURLProtocol.install(on: config)
    return URLSession(configuration: config)
  }()

  func send(_ body: Data) async -> TelemetrySendResult {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    do {
      let (_, response) = try await Self.session.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      switch status {
      case 200..<300: return .delivered
      // Only "your ping is malformed" drops it. A 404/403/429 is the endpoint or routing being
      // wrong for now (e.g. a domain mapping not live yet), and the data must survive it.
      case 400, 413, 422: return .rejected(status)
      default: return .failed
      }
    } catch {
      return .failed
    }
  }
}

struct TelemetryEnvironment {
  var defaults: UserDefaults
  var now: () -> Date
  var calendar: Calendar
  var storeURL: URL
  var transport: TelemetryTransport
  var offlineMode: () -> Bool
  var setup: () -> TelemetrySetup
  var isExistingInstall: () -> Bool
  var appVersion: String
  var build: String
  var osMajor: String
  /// Send milestones the moment they are queued. Tests turn this off and call `flush()` themselves.
  var autoFlush = true

  static var live: TelemetryEnvironment {
    #if APP_STORE
    let build = "appstore"
    #else
    let build = "direct"
    #endif
    return TelemetryEnvironment(
      defaults: .standard,
      now: Date.init,
      calendar: .current,
      storeURL: AppSupportPaths.whisperShortcutApplicationSupportURL()
        .appendingPathComponent("telemetry-pending.json"),
      transport: URLSessionTelemetryTransport(endpoint: TelemetryService.endpoint),
      offlineMode: { OfflineMode.isEnabled },
      setup: liveSetup,
      isExistingInstall: { UserDefaults.standard.bool(forKey: UserDefaultsKeys.hasCompletedOnboarding) },
      appVersion: AppConstants.appVersion,
      build: build,
      osMajor: "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
    )
  }

  private static func liveSetup() -> TelemetrySetup {
    let keychain = KeychainManager.shared
    var providers: [TelemetryProvider] = []
    if keychain.hasNonEmpty(.google) { providers.append(.gemini) }
    if keychain.hasNonEmpty(.openAI) { providers.append(.openai) }
    if keychain.hasNonEmpty(.xai) { providers.append(.xai) }
    if keychain.hasNonEmpty(.anthropic) { providers.append(.anthropic) }
    if keychain.hasNonEmpty(.openRouter) { providers.append(.openrouter) }
    return TelemetrySetup(
      providers: providers,
      offlineWhisperModel: OfflineModelType.byAccuracy.contains { ModelManager.shared.isModelAvailable($0) },
      smartImprovement: ContextLoggingPreference.storedFlag,
      autoPaste: UserDefaults.standard.bool(forKey: UserDefaultsKeys.autoPasteAfterDictation)
    )
  }
}
