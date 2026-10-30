import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Prompt reply cleanup")
struct PromptReplyCleanupTests {

  @Test("A bulleted reply ending in a prompt suffix is left intact")
  func bulletSuffixSurvives() {
    let reply = "- Cut adverbs\n- Remove filler words"
    #expect(PromptReplyCleanup.normalize(reply) == reply)
  }

  @Test("A reply that starts like a transcript prefix is left intact")
  func prefixPhraseSurvives() {
    let reply = "Clean text with no typos is the goal."
    #expect(PromptReplyCleanup.normalize(reply) == reply)
  }

  @Test("A reply that mentions several prompt keywords is accepted")
  func keywordHeavyReplyIsAccepted() throws {
    try PromptReplyCleanup.validate(
      "Write with proper punctuation, remove filler words, and skip disfluencies.",
      mode: "PROMPT-MODE-OPENAI")
  }

  @Test("An empty reply is a retryable model failure")
  func emptyReplyIsEmptyModelReply() {
    #expect(throws: TranscriptionError.emptyModelReply) {
      try PromptReplyCleanup.validate("", mode: "PROMPT-MODE-GEMINI")
    }
    #expect(throws: TranscriptionError.emptyModelReply) {
      try PromptReplyCleanup.validate("  \n ", mode: "PROMPT-MODE-LOCAL")
    }
    #expect(TranscriptionError.emptyModelReply.isRetryable)
    let popup = SpeechErrorFormatter.titleAndBodyForPopup(.emptyModelReply)
    #expect(popup.body == "The model returned no text. Your recording was kept – try Retry or another model.")
  }

  @Test("A transcription preamble is stripped")
  func preambleIsStripped() {
    #expect(PromptReplyCleanup.normalize("**Transcription:** hello") == "hello")
  }
}
