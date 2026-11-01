import Testing
@testable import WhisperShortcut_AppStore

/// Pasting a 39-character API key used to write the Keychain once per character.
/// The field now debounces (~500 ms) and flushes on disappear.
@Suite("Debounced async commit")
struct DebouncedAsyncCommitTests {

  @MainActor
  @Test("A burst of keystrokes becomes one commit of the final value")
  func pasteIsOneWrite() async {
    let key = "sk-abcdefghijklmnopqrstuvwxyz012345678"
    #expect(key.count == 39)

    var writes: [String] = []
    let committer = DebouncedAsyncCommit<String>(delay: .milliseconds(30)) { value in
      writes.append(value)
    }
    var typed = ""
    for character in key {
      typed.append(character)
      committer.schedule(typed)
    }
    try? await Task.sleep(for: .milliseconds(80))
    #expect(writes == [key])
  }

  @MainActor
  @Test("Flush writes the latest value without waiting for the delay")
  func flushWritesImmediately() async {
    var writes: [String] = []
    let committer = DebouncedAsyncCommit<String>(delay: .milliseconds(2_000)) { value in
      writes.append(value)
    }
    committer.schedule("partial")
    await committer.flush("full-key")
    #expect(writes == ["full-key"])
  }
}
