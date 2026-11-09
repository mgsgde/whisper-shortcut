import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Code fence scanner (R212)")
struct CodeFenceScannerTests {

  private func scan(_ s: String) -> [CodeBlockExtractor.FenceMatch] {
    CodeBlockExtractor.scanFences(in: s)
  }

  @Test("language with symbols: c++, objective-c, c#")
  func symbolLanguages() {
    #expect(scan("```c++\nint x;\n```").first?.language == "c++")
    #expect(scan("```objective-c\nint x;\n```").first?.language == "objective-c")
    #expect(scan("```c#\nint x;\n```").first?.language == "c#")
  }

  @Test("tilde fences")
  func tildes() {
    let m = scan("~~~python\nprint(1)\n~~~")
    #expect(m.count == 1)
    #expect(m[0].code == "print(1)")
    #expect(m[0].language == "python")
  }

  @Test("indented fence strips the same indent from code")
  func indented() {
    let m = scan("- item\n  ```swift\n  let a = 1\n    let b = 2\n  ```\n")
    #expect(m.count == 1)
    #expect(m[0].code == "let a = 1\n  let b = 2")
    #expect(m[0].language == "swift")
  }

  @Test("CRLF line endings")
  func crlf() {
    let m = scan("```js\r\nlet a;\r\nlet b;\r\n```\r\nafter")
    #expect(m.count == 1)
    #expect(m[0].code == "let a;\nlet b;")
    #expect(m[0].language == "js")
  }

  @Test("unclosed fence runs to the end of the text")
  func unclosed() {
    let m = scan("intro\n```bash\nls -la\necho hi")
    #expect(m.count == 1)
    #expect(m[0].code == "ls -la\necho hi")
    let text = "intro\n```bash\nls -la\necho hi"
    #expect(NSMaxRange(m[0].range) == (text as NSString).length)
  }

  @Test("empty block does not swallow following prose")
  func emptyBlock() {
    let r = CodeBlockExtractor.extract(from: "```\n```\nafter text")
    #expect(r.blocks.count == 1)
    #expect(r.blocks[0].code == "")
    #expect(r.processed.contains("after text"))
  }

  @Test("four-backtick fence may contain triple-backtick lines")
  func longFence() {
    let m = scan("````md\n```\ninner\n```\n````\ntail")
    #expect(m.count == 1)
    #expect(m[0].code == "```\ninner\n```")
    #expect(m[0].language == "md")
  }

  @Test("closing fence must be at least as long and same char")
  func closingRules() {
    let m = scan("```\na\n~~~\nb\n```")
    #expect(m.count == 1)
    #expect(m[0].code == "a\n~~~\nb")
  }

  @Test("inline triple backticks are not a fence")
  func inlineNotFence() {
    #expect(scan("use ```code``` inline").isEmpty)
    #expect(scan("```code```").isEmpty)
  }

  @Test("two blocks with prose between")
  func twoBlocks() {
    let r = CodeBlockExtractor.extract(from: "a\n```x\n1\n```\nmid\n```y\n2\n```\nz")
    #expect(r.blocks.map(\.code) == ["1", "2"])
    #expect(r.blocks.map(\.language) == ["x", "y"])
    #expect(r.processed.contains("mid"))
    #expect(r.processed.contains("z"))
  }
}
