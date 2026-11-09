import Testing
import Foundation
@testable import WhisperShortcut_AppStore

@Suite("Markdown lists (R213)")
struct MarkdownListTests {

  @Test("ordered items keep their number")
  func ordinal() {
    let p = MarkdownParsing.parseListLine("3. third")
    #expect(p?.ordinal == 3)
    #expect(p?.content == "third")
    #expect(MarkdownParsing.parseListLine("- x")?.ordinal == nil)
  }

  @Test("indent is measured in columns, tab = 4")
  func indent() {
    #expect(MarkdownParsing.parseListLine("    - x")?.indent == 4)
    #expect(MarkdownParsing.parseListLine("\t- x")?.indent == 4)
    #expect(MarkdownParsing.parseListLine("not a list") == nil)
  }

  @Test("levels follow indentation, capped at 3")
  func levels() {
    #expect(MarkdownParsing.listLevels(forIndents: [0, 2, 4, 0]) == [0, 1, 2, 0])
    #expect(MarkdownParsing.listLevels(forIndents: [0, 4, 8, 12, 16, 20]) == [0, 1, 2, 3, 3, 3])
    #expect(MarkdownParsing.listLevels(forIndents: [0, 1]) == [0, 0])
    #expect(MarkdownParsing.listLevels(forIndents: [0, 3, 0, 3]) == [0, 1, 0, 1])
  }

  @Test("builder yields ordinal and level for nested lists")
  func builderNested() {
    let content = "1. one\n   - sub a\n   - sub b\n2. two"
    let blocks = ReplyBlockBuilder.buildBlocks(content: content, sources: [], groundingSupports: [])
    guard case .bulletList(let items)? = blocks.first else {
      Issue.record("expected a bullet list"); return
    }
    #expect(items.map(\.ordinal) == [1, nil, nil, 2])
    #expect(items.map(\.level) == [0, 1, 1, 0])
    #expect(items.map { String($0.content.characters) } == ["one", "sub a", "sub b", "two"])
  }

  @Test("ordered markers render with their number, nested bullets with a hollow dot")
  func markers() {
    let ordered = ReplyListItem(content: AttributedString("x"), ordinal: 7, level: 0)
    let nested = ReplyListItem(content: AttributedString("x"), ordinal: nil, level: 1)
    let flat = ReplyListItem(content: AttributedString("x"), ordinal: nil, level: 0)
    #expect(ordered.marker == "7. ")
    #expect(nested.marker == "◦ ")
    #expect(flat.marker == "• ")
  }

  @Test("no blank line between an item's continuation line and the next item")
  func continuationKeepsList() {
    let out = MarkdownParsing.normalizeMarkdownParagraphBreaks("1. one\n   more of one\n2. two")
    #expect(out == "1. one\n   more of one\n2. two")
  }

  @Test("a list after plain text still gets a blank line")
  func listAfterText() {
    let out = MarkdownParsing.normalizeMarkdownParagraphBreaks("Intro\n- a")
    #expect(out == "Intro\n\n- a")
  }
}

@Suite("Markdown tables (R214)")
struct MarkdownTableTests {

  @Test("two lines with pipes but no delimiter row are not a table")
  func falseTable() {
    #expect(!MarkdownParsing.looksLikeMarkdownTable("a | b\nc | d"))
    #expect(!MarkdownParsing.looksLikeMarkdownTable("- use a|b\n- or c|d"))
  }

  @Test("header + delimiter row is a table")
  func realTable() {
    let t = "| A | B |\n| --- | :---: |\n| 1 | 2 |"
    #expect(MarkdownParsing.looksLikeMarkdownTable(t))
    let parsed = MarkdownParsing.parseMarkdownTable(t)
    #expect(parsed?.headers == ["A", "B"])
    #expect(parsed?.rows == [["1", "2"]])
  }

  @Test("borderless table is accepted")
  func borderless() {
    let t = "A | B\n--- | ---\n1 | 2"
    #expect(MarkdownParsing.looksLikeMarkdownTable(t))
    #expect(MarkdownParsing.parseMarkdownTable(t)?.rows == [["1", "2"]])
  }

  @Test("cells beyond the header count widen the header, not vanish")
  func extraCells() {
    let t = "| A |\n| --- |\n| 1 | 2 | 3 |"
    let parsed = MarkdownParsing.parseMarkdownTable(t)
    #expect(parsed?.headers == ["A", "", ""])
    #expect(parsed?.rows == [["1", "2", "3"]])
  }

  @Test("escaped pipe is a literal pipe inside a cell")
  func escapedPipe() {
    let t = "| A | B |\n| --- | --- |\n| x \\| y | z |"
    #expect(MarkdownParsing.parseMarkdownTable(t)?.rows == [["x | y", "z"]])
  }

  @Test("a pipe list falls through to a list block")
  func pipeListIsList() {
    let blocks = ReplyBlockBuilder.buildBlocks(content: "- a | b\n- c | d", sources: [], groundingSupports: [])
    guard case .bulletList(let items)? = blocks.first else {
      Issue.record("expected a bullet list"); return
    }
    #expect(items.count == 2)
  }
}
