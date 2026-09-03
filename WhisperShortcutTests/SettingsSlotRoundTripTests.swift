import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Locks the invariant that made the slot table worth building: for every persisted setting,
/// `save` then `load` is the identity.
///
/// Before the table, each setting was spelled out twice — once in `loadCurrentSettings()`, once
/// in `saveSettings()` — and nothing checked that the two halves used the same key or the same
/// encoding. A mismatch there is invisible at runtime: the setting simply reverts to its default
/// the next time Settings opens, which reads as "the app forgot my choice", not as a bug.
///
/// The test drives `SettingsViewModel.slots` itself, so a newly added setting is covered the
/// moment it joins the table.
@Suite("Settings slot round-trip", .serialized)
@MainActor
struct SettingsSlotRoundTripTests {

  /// Every UserDefaults key the slot table touches, so the suite can snapshot and restore the
  /// developer's real settings around each test.
  private static let touchedKeys: [String] = [
    UserDefaultsKeys.selectedTranscriptionModel,
    UserDefaultsKeys.selectedPromptModel,
    UserDefaultsKeys.selectedChatModel,
    UserDefaultsKeys.selectedImprovementModel,
    UserDefaultsKeys.whisperLanguage,
    UserDefaultsKeys.transcriptionTemperature,
    UserDefaultsKeys.transcriptionThinkingEffort,
    UserDefaultsKeys.openRouterTranscriptionModelID,
    UserDefaultsKeys.showPopupNotifications,
    UserDefaultsKeys.notificationPosition,
    UserDefaultsKeys.notificationDuration,
    UserDefaultsKeys.errorNotificationDuration,
    UserDefaultsKeys.confirmAboveDurationSeconds,
    UserDefaultsKeys.autoPasteAfterDictation,
    UserDefaultsKeys.restoreClipboardAfterPaste,
    UserDefaultsKeys.fnKeyDictation,
    UserDefaultsKeys.screenshotInPromptMode,
    UserDefaultsKeys.screenshotSaveEnabled,
    UserDefaultsKeys.readAloudSmartRewriteEnabled,
    UserDefaultsKeys.readAloudSpeed,
    UserDefaultsKeys.selectedReadAloudModel,
    UserDefaultsKeys.selectedReadAloudVoiceGemini,
    UserDefaultsKeys.selectedReadAloudVoiceOpenAI,
    UserDefaultsKeys.selectedReadAloudVoiceXAI,
    UserDefaultsKeys.selectedReadAloudVoiceSystem,
    UserDefaultsKeys.chatCloseOnFocusLoss,
    UserDefaultsKeys.settingsCloseOnFocusLoss,
    UserDefaultsKeys.liveMeetingChunkInterval,
    UserDefaultsKeys.liveMeetingSafeguardDurationSeconds,
    UserDefaultsKeys.selectedTranscriptionModelForMeetings,
    UserDefaultsKeys.selectedMeetingSummaryModel,
  ]

  /// Runs `body` with the real UserDefaults restored afterwards — these tests write to
  /// `UserDefaults.standard` because that is what the slot table reads.
  private func preservingDefaults(_ body: () -> Void) {
    let snapshot = Self.touchedKeys.reduce(into: [String: Any]()) { acc, key in
      if let value = UserDefaults.standard.object(forKey: key) { acc[key] = value }
    }
    defer {
      for key in Self.touchedKeys {
        if let original = snapshot[key] {
          UserDefaults.standard.set(original, forKey: key)
        } else {
          UserDefaults.standard.removeObject(forKey: key)
        }
      }
    }
    body()
  }

