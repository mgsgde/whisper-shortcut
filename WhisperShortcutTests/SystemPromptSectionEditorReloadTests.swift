import Testing
@testable import WhisperShortcut_AppStore

/// Pins the reload guard that decides whether a `.contextFileDidUpdate` is our own
/// autosave. The store trims the body it writes back, and an emptied field comes back
/// empty, so both must count as our save rather than an outside edit.
@Suite("System prompt section editor reload")
struct SystemPromptSectionEditorReloadTests {

  private struct OwnSaveCase: Sendable {
    let onDisk: String?
    let lastSaved: String
    let isOwn: Bool
    let label: String
  }

  @Test(
    "isOwnSave: trimmed or emptied round trips are our save, anything else is an outside change",
    arguments: [
      OwnSaveCase(onDisk: "", lastSaved: "", isOwn: true, label: "emptied field comes back empty"),
      OwnSaveCase(onDisk: nil, lastSaved: "", isOwn: true, label: "emptied field comes back nil"),
      OwnSaveCase(onDisk: "abc", lastSaved: "abc\n", isOwn: true, label: "trailing newline trimmed on disk"),
      OwnSaveCase(onDisk: "other text", lastSaved: "abc", isOwn: false, label: "different body"),
      OwnSaveCase(onDisk: "abc", lastSaved: "", isOwn: false, label: "disk text against emptied field"),
    ])
  private func isOwnSave(_ c: OwnSaveCase) {
    #expect(
      SystemPromptSectionEditor.isOwnSave(onDisk: c.onDisk, lastSaved: c.lastSaved) == c.isOwn,
      "\(c.label)")
  }

  @Test("Save keeps a glossary term appended during the autosave window and honours deletions")
  func saveKeepsAppendedLine() {
    let loaded = "Metoprolol\nBisoprolol"
    let edited = "Metoprolol"
    let onDisk = "Metoprolol\nBisoprolol\nHbA1c"
    #expect(
      SystemPromptSectionEditor.textToSave(
        section: .whisperGlossary, edited: edited, loaded: loaded, onDisk: onDisk)
        == "Metoprolol\nHbA1c")
  }

  @Test("Prose sections save the edited text as is, even when disk has an extra line")
  func proseSectionIgnoresDisk() {
    #expect(
      SystemPromptSectionEditor.textToSave(
        section: .dictation, edited: "Be brief.", loaded: "Be verbose.",
        onDisk: "Be verbose.\nAlso formal.")
        == "Be brief.")
  }
}
