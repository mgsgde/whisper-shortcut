import Testing
@testable import WhisperShortcut_AppStore

/// Pins the reload guard that decides whether a `.contextFileDidUpdate` is our own
/// autosave. The store trims the body it writes back, and an emptied field comes back
/// empty, so both must count as our save rather than an outside edit.
@Suite("System prompt section editor reload")
struct SystemPromptSectionEditorReloadTests {

  @Test("An emptied field comes back empty and is our own save")
  func emptiedField() {
    #expect(SystemPromptSectionEditor.isOwnSave(onDisk: "", lastSaved: ""))
    #expect(SystemPromptSectionEditor.isOwnSave(onDisk: nil, lastSaved: ""))
  }

  @Test("A trailing newline trimmed on disk is still our own save")
  func trailingNewline() {
    #expect(SystemPromptSectionEditor.isOwnSave(onDisk: "abc", lastSaved: "abc\n"))
  }

  @Test("A different body is an outside change")
  func outsideChange() {
    #expect(!SystemPromptSectionEditor.isOwnSave(onDisk: "other text", lastSaved: "abc"))
  }

  @Test("Disk text against an emptied field is an outside change")
  func diskTextAgainstEmptyField() {
    #expect(!SystemPromptSectionEditor.isOwnSave(onDisk: "abc", lastSaved: ""))
  }
}
