import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The try-it failure router used to test "model" before "api key". Every missing-key message
/// contains "model", so Accounts was unreachable.
@Suite("Onboarding try-it settings tab")
struct OnboardingTryItRoutingTests {

  private struct Silent: Error {}

  @Test("A missing OpenAI key opens Accounts")
  func missingKeyOpensAccounts() {
    let message = ProviderCredentials.missingKeyMessage(.openAI)
    #expect(message.localizedLowercase.contains("model"))
    #expect(OnboardingTryItController.settingsTab(for: Silent(), message: message) == .accounts)
  }

  @Test("A download message opens Dictate")
  func downloadOpensDictate() {
    #expect(
      OnboardingTryItController.settingsTab(
        for: Silent(), message: "Download the selected offline model")
        == .speechToText)
  }
}
