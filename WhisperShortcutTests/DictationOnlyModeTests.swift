import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Dictation only mode")
struct DictationOnlyModeTests {

  /// A throwaway defaults domain so no test touches the real preferences.
  private func makeDefaults() -> UserDefaults {
    let name = "DictationOnlyModeTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  // MARK: - Flag

  @Test("Off by default")
  func defaultsOff() {
    #expect(makeDefaults().bool(forKey: UserDefaultsKeys.dictationOnlyMode) == false)
  }

  @Test("setEnabled writes the key and posts the notification")
  func setEnabledWritesAndPosts() {
    let defaults = makeDefaults()
    let center = NotificationCenter()
    var posted = 0
    let token = center.addObserver(forName: .dictationOnlyModeChanged, object: nil, queue: nil) { _ in
      posted += 1
    }
    defer { center.removeObserver(token) }
    let changed = DictationOnlyMode.setEnabled(
      true, meetingActive: false, recording: false, defaults: defaults, notificationCenter: center)
    #expect(changed)
    #expect(defaults.bool(forKey: UserDefaultsKeys.dictationOnlyMode))
    #expect(posted == 1)
  }

  @Test("setEnabled is refused while a meeting or a recording runs")
  func setEnabledRefusedWhileBusy() {
    for (meeting, recording) in [(true, false), (false, true), (true, true)] {
      let defaults = makeDefaults()
      let center = NotificationCenter()
      var posted = 0
      let token = center.addObserver(forName: .dictationOnlyModeChanged, object: nil, queue: nil) { _ in
        posted += 1
      }
      defer { center.removeObserver(token) }
      let changed = DictationOnlyMode.setEnabled(
        true, meetingActive: meeting, recording: recording, defaults: defaults,
        notificationCenter: center)
      #expect(!changed)
      #expect(defaults.object(forKey: UserDefaultsKeys.dictationOnlyMode) == nil)
      #expect(posted == 0)
    }
  }

  @Test("On then off leaves every other stored key untouched")
  func roundTripLeavesOtherKeys() {
    let defaults = makeDefaults()
    defaults.set("de", forKey: UserDefaultsKeys.whisperLanguage)
    defaults.set("parakeet-ultra", forKey: UserDefaultsKeys.selectedTranscriptionModel)
    defaults.set(true, forKey: UserDefaultsKeys.offlineModeEnabled)
    defaults.set(Data([1, 2, 3]), forKey: "someShortcutBinding")
    let before = defaults.dictionaryRepresentation().filter { $0.key != UserDefaultsKeys.dictationOnlyMode }

    DictationOnlyMode.setEnabled(true, meetingActive: false, recording: false, defaults: defaults)
    DictationOnlyMode.setEnabled(false, meetingActive: false, recording: false, defaults: defaults)

    let after = defaults.dictionaryRepresentation().filter { $0.key != UserDefaultsKeys.dictationOnlyMode }
    #expect(NSDictionary(dictionary: before).isEqual(to: after))
    #expect(defaults.bool(forKey: UserDefaultsKeys.dictationOnlyMode) == false)
  }

  // MARK: - What the mode shows

  @Test("Settings tabs: everything with the mode off, four with it on")
  func tabList() {
    #expect(DictationOnlyMode.visibleTabs(SettingsTab.allCases, enabled: false) == SettingsTab.allCases)
    #expect(
      DictationOnlyMode.visibleTabs(SettingsTab.allCases, enabled: true)
        == [.general, .speechToText, .permissions, .about])
  }

  @Test("Sidebar sections lose the ones with no tab left")
  func sectionList() {
    #expect(SettingsTab.sections(enabled: false) == SettingsTab.SettingsSection.allCases)
    #expect(SettingsTab.sections(enabled: true) == [.general, .dictation, .more])
    #expect(SettingsTab.SettingsSection.general.tabs(enabled: true) == [.general, .permissions])
    #expect(SettingsTab.SettingsSection.dictation.tabs(enabled: true) == [.speechToText])
    #expect(SettingsTab.SettingsSection.more.tabs(enabled: true) == [.about])
  }

  @Test("Status menu rows: all with the mode off, dictation rows, Settings, updates and Quit with it on")
  func menuRows() {
    #expect(DictationOnlyMode.menuRows(enabled: false) == StatusMenuRow.allCases)
    #expect(
      Set(DictationOnlyMode.menuRows(enabled: true))
        == [.dictate, .dictateLive, .addToGlossary, .settings, .updates, .quit])
  }

  @Test("Shortcuts: all register with the mode off, only dictation ones and Settings with it on")
  func shortcutList() {
    for slot in ShortcutSlot.allCases {
      #expect(DictationOnlyMode.registersShortcut(slot, enabled: false))
    }
    let registered = Set(ShortcutSlot.allCases.filter {
      DictationOnlyMode.registersShortcut($0, enabled: true)
    })
    #expect(registered == [.dictate, .dictateLive, .addToGlossary, .openSettings])
  }
}

