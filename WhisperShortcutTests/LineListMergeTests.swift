import Testing
@testable import WhisperShortcut_AppStore

@Suite("Line list merge (memory, folder map)")
struct LineListMergeTests {
  @Test("Unchanged file: the edit is written as is, deletions included")
  func unchangedFile() {
    let loaded = "- a\n- b"
    #expect(LineListMerge.textToSave(edited: "- a", loaded: loaded, onDisk: loaded) == "- a")
  }

  @Test("A fact added meanwhile survives Save; a deleted line stays deleted")
  func addedMeanwhile() {
    let merged = LineListMerge.textToSave(
      edited: "- a\n- edited", loaded: "- a\n- b", onDisk: "- a\n- b\n- new")
    #expect(merged == "- a\n- edited\n- new")
  }

  @Test("An empty edit keeps only what was added meanwhile")
  func clearedEdit() {
    #expect(LineListMerge.textToSave(edited: "", loaded: "- a", onDisk: "- a\n- new") == "- new")
  }

  @Test("A line the user typed that the model also added is not duplicated")
  func noDuplicate() {
    #expect(LineListMerge.textToSave(edited: "- a\n- x", loaded: "- a", onDisk: "- a\n- x") == "- a\n- x")
  }
}
