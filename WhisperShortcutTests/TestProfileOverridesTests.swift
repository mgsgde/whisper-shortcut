import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// `TestProfileOverrides`: the state-injection arguments of `scripts/ui-catalogue.sh` take effect
/// in a test profile only. A normal launch ignores every one of them.
@Suite("Test profile overrides")
struct TestProfileOverridesTests {

  private let everyArgument = [
    "/x/WhisperShortcut Dev", "--sidecar",
    "--onboarding-step", "download",
    "--dictation-only", "on",
    "--settings-tab", "dictate",
    "--globe", "emoji",
    "--mic", "denied",
    "--accessibility", "missing",
    "--download", "running:40",
    "--disk-full",
    "--language-needs-pick",
    "--intel",
    "--recording-running",
    "--audio-file", "/tmp/sample.wav",
    "--live-audio-file", "/tmp/live.wav",
  ]

  @Test("A normal launch ignores every override argument")
  func normalLaunchIgnoresEverything() {
    let parsed = TestProfileOverrides.parse(arguments: everyArgument, profileActive: false)
    #expect(parsed == .none)
    #expect(parsed.isEmpty)
    #expect(parsed.preferredLanguages == Locale.preferredLanguages)
  }

  @Test("The running test host is not a profile, so its overrides are empty")
  func testHostHasNoOverrides() {
    #expect(!TestProfile.isActive)
    #expect(TestProfileOverrides.current == .none)
    #expect(TestProfileOverrides.stubbedModelAvailability() == nil)
  }

  @Test("In a profile every argument is read")
  func profileReadsEverything() {
    let parsed = TestProfileOverrides.parse(arguments: everyArgument, profileActive: true)
    #expect(parsed.onboardingStep == .dictationOnly(.download))
    #expect(parsed.dictationOnlyMode == true)
    #expect(parsed.settingsTab == .speechToText)
    #expect(parsed.globeKey == .emojiAndSymbols)
    #expect(parsed.microphone == .denied)
    #expect(parsed.accessibility == .notDetermined)
    #expect(parsed.download == .running(percent: 40))
    #expect(parsed.diskFull)
    #expect(parsed.languageNeedsPick)
    #expect(parsed.intelMac)
    #expect(parsed.recordingRunning)
    #expect(parsed.audioFile == "/tmp/sample.wav")
    #expect(parsed.liveAudioFile == "/tmp/live.wav")
    #expect(parsed.preferredLanguages == ["ja-JP"])
  }

  @Test("Unknown values and relative audio paths are dropped")
  func unknownValuesDropped() {
    let parsed = TestProfileOverrides.parse(
      arguments: [
        "--onboarding-step", "nope", "--globe", "x", "--download", "running:abc",
        "--audio-file", "rel.wav", "--live-audio-file", "rel.wav",
      ],
      profileActive: true)
    #expect(parsed == .none)
    #expect(parsed.liveAudioFile == nil)
  }

  @Test("--glossary-terms splits on semicolons, trims and drops empties; a normal launch ignores it")
  func glossaryTerms() {
    let parsed = TestProfileOverrides.parse(
      arguments: ["--glossary-terms", "a; b;c;; "], profileActive: true)
    #expect(parsed.glossaryTerms == ["a", "b", "c"])
    let normal = TestProfileOverrides.parse(
      arguments: ["--glossary-terms", "a;b"], profileActive: false)
    #expect(normal.glossaryTerms == nil)
  }

  @Test("An absolute --live-audio-file is kept, a relative one and a normal launch are not")
  func liveAudioFile() {
    let kept = TestProfileOverrides.parse(
      arguments: ["--live-audio-file", "/tmp/live.wav"], profileActive: true)
    #expect(kept.liveAudioFile == "/tmp/live.wav")
    let relative = TestProfileOverrides.parse(
      arguments: ["--live-audio-file", "live.wav"], profileActive: true)
    #expect(relative.liveAudioFile == nil)
    #expect(relative == .none)
    let ignored = TestProfileOverrides.parse(
      arguments: ["--live-audio-file", "/tmp/live.wav"], profileActive: false)
    #expect(ignored == .none)
  }

  @Test("Full-path steps and download states parse")
  func stepsAndDownloads() {
    func step(_ id: String) -> TestProfileOverrides.OnboardingStep? {
      TestProfileOverrides.parse(arguments: ["--onboarding-step", id], profileActive: true).onboardingStep
    }
    #expect(step("mode") == .modeChoice)
    #expect(step("globe") == .dictationOnly(.globeKey))
    #expect(step("full-permissions") == .full(.permissions))
    func download(_ raw: String) -> TestProfileOverrides.Download? {
      TestProfileOverrides.parse(arguments: ["--download", raw], profileActive: true).download
    }
    #expect(download("not-started") == .notStarted)
    #expect(download("finished") == .finished)
    #expect(download("failed") == .failed)
    #expect(download("running:150") == .running(percent: 99))
  }
}

/// The last screen names a shortcut by the words on the keys.
@Suite("Dictation only key names")
struct DictationOnlyKeyNamesTests {
  @Test("Modifiers are spelled in keyboard order, the key comes last")
  func spellsModifiers() {
    #expect(DictationOnlyKeyNames.spell("⌥⌃1") == "control + option + 1")
    #expect(DictationOnlyKeyNames.spell("⌘⇧D") == "shift + command + D")
    #expect(DictationOnlyKeyNames.spell("⌘1") == "command + 1")
  }

  @Test("No glyphs left in the spelled form")
  func noGlyphs() {
    let spelled = DictationOnlyKeyNames.spell("⌘⌥⌃⇧F5")
    #expect(!spelled.contains { "⌘⌥⌃⇧".contains($0) })
    #expect(spelled.hasSuffix("F5"))
  }
}

/// The popup when the dictation key is pressed before the offline model is on this Mac.
@Suite("Live unavailable message")
struct LiveUnavailableMessageTests {

  @Test("Dictation only: a running download says so in plain words")
  func dictationOnlyDownloadRunning() {
    let text = LiveDictation.Unavailable.notDownloaded.message(dictationOnly: true, downloadRunning: true)
    #expect(text == String(localized: "The download is still running. You can dictate as soon as it has finished."))
    #expect(!text.contains("Parakeet"))
  }

  @Test("Dictation only: no download yet points to Settings without a model name")
  func dictationOnlyNotStarted() {
    let text = LiveDictation.Unavailable.notDownloaded.message(dictationOnly: true, downloadRunning: false)
    #expect(!text.contains("Parakeet"))
    #expect(!text.contains("Live"))
  }

  @Test("The full app keeps its message")
  func fullAppUnchanged() {
    #expect(
      LiveDictation.Unavailable.notDownloaded.message(dictationOnly: false, downloadRunning: true)
        == LiveDictation.Unavailable.notDownloaded.message)
    #expect(
      LiveDictation.Unavailable.intelMac.message(dictationOnly: true, downloadRunning: false)
        == LiveDictation.Unavailable.intelMac.message)
  }
}
