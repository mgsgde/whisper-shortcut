//
//  TestProfileOverrides.swift
//  WhisperShortcut
//
//  Launch arguments that put a test profile into states this Mac cannot produce on demand (the 🌐
//  key in conflict, the microphone denied, a download at 40 %, a full disk, an Intel Mac …), so
//  every screen of the onboarding and Settings can be looked at and screenshotted
//  (`scripts/ui-catalogue.sh`). Parsed once. Outside a test profile (`TestProfile.isActive` false)
//  every one of these arguments is ignored: `current` is `.none` and no reader changes behaviour.
//
//  Arguments (each optional):
//    --onboarding-step <id>      open the Welcome Tour on that step. Dictation-only path: mode,
//                                globe, language, permissions, download, test, glossary, done.
//                                Full path: full-setup, full-permissions, full-try, full-done.
//    --dictation-only on|off     the mode at launch, Welcome Tour closed (Settings, status menu).
//    --settings-tab <tab>        open Settings on that tab at launch (general, dictate, permissions, about).
//    --globe free|emoji|input|dictation   what macOS does with the 🌐 key.
//    --mic not-determined|denied|granted
//    --accessibility missing|denied|granted
//    --download not-started|running:<percent>|finished|failed   a stub, never a real download.
//    --disk-full                 the download's free-space check fails.
//    --language-needs-pick       the Mac's language is one the offline model cannot transcribe.
//    --intel                     Live is unavailable (Intel Mac).
//    --recording-running         a recording is running: switching the mode is refused.
//    --audio-file <path>         the try-it panel transcribes this WAV instead of recording.
//

import Foundation

struct TestProfileOverrides: Equatable {

  enum OnboardingStep: Equatable {
    case modeChoice
    case dictationOnly(DictationOnlyStep)
    case full(WelcomeStep)
  }

  enum Download: Equatable {
    case notStarted
    case running(percent: Int)
    case finished
    case failed
  }

  var onboardingStep: OnboardingStep?
  var dictationOnlyMode: Bool?
  var settingsTab: SettingsTab?
  var globeKey: GlobeKeyUsage?
  var microphone: PermissionStatus?
  var accessibility: PermissionStatus?
  var download: Download?
  var diskFull = false
  var languageNeedsPick = false
  var intelMac = false
  var recordingRunning = false
  var audioFile: String?

  static let none = TestProfileOverrides()

  var isEmpty: Bool { self == .none }

  /// The overrides of this process. Read once; `.none` unless this process is a test profile.
  static let current = parse(
    arguments: ProcessInfo.processInfo.arguments, profileActive: TestProfile.isActive)

  /// Pure, so a test can prove that a normal launch ignores every argument.
  static func parse(arguments: [String], profileActive: Bool) -> TestProfileOverrides {
    guard profileActive else { return .none }
    var result = TestProfileOverrides()
    func value(_ flag: String) -> String? {
      guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
      return arguments[index + 1]
    }

    if let id = value("--onboarding-step") { result.onboardingStep = onboardingStep(id) }
    if let mode = value("--dictation-only") { result.dictationOnlyMode = mode == "on" ? true : (mode == "off" ? false : nil) }
    switch value("--settings-tab") {
    case "general": result.settingsTab = .general
    case "dictate": result.settingsTab = .speechToText
    case "permissions": result.settingsTab = .permissions
    case "about": result.settingsTab = .about
    default: break
    }
    switch value("--globe") {
    case "free": result.globeKey = .doNothing
    case "emoji": result.globeKey = .emojiAndSymbols
    case "input": result.globeKey = .changeInputSource
    case "dictation": result.globeKey = .startDictation
    default: break
    }
    result.microphone = permission(value("--mic"))
    result.accessibility = permission(value("--accessibility"))
    if let download = value("--download") {
      switch download {
      case "not-started": result.download = .notStarted
      case "finished": result.download = .finished
      case "failed": result.download = .failed
      default:
        if download.hasPrefix("running:"), let percent = Int(download.dropFirst("running:".count)) {
          result.download = .running(percent: min(99, max(0, percent)))
        }
      }
    }
    result.diskFull = arguments.contains("--disk-full")
    result.languageNeedsPick = arguments.contains("--language-needs-pick")
    result.intelMac = arguments.contains("--intel")
    result.recordingRunning = arguments.contains("--recording-running")
    result.audioFile = value("--audio-file").flatMap { $0.hasPrefix("/") ? $0 : nil }
    return result
  }

  private static func permission(_ raw: String?) -> PermissionStatus? {
    switch raw {
    case "granted": return .granted
    case "denied": return .denied
    case "not-determined", "missing": return .notDetermined
    default: return nil
    }
  }

