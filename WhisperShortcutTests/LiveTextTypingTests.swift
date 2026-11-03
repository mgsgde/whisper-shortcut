import Testing
@testable import WhisperShortcut_AppStore

@Suite("Live text typing for Chromium")
struct LiveTextTypingTests {

  @Test("Chromium-family bundle ids are recognised, others are not")
  func chromiumDetection() {
    for id in [
      "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
      "com.google.Chrome.canary", "org.chromium.Chromium", "com.brave.Browser",
      "com.brave.Browser.beta", "com.microsoft.edgemac", "com.microsoft.edgemac.Dev",
      "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
      "com.operasoftware.OperaGX",
    ] {
      #expect(LiveTextTyping.isChromium(bundleID: id), "\(id)")
    }
    for id in [
      "com.apple.Safari", "org.mozilla.firefox", "com.anthropic.claudefordesktop",
      "com.apple.TextEdit", "com.google.GoogleDrive", "com.google.Chromecast", "",
    ] {
      #expect(!LiveTextTyping.isChromium(bundleID: id), "\(id)")
    }
    #expect(!LiveTextTyping.isChromium(bundleID: nil))
  }

  @Test("Empty text gives no chunks")
  func empty() {
    #expect(LiveTextTyping.chunks("").isEmpty)
  }

  @Test("Exactly 20 UTF-16 units is one chunk, 21 is two")
  func boundary() {
    let twenty = String(repeating: "a", count: 20)
    #expect(LiveTextTyping.chunks(twenty) == [.text(twenty)])
    let twentyOne = twenty + "b"
    #expect(LiveTextTyping.chunks(twentyOne) == [.text(twenty), .text("b")])
  }

  @Test("Umlauts and the ellipsis stay intact")
  func umlauts() {
    let text = "Größe für Ärzte… übermäßig"
    let chunks = LiveTextTyping.chunks(text)
    #expect(chunks.count == 2)
    let joined = chunks.compactMap { chunk -> String? in
      if case .text(let s) = chunk { return s } else { return nil }
    }.joined()
    #expect(joined == text)
  }

  @Test("A surrogate pair is never split at a chunk boundary")
  func surrogatePair() {
    let text = String(repeating: "a", count: 19) + "😀" + "z"
    let chunks = LiveTextTyping.chunks(text)
    #expect(chunks == [.text(String(repeating: "a", count: 19)), .text("😀z")])
    for case .text(let s) in chunks { #expect(s.utf16.count <= 20) }
  }

  @Test("A multi-scalar emoji cluster stays whole")
  func cluster() {
    let family = "👨‍👩‍👧"
    let text = String(repeating: "a", count: 15) + family
    let chunks = LiveTextTyping.chunks(text)
    #expect(chunks == [.text(String(repeating: "a", count: 15)), .text(family)])
  }

  @Test("Line breaks become newline chunks, \\r\\n counts once")
  func newlines() {
    #expect(LiveTextTyping.chunks("a\nb") == [.text("a"), .newline, .text("b")])
    #expect(LiveTextTyping.chunks("a\r\nb") == [.text("a"), .newline, .text("b")])
    #expect(LiveTextTyping.chunks("\n") == [.newline])
    #expect(LiveTextTyping.chunks("a\n\nb") == [.text("a"), .newline, .newline, .text("b")])
  }
}
