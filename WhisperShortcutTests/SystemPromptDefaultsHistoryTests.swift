import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Guards the "never edited" detection that lets a changed default prompt reach existing installs.
/// The fingerprint list is generated from git history by `scripts/prompt-default-fingerprints.py`;
/// the first test is what makes forgetting to re-run it a build failure rather than a silent
/// no-op for every user.
@Suite("System prompt defaults history")
struct SystemPromptDefaultsHistoryTests {

  @Test("Every current default is in the shipped list — re-run scripts/prompt-default-fingerprints.py if this fails",
        arguments: SystemPromptSection.allCases)
  func currentDefaultIsRegistered(_ section: SystemPromptSection) {
    let current = SystemPromptDefaultsHistory.currentDefault(for: section)
    #expect(SystemPromptDefaultsHistory.isShippedDefault(current, for: section),
            "\(section.rawValue): the current default's fingerprint is missing from SystemPromptDefaultsHistory")
  }

  @Test("Whitespace differences do not count as an edit")
  func normalizationIgnoresWhitespace() {
    let current = AppConstants.defaultChatSystemPrompt
    let rewrapped = "  " + current.replacingOccurrences(of: "\n", with: "\n\n") + "\n\n"
    #expect(SystemPromptDefaultsHistory.fingerprint(rewrapped) == SystemPromptDefaultsHistory.fingerprint(current))
    #expect(SystemPromptDefaultsHistory.upgrades(for: [.chat: rewrapped]).isEmpty, "already current → nothing to lift")
  }

  @Test("A section on the current wording is not lifted")
  func currentIsNotUpgraded() {
    let all = Dictionary(uniqueKeysWithValues: SystemPromptSection.allCases.map {
      ($0, SystemPromptDefaultsHistory.currentDefault(for: $0))
    })
    #expect(SystemPromptDefaultsHistory.upgrades(for: all).isEmpty)
  }

  @Test("An edited section is never lifted")
  func editedIsNotUpgraded() {
    let edited = AppConstants.defaultReadAloudRewritePrompt + "\nAlways read numbers as digits."
    #expect(!SystemPromptDefaultsHistory.isShippedDefault(edited, for: .readAloudRewrite))
    #expect(SystemPromptDefaultsHistory.upgrades(for: [.readAloudRewrite: edited]).isEmpty)
  }

  @Test("A former shipped default is lifted to the current one")
  func formerDefaultIsUpgraded() {
    // The Read Aloud rewrite prompt as shipped 2026-05-29 (8296ab85), fingerprint ab5bd9bd…: recover
    // it from the list by checking that *some* fingerprint other than the current one exists, then
    // simulate a file holding a text with that fingerprint via the public API contract: a text is
    // lifted iff it is a shipped default and not the current wording.
    let current = AppConstants.defaultReadAloudRewritePrompt
    let shipped = SystemPromptDefaultsHistory.shippedFingerprints[.readAloudRewrite] ?? []
    #expect(shipped.count >= 2, "history should contain at least one former wording")
    #expect(shipped.contains(SystemPromptDefaultsHistory.fingerprint(current)))
    // Contract check with a synthetic history entry: register a fake former default and see it lifted.
    let former = "You prepare text for text-to-speech playback. Return only the spoken version."
    #expect(!SystemPromptDefaultsHistory.isShippedDefault(former, for: .readAloudRewrite))
    var history = shipped
    history.insert(SystemPromptDefaultsHistory.fingerprint(former))
    let lifted = SystemPromptDefaultsHistory.upgrades(
      for: [.readAloudRewrite: former], shippedFingerprints: [.readAloudRewrite: history])
    #expect(lifted[.readAloudRewrite] == current)
  }
}
