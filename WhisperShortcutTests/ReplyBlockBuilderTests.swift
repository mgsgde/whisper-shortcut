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
      case .sources: return "sources"
      }
    }
  }

  private static func codeBlocks(_ blocks: [ReplyContentBlock]) -> [(String, String?)] {
    blocks.compactMap { if case .codeBlock(let c, let l) = $0 { return (c, l) } else { return nil } }
  }

  private static func textBlocks(_ blocks: [ReplyContentBlock]) -> [AttributedString] {
    blocks.compactMap { if case .text(let attr) = $0 { return attr } else { return nil } }
  }

  /// Text of every prose block, in order. Source rows and other non-text blocks are omitted
  /// so a grounded reply's chip row does not add a trailing break.
  private static func joinedText(_ blocks: [ReplyContentBlock]) -> String {
    textBlocks(blocks).map { String($0.characters) }.joined(separator: "\n")
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
    #expect(Self.kinds(ungrounded) == Self.kinds(grounded).filter { $0 != "sources" })
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

    #expect(Self.citedAfter("apples", in: blocks) == ["https://example.com/1"])
    #expect(Self.citedAfter("oranges", in: blocks) == ["https://example.com/2"])
  }

  /// The sources row that directly follows the text block containing `needle`, as URIs.
  private static func citedAfter(_ needle: String, in blocks: [ReplyContentBlock]) -> [String]? {
    guard let i = blocks.firstIndex(where: { block in
      if case .text(let a) = block { return String(a.characters).contains(needle) }
      if case .bulletList(let items) = block {
        return items.contains { String($0.characters).contains(needle) }
      }
      return false
    }), i + 1 < blocks.count, case .sources(let sources) = blocks[i + 1] else { return nil }
    return sources.map(\.uri)
  }

  // MARK: - Source chips

  @Test("A grounded paragraph gets a sources row, never an inline [N] marker")
  func groundedParagraphGetsSourcesRow() {
    let content = "- alpha\n- beta"
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: content,
      sources: [GroundingSource(uri: "https://example.com", title: "S")],
      groundingSupports: [GroundingSupport(startIndex: 0, endIndex: 14, groundingChunkIndices: [0])])
    #expect(Self.kinds(blocks) == ["bulletList", "sources"])
    #expect(!Self.plainText(blocks).contains("[1]"))
  }

  @Test("Grok's [[N]](url) markers become the paragraph's chips and leave the prose")
  func grokLinkMarkersBecomeChips() {
    let content = """
      FOCIL forces inclusion lists.[[1]](https://a.example/x)[[2]](https://www.b.example/y_(z))

      Second claim. [[1]](https://a.example/x)
      """
    let footer = [GroundingSource(uri: "https://a.example/x", title: "a.example")]
    let blocks = ReplyBlockBuilder.buildBlocks(content: content, sources: footer, groundingSupports: [])
    #expect(Self.kinds(blocks) == ["text", "sources", "text", "sources"])
    #expect(Self.citedAfter("FOCIL", in: blocks) == ["https://a.example/x", "https://www.b.example/y_(z)"])
    #expect(Self.citedAfter("Second", in: blocks) == ["https://a.example/x"])
    let text = Self.plainText(blocks)
    #expect(!text.contains("[["), "marker leaked into prose: \(text)")
    #expect(text.contains("inclusion lists."))
    guard case .sources(let chips) = blocks[1] else { return }
    #expect(chips.map(\.title) == ["a.example", "b.example"])
  }

  @Test("Grok's leaked [web:N] tokens are stripped without inventing a source")
  func grokWebTokensAreStripped() {
    let content = "Validators can no longer censor. [web:9][web:11]"
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: content,
      sources: (0..<12).map { GroundingSource(uri: "https://s\($0).example", title: "s\($0)") },
      groundingSupports: [])
    #expect(Self.kinds(blocks) == ["text"])
    #expect(Self.plainText(blocks) == "Validators can no longer censor.")
  }

  @Test("GPT's ([domain](url)) citations become chips; a model's own parenthesized link stays")
  func openAIParenCitationsBecomeChips() {
    let content = """
      Rates held steady. ([reuters.com](https://www.reuters.com/a?utm_source=openai))

      Two at once. ([a.example](https://a.example/x), [b.example](https://b.example/y))

      See the guide ([docs](https://docs.example/guide)) for details.
      """
    let footer = [
      GroundingSource(uri: "https://a.example/x", title: "a.example"),
      GroundingSource(uri: "https://b.example/y", title: "b.example"),
    ]
    let blocks = ReplyBlockBuilder.buildBlocks(content: content, sources: footer, groundingSupports: [])
    #expect(Self.kinds(blocks) == ["text", "sources", "text", "sources", "text"])
    #expect(Self.citedAfter("Rates", in: blocks) == ["https://www.reuters.com/a?utm_source=openai"])
    #expect(Self.citedAfter("Two at once", in: blocks) == ["https://a.example/x", "https://b.example/y"])
    let text = Self.plainText(blocks)
    #expect(text.contains("Rates held steady.\n"), "marker left residue: \(text)")
    #expect(!text.contains("reuters"))
    #expect(text.contains("docs"), "a non-citation link was stripped: \(text)")
  }

  @Test("A GPT citation cut off mid-stream is hidden until it completes")
  func partialOpenAICitationHidden() {
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: "Rates held steady. ([reuters.com](https://www.reu", sources: [], groundingSupports: [])
    #expect(Self.plainText(blocks) == "Rates held steady.")
  }

  @Test("A marker cut off mid-stream is hidden until it completes")
  func partialMarkerHiddenWhileStreaming() {
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: "Almost done.[[2]](https://exa", sources: [], groundingSupports: [])
    #expect(Self.plainText(blocks) == "Almost done.")
  }

  @Test("Markers inside fenced code are left alone")
  func markersInCodeUntouched() {
    let content = "Example:\n\n```\nlet a = b[[1]](x)\n```"
    let blocks = ReplyBlockBuilder.buildBlocks(content: content, sources: [], groundingSupports: [])
    #expect(Self.codeBlocks(blocks).first?.0 == "let a = b[[1]](x)")
  }

  // MARK: - Line breaks

  /// `.full` markdown collapses a single newline into a space. Grounded replies never reach
  /// `normalizeMarkdownParagraphBreaks`, so the break has to survive in the shared renderer.
  @Test("Single newlines in a reply stay line breaks, grounded or not")
  func singleNewlinesStayLineBreaks() {
    let content = "Hi Tom,\nthanks…\nBest,\nMagnus"
    let ungrounded = ReplyBlockBuilder.buildBlocks(
      content: content, sources: [], groundingSupports: [])
    #expect(Self.joinedText(ungrounded) == content)

    let grounded = ReplyBlockBuilder.buildBlocks(
      content: content,
      sources: [GroundingSource(uri: "https://example.com/a", title: "A")],
      groundingSupports: [GroundingSupport(startIndex: 0, endIndex: content.count, groundingChunkIndices: [0])])
    #expect(Self.joinedText(grounded) == content)
  }

  @Test("Inline markdown still applies on a line that keeps its break")
  func inlineMarkdownSurvivesLineBreaks() {
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: "**Hi** Tom,\nthanks", sources: [], groundingSupports: [])
    #expect(Self.joinedText(blocks) == "Hi Tom,\nthanks")
  }

  @Test("A heading on its own line is not glued to the surrounding prose")
  func headingKeepsSurroundingLineBreaks() {
    let content = "Here is the plan:\n### Step one\nDo the thing."
    for blocks in [
      ReplyBlockBuilder.buildBlocks(content: content, sources: [], groundingSupports: []),
      ReplyBlockBuilder.buildBlocks(
        content: content,
        sources: [GroundingSource(uri: "https://example.com/a", title: "A")],
        groundingSupports: [GroundingSupport(startIndex: 0, endIndex: content.count, groundingChunkIndices: [0])]),
    ] {
      let texts = Self.textBlocks(blocks)
      #expect(texts.count == 1)
      guard let attr = texts.first else { continue }
      #expect(String(attr.characters) == "Here is the plan:\nStep one\nDo the thing.")
      let heading = attr.runs.contains { run in
        run[ProseFontHint.self] != nil && String(attr[run.range].characters).contains("Step one")
      }
      #expect(heading)
    }
  }

  @Test("A paragraph that opens with a heading still renders the heading above its body")
  func leadingHeadingStillRenders() {
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: "### Step one\nDo the thing.", sources: [], groundingSupports: [])
    #expect(Self.joinedText(blocks) == "Step one\n\nDo the thing.")
  }

  @Test("A paragraph that opens with a heading does not glue its later headings")
  func leadingHeadingDoesNotGlueLaterHeadings() {
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: "### A\nfoo\n### B\nbar", sources: [], groundingSupports: [])
    let texts = Self.textBlocks(blocks)
    #expect(texts.count == 1)
    guard let attr = texts.first else { return }
    #expect(String(attr.characters) == "A\n\nfoo\nB\nbar")
    let headingB = attr.runs.contains { run in
      run[ProseFontHint.self] != nil && String(attr[run.range].characters) == "B"
    }
    #expect(headingB)
  }

  @Test("A quote line loses its `> ` marker but keeps its line break")
  func quoteMarkerIsStripped() {
    let blocks = ReplyBlockBuilder.buildBlocks(
      content: "He said:\n> be kind\n> always", sources: [], groundingSupports: [])
    #expect(Self.joinedText(blocks) == "He said:\nbe kind\nalways")
  }

  @Test("A reply keeps prices, inline-code dollars, Windows paths, and real math")
  func replyKeepsDollarsPathsAndMath() {
    let content = """
    costs $5 per month, or $50
    `echo $HOME and $PATH`
    C:\\Users\\tom\\index.txt
    $x^2$
    $\\alpha \\to \\beta$
    $$x^2$$
    """
    let expected = """
    costs $5 per month, or $50
    echo $HOME and $PATH
    C:\\Users\\tom\\index.txt
    x²
    α → β
    x²
    """
    #expect(Self.joinedText(ReplyBlockBuilder.buildBlocks(
      content: content, sources: [], groundingSupports: [])) == expected)
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