  /// Distinct from every `SettingsDefaults` value, so a slot that silently falls back to its
  /// default fails the comparison instead of coincidentally matching.
  private func makeProbe() -> SettingsData {
    var data = SettingsData()
    data.selectedTranscriptionModel = .gemini36Flash
    data.selectedPromptModel = .gemini36Flash
    // Chat-capable models only: `loadChatSlotModel` validates `supportsTextChat` and falls back
    // to the default when it fails, which would mask a key mismatch.
    data.selectedChatModel = .grok43
    data.selectedImprovementModel = .claudeSonnet5
    data.whisperLanguage = .de
    data.transcriptionTemperature = .balanced
    data.transcriptionThinkingEffort = .high
    data.openRouterTranscriptionModelID = "probe/openrouter-model"
    data.showPopupNotifications = !SettingsDefaults.showPopupNotifications
    data.notificationPosition = .leftTop
    data.notificationDuration = .sevenSeconds
    data.errorNotificationDuration = .twoSeconds
    data.confirmAboveDuration = .tenMinutes
    data.autoPasteAfterDictation = !SettingsDefaults.autoPasteAfterDictation
    data.restoreClipboardAfterPaste = !SettingsDefaults.restoreClipboardAfterPaste
    data.fnKeyDictation = !SettingsDefaults.fnKeyDictation
    data.screenshotInPromptMode = !SettingsDefaults.screenshotInPromptMode
    data.screenshotSaveEnabled = !SettingsDefaults.screenshotSaveEnabled
    data.readAloudSmartRewriteEnabled = !SettingsDefaults.readAloudSmartRewriteEnabled
    data.readAloudSpeed = .x150
    data.selectedReadAloudModel = .openAIGpt4oMiniTTS
    data.readAloudVoiceGemini = "probe-gemini-voice"
    data.readAloudVoiceOpenAI = "probe-openai-voice"
    data.readAloudVoiceXAI = "probe-xai-voice"
    data.readAloudVoiceSystem = "probe-system-voice"
    data.chatCloseOnFocusLoss = !SettingsDefaults.chatCloseOnFocusLoss
    data.settingsCloseOnFocusLoss = !SettingsDefaults.settingsCloseOnFocusLoss
    data.liveMeetingChunkInterval = .thirtySeconds
    data.liveMeetingSafeguardDuration = .twoHours
    data.selectedTranscriptionModelForMeetings = .gemini36Flash
    data.selectedMeetingSummaryModel = .grok43
    return data
  }

  @Test("Saving then loading every slot returns the same values")
  func roundTripIsIdentity() {
    preservingDefaults {
      let probe = makeProbe()
      for slot in SettingsViewModel.slots { slot.save(probe) }

      var loaded = SettingsData()
      for slot in SettingsViewModel.slots { slot.load(&loaded) }

      // Fields outside the table (Keychain, SMAppService, shortcuts, display-only) stay at
      // their defaults in both, so whole-struct equality is the right assertion.
      #expect(loaded == makeProbe())
    }
  }

  @Test("Loading with nothing persisted yields the documented defaults")
  func loadFallsBackToDefaults() {
    preservingDefaults {
      for key in Self.touchedKeys { UserDefaults.standard.removeObject(forKey: key) }

      var loaded = SettingsData()
      for slot in SettingsViewModel.slots { slot.load(&loaded) }

      #expect(loaded == SettingsData())
    }
  }

  /// The whole-table `roundTripIsIdentity` above can hide a broken slot: it saves and loads
  /// *every* slot, so one that reads a key nobody wrote still lands on the value some other slot
  /// happened to leave behind. This drives each slot alone against a cleared UserDefaults.
  ///
  /// The comparison is against the slot's own **no-op baseline** — what it loads when nothing was
  /// persisted — rather than against a second load of the same state. Comparing two identical
  /// loads is what this test used to do, and it made the test vacuous: both sides ran the same
  /// code over the same bytes, so it passed even when `save` wrote nothing at all. Every probe
  /// value differs from its default (see `makeProbe`), so a slot that genuinely persisted
  /// something cannot match its baseline.
  @Test("Each slot writes something a reload can actually see")
  func everySlotPersists() {
    preservingDefaults {
      let probe = makeProbe()
      for (index, slot) in SettingsViewModel.slots.enumerated() {
        // What this slot yields with nothing persisted.
        for key in Self.touchedKeys { UserDefaults.standard.removeObject(forKey: key) }
        var baseline = SettingsData()
        slot.load(&baseline)

        // What it yields after saving the probe, from the same cleared starting point.
        for key in Self.touchedKeys { UserDefaults.standard.removeObject(forKey: key) }
        slot.save(probe)
        var loaded = SettingsData()
        slot.load(&loaded)

        // A slot whose save and load disagree on the key leaves `loaded` at the default — equal
        // to the baseline. That is exactly the drift this catches.
        #expect(
          loaded != baseline,
          "slot \(index) wrote nothing its own load could see — check that save and load use the same key")
      }
    }
  }
}
