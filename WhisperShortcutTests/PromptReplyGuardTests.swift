import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Dictate Prompt reply guard")
struct PromptReplyGuardTests {

  private let scaffoldReply =
    "The user provided an SRT-like or timestamped transcript and a selection.\n"
    + "SELECTED TEXT FROM CLIPBOARD (apply the voice instruction to this text):\n\n-\n\n"
    + "VOICE INSTRUCTION:\nthe list\n"
    + String(repeating: "Let me think about what the user might want here. ", count: 200)

  @Test("The observed failure: 11k characters of self-talk quoting the scaffold")
  func observedFailure() {
    let instruction = String(repeating: "a list item, ", count: 31)  // ~400 chars
    #expect(scaffoldReply.count > 10_000)
    #expect(
      PromptReplyGuard.verdict(reply: scaffoldReply, selectedText: "-", instruction: instruction)
        == .scaffoldEcho)
    // Without an instruction the scaffold rule still fires.
    #expect(
      PromptReplyGuard.verdict(reply: scaffoldReply, selectedText: "-", instruction: nil)
        == .scaffoldEcho)
  }

  @Test("Both labels count, in the colon form the model quotes")
  func bothLabels() {
    #expect(
      PromptReplyGuard.verdict(
        reply: "Sure.\nSELECTED TEXT FROM CLIPBOARD:\nfoo", selectedText: "foo", instruction: "fix")
        == .scaffoldEcho)
    #expect(
      PromptReplyGuard.verdict(
        reply: "Sure.\n  VOICE INSTRUCTION: fix", selectedText: "foo", instruction: "fix")
        == .scaffoldEcho)
  }

  @Test("The request builder and the guard share the label constants")
  func sharedConstants() {
    #expect(AppConstants.clipboardSelectionHeader.hasPrefix(AppConstants.clipboardSelectionLabel))
    #expect(PromptReplyGuard.startsLineWithScaffoldLabel(AppConstants.clipboardSelectionHeader))
    #expect(PromptReplyGuard.startsLineWithScaffoldLabel("\(AppConstants.voiceInstructionLabel)\nx"))
  }

  @Test("A reply that merely mentions the words mid-sentence passes")
  func midSentenceMention() {
    let reply = "Your voice instruction was clear. The selected text from clipboard is now shorter."
    #expect(PromptReplyGuard.verdict(reply: reply, selectedText: "Hello world", instruction: "shorter") == .ok)
    #expect(
      PromptReplyGuard.verdict(
        reply: "Note: VOICE INSTRUCTION: is a label.", selectedText: "x", instruction: "y") == .ok)
  }

  @Test("A label the user's own selection already has at a line start is not an echo")
  func labelInUserText() {
    let selection = "Docs\nVOICE INSTRUCTION: spoken command\nmore"
    #expect(
      PromptReplyGuard.verdict(
        reply: "Docs\nVOICE INSTRUCTION: spoken command\nmore!", selectedText: selection,
        instruction: "add an exclamation mark") == .ok)
  }

  @Test("A normal edit passes")
  func normalEdit() {
    #expect(
      PromptReplyGuard.verdict(
        reply: "Hallo Mark, danke für die Nachricht.", selectedText: "hallo mark danke fuer die nachricht",
        instruction: "Korrigiere") == .ok)
  }

  @Test("A long compose reply under the cap passes, over it does not")
  func composeCap() {
    let instruction = "Write a long email to the landlord about the broken heating"
    let cap = max(2000, 8 * instruction.count)
    #expect(cap == 2000)
    #expect(
      PromptReplyGuard.verdict(
        reply: String(repeating: "a", count: 1800), selectedText: nil, instruction: instruction) == .ok)
    #expect(
      PromptReplyGuard.verdict(
        reply: String(repeating: "a", count: cap), selectedText: nil, instruction: instruction) == .ok)
    #expect(
      PromptReplyGuard.verdict(
        reply: String(repeating: "a", count: cap + 1), selectedText: nil, instruction: instruction)
        == .runaway)
  }

  @Test("The cap grows with a long selection plus instruction (8x)")
  func capScalesWithInput() {
    let selection = String(repeating: "s", count: 400)
    let instruction = String(repeating: "i", count: 100)
    let cap = 8 * 500
    #expect(
      PromptReplyGuard.verdict(
        reply: String(repeating: "r", count: cap), selectedText: selection, instruction: instruction)
        == .ok)
    #expect(
      PromptReplyGuard.verdict(
        reply: String(repeating: "r", count: cap + 1), selectedText: selection, instruction: instruction)
        == .runaway)
  }

  @Test("An unknown instruction skips only the length rule")
  func unknownInstruction() {
    #expect(
      PromptReplyGuard.verdict(
        reply: String(repeating: "a", count: 9000), selectedText: nil, instruction: nil) == .ok)
  }

  @Test("The rejection is a retryable error with a popup message")
  func errorSurface() {
    #expect(TranscriptionError.promptReplyRejected.isRetryable)
    let popup = SpeechErrorFormatter.titleAndBodyForPopup(.promptReplyRejected)
    #expect(!popup.body.isEmpty)
    #expect(!popup.shortTitle.isEmpty)
  }
}