  private static func onboardingStep(_ id: String) -> OnboardingStep? {
    switch id {
    case "mode": return .modeChoice
    case "globe": return .dictationOnly(.globeKey)
    case "language": return .dictationOnly(.language)
    case "permissions": return .dictationOnly(.permissions)
    case "download": return .dictationOnly(.download)
    case "test": return .dictationOnly(.test)
    case "glossary": return .dictationOnly(.glossary)
    case "done": return .dictationOnly(.done)
    case "full-setup": return .full(.dictationSetup)
    case "full-permissions": return .full(.permissions)
    case "full-try": return .full(.tryIt)
    case "full-done": return .full(.done)
    default: return nil
    }
  }

  // MARK: - Launch

  /// The Mac languages `DictationOnlyDefaults.apply` sees: with `--language-needs-pick` one the
  /// offline model does not transcribe, so the language step asks for an explicit pick.
  var preferredLanguages: [String] {
    languageNeedsPick ? ["ja-JP"] : Locale.preferredLanguages
  }

  /// Writes the start state the arguments ask for, before the launch decides between the Welcome
  /// Tour and Settings. Only ever called in a test profile (its own container).
  @MainActor
  static func applyAtLaunch() {
    let overrides = current
    guard TestProfile.isActive, !overrides.isEmpty else { return }
    let defaults = UserDefaults.standard
    func enterDictationOnly() {
      defaults.set(true, forKey: UserDefaultsKeys.dictationOnlyMode)
      _ = DictationOnlyDefaults.apply(preferredLanguages: overrides.preferredLanguages)
    }
    switch overrides.onboardingStep {
    case .modeChoice:
      defaults.set(false, forKey: UserDefaultsKeys.hasCompletedOnboarding)
      defaults.set(WelcomeStep.intro.rawValue, forKey: UserDefaultsKeys.onboardingCurrentStep)
    case .dictationOnly(let step):
      enterDictationOnly()
      defaults.set(false, forKey: UserDefaultsKeys.hasCompletedOnboarding)
      defaults.set(step.rawValue, forKey: UserDefaultsKeys.onboardingCurrentStep)
    case .full(let step):
      defaults.set(false, forKey: UserDefaultsKeys.dictationOnlyMode)
      defaults.set(false, forKey: UserDefaultsKeys.hasCompletedOnboarding)
      defaults.set(step.rawValue, forKey: UserDefaultsKeys.onboardingCurrentStep)
    case nil:
      break
    }
    if let mode = overrides.dictationOnlyMode {
      if mode { enterDictationOnly() } else { defaults.set(false, forKey: UserDefaultsKeys.dictationOnlyMode) }
      if overrides.onboardingStep == nil { defaults.set(true, forKey: UserDefaultsKeys.hasCompletedOnboarding) }
    }
    DebugLogger.log("TEST-PROFILE: overrides applied \(overrides)")
  }

  /// After launch: Settings on the requested tab.
  @MainActor
  static func openRequestedWindow() {
    guard TestProfile.isActive else { return }
    // `running:<n>` means a download is under way, as after "Dictation only" was chosen: start the
    // stub, so Settings, the status menu and the dictation popup see it running.
    if case .running? = current.download, current.onboardingStep == nil {
      DictationOnlyFlow.startDownloadEarly()
    }
    guard let tab = current.settingsTab else { return }
    SettingsManager.shared.showSettings(tab: tab)
  }

  // MARK: - Download stub

  /// The pretend download a profile runs instead of a real one when `--download` is given: it
  /// starts at the given percent and advances one percent every two seconds.
  final class DownloadStub: @unchecked Sendable {
    static let shared = DownloadStub()
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
      lock.lock(); defer { lock.unlock() }
      return finished
    }

    func markFinished() {
      lock.lock(); finished = true; lock.unlock()
    }
  }

  /// Availability of an offline model as the stub reports it, nil when no stub is active.
  static func stubbedModelAvailability() -> Bool? {
    guard let download = current.download else { return nil }
    return download == .finished || DownloadStub.shared.isFinished
  }

  /// Runs the pretend download. `report` receives 0…1. Throws like the real one would.
  static func runStubDownload(report: @escaping @MainActor (Double) -> Void) async throws {
    guard let download = current.download else { return }
    switch download {
    case .finished:
      return
    case .notStarted:
      // Nothing runs: the screen keeps its Download button.
      throw CancellationError()
    case .failed:
      await report(0.12)
      try await Task.sleep(nanoseconds: 1_500_000_000)
      throw URLError(.networkConnectionLost)
    case .running(let percent):
      var current = percent
      while current < 100 {
        await report(Double(current) / 100)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        current += 1
      }
      DownloadStub.shared.markFinished()
    }
  }
}
