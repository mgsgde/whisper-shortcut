import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The spoken-output rule is appended by a pure function so Dictate Prompt's paste rule stays
/// last only for a normal turn. `FinishedPromptInputs` is private to `MenuBarController`, so the
/// retry flag is not reachable as a pure function from here.
@Suite("Read Aloud Prompt")
struct ReadAloudPromptTests {

  @Test("The spoken-output rule is appended only when the reply is spoken, and it stays last")
  func spokenOutputRuleStaysLast() {
    let base = "BASE" + AppConstants.promptModeOutputRule
    #expect(SpeechService.spokenOutputSystemPrompt(base, outputIsSpoken: false) == base)

    let spoken = SpeechService.spokenOutputSystemPrompt(base, outputIsSpoken: true)
    #expect(spoken == base + AppConstants.readAloudPromptSpokenOutputRule)
    #expect(spoken.hasSuffix(AppConstants.readAloudPromptSpokenOutputRule))
    let paste = spoken.range(of: AppConstants.promptModeOutputRule)
    let spokenRule = spoken.range(of: AppConstants.readAloudPromptSpokenOutputRule)
    #expect(paste != nil && spokenRule != nil)
    if let paste, let spokenRule {
      #expect(paste.upperBound <= spokenRule.lowerBound)
    }
  }

  @Test("A spoken turn is not recorded into Dictate Prompt history")
  func spokenTurnSkipsPromptHistory() {
    #expect(!SpeechService.recordsPromptHistory(
      turnKind: .edit, offlineMode: false, outputIsSpoken: true))
    #expect(!SpeechService.recordsPromptHistory(
      turnKind: .compose, offlineMode: false, outputIsSpoken: true))
    #expect(SpeechService.recordsPromptHistory(
      turnKind: .edit, offlineMode: false, outputIsSpoken: false))
  }
}