@Suite("Dictation only defaults")
@MainActor
struct DictationOnlyDefaultsTests {

  private func makeDefaults() -> UserDefaults {
    let name = "DictationOnlyDefaultsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private func apply(
    _ defaults: UserDefaults, languages: [String] = ["de-DE"], appleSilicon: Bool = true,
    appStore: Bool = false, offlineCalls: Counter = Counter()
  ) -> DictationOnlyDefaults.Result {
    DictationOnlyDefaults.apply(
      defaults: defaults, preferredLanguages: languages, isAppleSilicon: appleSilicon,
      isAppStore: appStore, switchOfflineOn: { offlineCalls.count += 1 })
  }

  final class Counter { var count = 0 }

  @Test("Applies Offline Mode, Parakeet, Mac language, Dictate Live and spoken punctuation")
  func appliesAll() {
    let defaults = makeDefaults()
    let offline = Counter()
    let result = apply(defaults, offlineCalls: offline)
    #expect(offline.count == 1)
    #expect(defaults.string(forKey: UserDefaultsKeys.selectedTranscriptionModel) == "parakeet-ultra")
    #expect(defaults.string(forKey: UserDefaultsKeys.whisperLanguage) == "de")
    #expect(defaults.string(forKey: UserDefaultsKeys.dictateMode) == DictateMode.live.rawValue)
    #expect(defaults.string(forKey: UserDefaultsKeys.punctuationMode) == PunctuationMode.spokenOnly.rawValue)
    #expect(defaults.bool(forKey: UserDefaultsKeys.dictationOnlyDefaultsApplied))
    #expect(result == .init(alreadyApplied: false, language: .set(.de), dictateMode: .live))
  }

  @Test("A second call changes nothing, even after the user changed a value")
  func appliesOnce() {
    let defaults = makeDefaults()
    let offline = Counter()
    _ = apply(defaults, offlineCalls: offline)
    defaults.set(DictateMode.dictate.rawValue, forKey: UserDefaultsKeys.dictateMode)
    defaults.set("fr", forKey: UserDefaultsKeys.whisperLanguage)
    defaults.set(PunctuationMode.automatic.rawValue, forKey: UserDefaultsKeys.punctuationMode)
    let result = apply(defaults, offlineCalls: offline)
    #expect(result.alreadyApplied)
    #expect(offline.count == 1)
    #expect(defaults.string(forKey: UserDefaultsKeys.dictateMode) == DictateMode.dictate.rawValue)
    #expect(defaults.string(forKey: UserDefaultsKeys.whisperLanguage) == "fr")
    #expect(defaults.string(forKey: UserDefaultsKeys.punctuationMode) == PunctuationMode.automatic.rawValue)
  }

  @Test("An unsupported Mac language is never silently Auto: the caller is told to ask")
  func unsupportedLanguage() {
    let defaults = makeDefaults()
    let result = apply(defaults, languages: ["uk-UA"])
    #expect(result.language == .needsExplicitPick)
    #expect(defaults.string(forKey: UserDefaultsKeys.whisperLanguage) == nil)
    let other = makeDefaults()
    #expect(apply(other, languages: []).language == .needsExplicitPick)
  }

  @Test("An explicit language already chosen is kept")
  func explicitLanguageKept() {
    let defaults = makeDefaults()
    defaults.set("en", forKey: UserDefaultsKeys.whisperLanguage)
    let result = apply(defaults, languages: ["de-DE"])
    #expect(result.language == .kept(.en))
    #expect(defaults.string(forKey: UserDefaultsKeys.whisperLanguage) == "en")
  }

  @Test("The App Store build and Intel Macs get plain Dictate")
  func plainDictateBranches() {
    let appStore = makeDefaults()
    #expect(apply(appStore, appStore: true).dictateMode == .dictate)
    #expect(appStore.string(forKey: UserDefaultsKeys.dictateMode) == DictateMode.dictate.rawValue)
    let intel = makeDefaults()
    #expect(apply(intel, appleSilicon: false).dictateMode == .dictate)
    #expect(intel.string(forKey: UserDefaultsKeys.dictateMode) == DictateMode.dictate.rawValue)
  }
}
