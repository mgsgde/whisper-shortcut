import Testing
@testable import WhisperShortcut_AppStore

/// Gemini sometimes writes its reasoning into the visible answer between `start_thought` and
/// `end_thought`. `ChatViewModel` is `@MainActor`, and so is this static.
@MainActor
@Suite("Leaked thought strip")
struct LeakedThoughtStripTests {

  @Test("Text without markers is unchanged, apart from the leading whitespace trim")
  func noMarkersUnchanged() {
    #expect(ChatViewModel.stripLeakedThoughtTokens("Hello there") == "Hello there")
    #expect(ChatViewModel.stripLeakedThoughtTokens("Hello\nthere") == "Hello\nthere")
    #expect(ChatViewModel.stripLeakedThoughtTokens("  \nHello") == "Hello")
  }

  @Test("A full block at the start is removed and the answer is kept")
  func fullBlockAtStartRemoved() {
    let leaked = """
    start_thought
    Context: Work Chat (Teams) with colleague Mark.
    Wait, let's keep it close to dictation.
    end_thought
    Thanks Mark, I'll send the notes.
    """
    #expect(ChatViewModel.stripLeakedThoughtTokens(leaked) == "Thanks Mark, I'll send the notes.")
  }

  @Test("An end_thought with no opener drops the prefix")
  func orphanEndThoughtDropsPrefix() {
    let leaked = """
    Context: Work Chat with colleague Mark.
    Wait, let's keep it close to dictation.
    end_thought
    Thanks Mark, I'll send the notes.
    """
    #expect(ChatViewModel.stripLeakedThoughtTokens(leaked) == "Thanks Mark, I'll send the notes.")
  }

  @Test("A start_thought with no closer drops the tail")
  func unclosedStartThoughtDropsTail() {
    let leaked = "Thanks Mark, I'll send the notes.\nstart_thought\nStill checking the spelling."
    #expect(ChatViewModel.stripLeakedThoughtTokens(leaked) == "Thanks Mark, I'll send the notes.\n")
  }

  @Test("Two blocks are both removed")
  func twoBlocksRemoved() {
    let leaked = "start_thought first end_thought Hello start_thought second end_thought there"
    #expect(ChatViewModel.stripLeakedThoughtTokens(leaked) == "Hello  there")
  }
}
