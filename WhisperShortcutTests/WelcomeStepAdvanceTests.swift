import Foundation
import Testing
@testable import WhisperShortcut_AppStore

/// Continue used to be five Keychain booleans OR'd with "any offline model downloaded".
/// Dictation setup now asks only whether the selected transcription model can run, which is
/// what the Done step already asked — so an Anthropic-only key no longer passes the step.
@Suite("Welcome step advance", .serialized)
struct WelcomeStepAdvanceTests {

  @Test("Permissions can continue once the user has answered; the other steps always can")
  func permissionsAndFreeSteps() {
    #expect(WelcomeStep.permissions.canAdvance(micStatus: .granted))
    #expect(WelcomeStep.permissions.canAdvance(micStatus: .denied))
    #expect(!WelcomeStep.permissions.canAdvance(micStatus: .notDetermined))
    #expect(!WelcomeStep.permissions.canAdvance(micStatus: .notApplicable))
    // An unresolved 🌐 conflict with Fn on holds the permissions step, even with the mic answered.
    #expect(!WelcomeStep.permissions.canAdvance(micStatus: .granted, fnSetupResolved: false))
    #expect(!WelcomeStep.permissions.canAdvance(micStatus: .denied, fnSetupResolved: false))
    #expect(WelcomeStep.permissions.canAdvance(micStatus: .granted, fnSetupResolved: true))
    for step in [WelcomeStep.intro, .tryIt, .done] {
      for status: PermissionStatus in [.granted, .denied, .notDetermined, .notApplicable] {
        #expect(step.canAdvance(micStatus: status))
      }
    }
  }

  @Test("Dictation setup follows the selected model, not whether some chat key exists")
  func dictationSetupFollowsSelectedModel() {
    let key = UserDefaultsKeys.selectedTranscriptionModel
    let previous = UserDefaults.standard.string(forKey: key)
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
    // Tiny is not the model onboarding downloads. If it is absent, a chat key in the login
    // Keychain must not flip this to true — that was the Anthropic-only hole.
    UserDefaults.standard.set(TranscriptionModel.whisperTiny.rawValue, forKey: key)
    #expect(TranscriptionModel.loadSelected() == .whisperTiny)
    let expected = TranscriptionModel.whisperTiny.isOfflineModelAvailable()
    #expect(WelcomeStep.dictationSetup.canAdvance(micStatus: .notDetermined) == expected)
    #expect(WelcomeStep.dictationSetup.canAdvance(micStatus: .granted) == expected)
  }
}

@Suite("Onboarding dictation gate")
struct OnboardingDictationGateTests {
  @Test("Offline card needs an installed offline model, not a cloud key")
  func offlineCardRequiresOfflineModel() {
    // Cloud model with a saved key, user switched to the Offline card.
    #expect(!OnboardingDictationGate.canAdvance(choice: .offline, selectedIsOffline: false, selectedCanRun: true))
    // Offline model selected but not downloaded.
    #expect(!OnboardingDictationGate.canAdvance(choice: .offline, selectedIsOffline: true, selectedCanRun: false))
    #expect(OnboardingDictationGate.canAdvance(choice: .offline, selectedIsOffline: true, selectedCanRun: true))
  }

  @Test("Cloud card and no choice follow whether the selected model can run")
  func cloudAndUnsetFollowSelectedModel() {
    for choice: DictationChoice? in [.cloud, nil] {
      #expect(OnboardingDictationGate.canAdvance(choice: choice, selectedIsOffline: false, selectedCanRun: true))
      #expect(!OnboardingDictationGate.canAdvance(choice: choice, selectedIsOffline: false, selectedCanRun: false))
    }
  }
}
