import Testing
@testable import WhisperShortcut_AppStore

@Suite("Dictate Prompt presets")
struct DictatePromptPresetTests {

  @Test("Pending instruction is peeked without consuming")
  func peekDoesNotConsume() {
    DictatePromptPreset.pending = .correct
    #expect(DictatePromptPreset.pending == .correct)
    #expect(DictatePromptPreset.pending?.instruction.contains("Correct") == true)
    DictatePromptPreset.pending = nil
    #expect(DictatePromptPreset.pending == nil)
  }

  @Test("consumePendingInstruction clears the armed preset")
  func consumeClears() {
    DictatePromptPreset.pending = .format
    let instruction = DictatePromptPreset.consumePendingInstruction()
    #expect(instruction?.contains("Format") == true)
    #expect(DictatePromptPreset.pending == nil)
  }
}
