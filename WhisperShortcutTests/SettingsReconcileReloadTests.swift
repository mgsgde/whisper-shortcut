import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Offline Mode (and adding a key) rewrites the persisted model selections while the settings
/// window may be open. The window keeps its own copy in `SettingsViewModel.data` and writes all of
/// it back on the next save — so a copy that is not reloaded both shows the wrong model and puts
/// the cloud selection back behind the mode's back.
@Suite("Settings reload after reconcile", .serialized)
@MainActor
struct SettingsReconcileReloadTests {

  @Test("A reconcile notice reloads the selections the settings window holds")
  func reconcileNoticeReloadsSelections() {
    let key = UserDefaultsKeys.selectedTranscriptionModel
    let saved = UserDefaults.standard.string(forKey: key)
    defer {
      if let saved { UserDefaults.standard.set(saved, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }

    let viewModel = SettingsViewModel()
    let target: TranscriptionModel =
      viewModel.data.selectedTranscriptionModel == .openAIGPTTranscribe
      ? .gemini31FlashLite : .openAIGPTTranscribe
    UserDefaults.standard.set(target.rawValue, forKey: key)
    #expect(viewModel.data.selectedTranscriptionModel != target)

    NotificationCenter.default.post(name: .modelSelectionsReconciled, object: nil)

    #expect(viewModel.data.selectedTranscriptionModel == target)
  }
}
