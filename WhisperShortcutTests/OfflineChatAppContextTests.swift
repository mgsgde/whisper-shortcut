import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// Offline Chat has no doc tools, so this section is all it knows about the app. Pinned here: it
/// names the running model and every offline model, picks up README features without the rest of
/// the README, and stays small enough that prefilling it on every message stays cheap.
@Suite("Offline Chat app context")
struct OfflineChatAppContextTests {
  private static let readme = """
    # WhisperShortcut

    ## Features

    - **Dictate**: Record speech. More detail that should not be included.
    - **Read Aloud**: Press the shortcut on any `selected` text. Then more.

    ## Requirements

    - **Not a feature**: must be ignored.
    """

  @Test func digestTakesNameAndFirstSentenceOfEachFeature() {
    #expect(
      OfflineChatAppContext.featureDigest(fromReadme: Self.readme) == [
        "Dictate: Record speech.",
        "Read Aloud: Press the shortcut on any selected text.",
      ])
  }

  /// One line per family, not per catalogue entry: the 6-bit and 8-bit variants are the same model
  /// at a higher precision and the block is prefilled on every offline message, so it names the
  /// family and its 4-bit alias. The model menu still lists every entry.
  @Test func blockNamesTheRunningModelAndEveryOfflineModel() {
    let block = OfflineChatAppContext.block(
      readme: Self.readme, currentModel: .qwen359B,
      shortcuts: [("Chat", "⌘ + 3")], appVersion: "9.99")
    #expect(block.contains("WhisperShortcut 9.99"))
    #expect(block.contains("You are Qwen3.5 9B"))
    for model in LocalLLMModelType.allCases where model.baseModel == model {
      #expect(block.contains(model.displayName))
      #expect(block.contains("/\(model.promptModel.shortAlias)"))
    }
    #expect(block.contains("Chat ⌘ + 3"))
    #expect(!block.contains("Not a feature"))
    let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(!lines.contains { $0.hasPrefix("- - ") })
    for model in LocalLLMModelType.allCases where model.baseModel == model {
      let modelLines = lines.filter { $0.contains(model.displayName) && $0.hasPrefix("- ") }
      #expect(!modelLines.isEmpty)
      #expect(modelLines.allSatisfy { !$0.dropFirst(2).hasPrefix("- ") })
    }
  }

  @Test func noModelLineForANonOfflineModel() {
    let block = OfflineChatAppContext.block(
      readme: "", currentModel: nil, shortcuts: [], appVersion: "1")
    #expect(!block.contains("You are "))
    #expect(!block.contains("Features:"))
  }

  /// The real README, so a long new first sentence shows up here rather than as slower offline
  /// replies. ~4 characters per token: 6,200 characters is about 1,550 tokens.
  @Test func realReadmeStaysWithinBudget() throws {
    let readmeURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("README.md")
    let readme = try String(contentsOf: readmeURL, encoding: .utf8)
    let digest = OfflineChatAppContext.featureDigest(fromReadme: readme)
    #expect(digest.count >= 10)
    let block = OfflineChatAppContext.block(
      readme: readme, currentModel: .qwen34BInstruct2507,
      shortcuts: [("Dictate", "⌘ + 1")], appVersion: "1")
    #expect(block.count < 6_200, "offline app context is \(block.count) characters")
  }

  @Test func appQuestionsTurnOnTheFullSection() {
    #expect(OfflineChatAppContext.isAboutTheApp([
      "Ich will mal überprüfen, ob dieses Quen 3.5 9B funktioniert."]))
    #expect(OfflineChatAppContext.isAboutTheApp(["Wie ändere ich das Tastenkürzel fürs Diktieren?"]))
    #expect(OfflineChatAppContext.isAboutTheApp(["Hallo", "Was kann Whisper Shortcut?"]))
  }

  @Test func everydayQuestionsKeepTheShortLine() {
    #expect(!OfflineChatAppContext.isAboutTheApp([
      "Was ist der Unterschied zwischen einer GmbH und einer UG?"]))
    #expect(!OfflineChatAppContext.isAboutTheApp(["Schreib mir ein Rezept für Pfannkuchen."]))
    // Common words that once switched every chat onto the slow path.
    #expect(!OfflineChatAppContext.isAboutTheApp([
      "Write a prompt for an image model that runs offline in the app settings."]))
    let line = OfflineChatAppContext.identity(currentModel: .qwen359B, appVersion: "9.99")
    #expect(line.contains("Qwen3.5 9B"))
    #expect(line.contains("WhisperShortcut 9.99"))
  }
}
