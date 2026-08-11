import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Pins the behaviour of the single markdown classifier.
///
/// It used to be two copies — one for replies that came back with search grounding, one for
/// everything else — and the copies drifted: the grounded one never learned about fenced code
/// blocks, so a grounded reply showed ``` fences as literal text. These tests exist so the two
/// paths can never again disagree about what a paragraph is.
@Suite("Reply block builder")
struct ReplyBlockBuilderTests {

  // MARK: - Helpers

  private static func kinds(_ blocks: [ReplyContentBlock]) -> [String] {
    blocks.map { block in
      switch block {
      case .text: return "text"
      case .bulletList: return "bulletList"
      case .table: return "table"
      case .separator: return "separator"
      case .codeBlock: return "codeBlock"
      case .image: return "image"
      }
    }
  }

  private static func codeBlocks(_ blocks: [ReplyContentBlock]) -> [(String, String?)] {
    blocks.compactMap { if case .codeBlock(let c, let l) = $0 { return (c, l) } else { return nil } }
  }

  private static func plainText(_ blocks: [ReplyContentBlock]) -> String {
    blocks.map { block -> String in
      switch block {
      case .text(let attr): return String(attr.characters)
      case .bulletList(let items): return items.map { String($0.characters) }.joined(separator: "\n")
      default: return ""
      }
    }.joined(separator: "\n")
  }

  // MARK: - The drift this refactor removed

  private static let fencedReply = """
    Here is how you do it:

    ```swift
    let x = 1
    print(x)
    ```

    That is the whole thing.
    """

  @Test("An ungrounded reply renders its fenced code as a code block")
  func ungroundedCodeFence() {
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: Self.fencedReply, sources: [], groundingSupports: [])
    #expect(Self.kinds(blocks).contains("codeBlock"))
    let code = Self.codeBlocks(blocks)
    #expect(code.count == 1)
    #expect(code.first?.0 == "let x = 1\nprint(x)")
    #expect(code.first?.1 == "swift")
  }

  /// The regression this whole finding is about. Before the two classifiers were merged, a reply
  /// carrying grounding sources went down a path that never called `CodeBlockExtractor`, so the
  /// fence was rendered as literal ``` text.
  @Test("A GROUNDED reply renders its fenced code as a code block too")
  func groundedCodeFence() {
    let sources = [GroundingSource(uri: "https://example.com/a", title: "A")]
    let supports = [GroundingSupport(startIndex: 0, endIndex: 24, groundingChunkIndices: [0])]
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: Self.fencedReply, sources: sources, groundingSupports: supports)

    #expect(Self.kinds(blocks).contains("codeBlock"), "grounded reply lost its code block")
    let code = Self.codeBlocks(blocks)
    #expect(code.first?.0 == "let x = 1\nprint(x)")
    #expect(code.first?.1 == "swift")
    // And the raw fence must not survive anywhere as text.
    #expect(!Self.plainText(blocks).contains("```"))
  }

  @Test("Grounded and ungrounded replies classify the same content the same way")
  func bothPathsAgreeOnStructure() {
    let content = """
      # Heading

      Some prose here.

      - one
      - two

      ---

      | a | b |
      | --- | --- |
      | 1 | 2 |
      """
    let ungrounded = ReplyBlockBuilder.buildBlocks(
      content: content, sources: [], groundingSupports: [])
    let grounded = ReplyBlockBuilder.buildBlocks(
      content: content,
      sources: [GroundingSource(uri: "https://example.com", title: "S")],
      groundingSupports: [GroundingSupport(startIndex: 0, endIndex: 9, groundingChunkIndices: [0])])
    #expect(Self.kinds(ungrounded) == Self.kinds(grounded))
  }

  // MARK: - Citations still land where they did

  /// `OffsetMap` is what makes it safe to pull fenced code out before splitting a grounded reply
  /// into paragraphs. Without it, every support range after the first fence would be interpreted
  /// against the shortened text and cite the wrong paragraph.
  @Test("Citation markers stay on their own paragraph across an extracted code block")
  func citationsSurviveCodeExtraction() {
    // The fence is deliberately long: extraction shortens the text by (fence − placeholder), and
    // the test only discriminates when that shift exceeds the length of the paragraph being cited.
    // A short fence still overlaps its own paragraph by accident and proves nothing.
    let fenceBody = (1...12).map { "let value\($0) = \($0) * 100_000" }.joined(separator: "\n")
    let content = """
      First paragraph about apples.

      ```swift
      \(fenceBody)
      ```

      Second paragraph about oranges.
      """
    let sources = [
      GroundingSource(uri: "https://example.com/1", title: "One"),
      GroundingSource(uri: "https://example.com/2", title: "Two"),
    ]
    // Support 2 points at the LAST paragraph, whose offset only lines up if the extraction shift
    // is translated back to the original content.
    let secondStart = content.range(of: "Second paragraph")!
    let start = content.distance(from: content.startIndex, to: secondStart.lowerBound)
    let supports = [
      GroundingSupport(startIndex: 0, endIndex: 20, groundingChunkIndices: [0]),
      GroundingSupport(startIndex: start, endIndex: start + 20, groundingChunkIndices: [1]),
    ]
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: content, sources: sources, groundingSupports: supports)

    let texts = blocks.compactMap { if case .text(let a) = $0 { return String(a.characters) } else { return nil } }
    let apples = texts.first { $0.contains("apples") }
    let oranges = texts.first { $0.contains("oranges") }
    #expect(apples?.contains("[1]") == true, "first paragraph lost its citation: \(apples ?? "nil")")
    #expect(oranges?.contains("[2]") == true, "second paragraph cited wrong source: \(oranges ?? "nil")")
    #expect(apples?.contains("[2]") == false, "citation bled into the wrong paragraph")
  }

  // MARK: - Citation attachment targets

  @Test("A bullet paragraph cites on its last item, not on a new block")
  func bulletCitationTarget() {
    let content = "- alpha\n- beta"
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: content,
      sources: [GroundingSource(uri: "https://example.com", title: "S")],
      groundingSupports: [GroundingSupport(startIndex: 0, endIndex: 14, groundingChunkIndices: [0])])
    #expect(Self.kinds(blocks) == ["bulletList"])
    guard case .bulletList(let items) = blocks[0] else { return }
    #expect(String(items.last!.characters).contains("[1]"))
    #expect(!String(items.first!.characters).contains("[1]"))
  }

  /// A "heading then bullets" paragraph cites on the HEADING — deliberately not the last block.
  @Test("A heading-plus-bullets paragraph cites on the heading")
  func headingCitationTarget() {
    let content = "Some intro line\n- alpha\n- beta"
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: content,
      sources: [GroundingSource(uri: "https://example.com", title: "S")],
      groundingSupports: [GroundingSupport(startIndex: 0, endIndex: 30, groundingChunkIndices: [0])])
    #expect(Self.kinds(blocks) == ["text", "bulletList"])
    guard case .text(let heading) = blocks[0] else { return }
    #expect(String(heading.characters).contains("[1]"))
  }

  @Test("Code blocks and separators never take a citation marker")
  func nonTextBlocksAreNotCited() {
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: Self.fencedReply,
      sources: [GroundingSource(uri: "https://example.com", title: "S")],
      groundingSupports: [GroundingSupport(startIndex: 0, endIndex: 200, groundingChunkIndices: [0])])
    for (code, _) in Self.codeBlocks(blocks) {
      #expect(!code.contains("["), "citation marker leaked into code: \(code)")
    }
  }
}
