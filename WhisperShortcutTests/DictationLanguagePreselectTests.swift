import Foundation
import Testing

@testable import WhisperShortcut_AppStore

@Suite("Dictation language preselect")
struct DictationLanguagePreselectTests {

  @Test("macOS language identifiers map to the app's languages")
  func identifierMapping() {
    #expect(DictationLanguagePreselect.language(forPreferredIdentifier: "de-DE") == .de)
    #expect(DictationLanguagePreselect.language(forPreferredIdentifier: "de") == .de)
    #expect(DictationLanguagePreselect.language(forPreferredIdentifier: "en-US") == .en)
    #expect(DictationLanguagePreselect.language(forPreferredIdentifier: "pt-BR") == .pt)
    #expect(DictationLanguagePreselect.language(forPreferredIdentifier: "zh-Hans-CN") == .zh)
    #expect(DictationLanguagePreselect.language(forPreferredIdentifier: "nb-NO") == .no)
    #expect(DictationLanguagePreselect.language(forPreferredIdentifier: "nn") == .no)
  }

  @Test("A language the app has no entry for, or no language at all, maps to nothing")
  func unmappedIdentifiers() {
    #expect(DictationLanguagePreselect.language(forPreferredIdentifier: "uk-UA") == nil)
    #expect(DictationLanguagePreselect.language(forPreferredIdentifier: "") == nil)
    #expect(DictationLanguagePreselect.language(forPreferredIdentifier: nil) == nil)
  }

  @Test("Auto on a German Mac becomes German with Parakeet")
  func autoBecomesMacLanguage() {
    #expect(
      DictationLanguagePreselect.preselection(
        current: .auto, preferredLanguages: ["de-DE", "en-US"], model: .parakeetUltra) == .de)
  }

  @Test("Only the first preferred language counts")
  func firstLanguageOnly() {
    #expect(
      DictationLanguagePreselect.preselection(
        current: .auto, preferredLanguages: ["en-GB", "de-DE"], model: .parakeetUltra) == .en)
  }

  @Test("A language the user already chose is never overridden")
  func keepsUserChoice() {
    #expect(
      DictationLanguagePreselect.preselection(
        current: .fr, preferredLanguages: ["de-DE"], model: .parakeetUltra) == nil)
    #expect(
      DictationLanguagePreselect.preselection(
        current: .en, preferredLanguages: ["de-DE"], model: .whisperLargeTurbo) == nil)
  }

  @Test("Stays on Auto when the offline model cannot transcribe the Mac's language")
  func unsupportedByModel() {
    // Parakeet covers 25 European languages, not Japanese.
    #expect(
      DictationLanguagePreselect.preselection(
        current: .auto, preferredLanguages: ["ja-JP"], model: .parakeetUltra) == nil)
    #expect(
      DictationLanguagePreselect.preselection(
        current: .auto, preferredLanguages: ["ja-JP"], model: .whisperLargeTurbo) == .ja)
  }

  @Test("Stays on Auto without a usable Mac language")
  func noPreferredLanguage() {
    #expect(
      DictationLanguagePreselect.preselection(
        current: .auto, preferredLanguages: [], model: .parakeetUltra) == nil)
    #expect(
      DictationLanguagePreselect.preselection(
        current: .auto, preferredLanguages: ["uk-UA"], model: .parakeetUltra) == nil)
  }

  @Test("Model language support: Whisper takes every listed language, Parakeet its 25")
  func modelSupport() {
    for language in WhisperLanguage.allCases {
      #expect(OfflineModelType.whisperLargeTurbo.supports(language))
    }
    #expect(OfflineModelType.parakeetUltra.supports(.auto))
    #expect(OfflineModelType.parakeetUltra.supports(.de))
    #expect(!OfflineModelType.parakeetUltra.supports(.ja))
    #expect(!OfflineModelType.parakeetUltra.supports(.zh))
    #expect(!OfflineModelType.parakeetUltra.supports(.ar))
  }
}
