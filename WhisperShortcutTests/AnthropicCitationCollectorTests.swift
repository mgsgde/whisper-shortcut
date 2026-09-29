import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Claude attaches web-search citations to the text block that makes the claim. The collector
/// turns those into the same sources + supports Gemini grounding produces, so the reply renders
/// source chips under the right paragraph without any marker in the stored text.
@Suite("Anthropic citation collector")
struct AnthropicCitationCollectorTests {

  private static func citation(_ url: String) -> [String: Any] {
    ["type": "web_search_result_location", "url": url, "title": "Page", "cited_text": "…"]
  }

  @Test("Each cited text block becomes one support over its own character range")
  func citedBlocksBecomeSupports() {
    var collector = AnthropicCitationCollector()
    collector.textBlockStarted(at: 0)
    collector.textBlockEnded(at: 20)  // uncited preamble
    collector.textBlockStarted(at: 20)
    collector.add(Self.citation("https://www.a.example/x"))
    collector.add(Self.citation("https://b.example/y"))
    collector.add(Self.citation("https://www.a.example/x"))  // repeat within a block
    collector.textBlockEnded(at: 60)
    collector.textBlockStarted(at: 60)
    collector.add(Self.citation("https://b.example/y"))  // repeat across blocks reuses the source
    collector.textBlockEnded(at: 90)

    #expect(collector.sources.map(\.uri) == ["https://www.a.example/x", "https://b.example/y"])
    #expect(collector.sources.map(\.title) == ["a.example", "b.example"])
    #expect(collector.supports == [
      GroundingSupport(startIndex: 20, endIndex: 60, groundingChunkIndices: [0, 1]),
      GroundingSupport(startIndex: 60, endIndex: 90, groundingChunkIndices: [1]),
    ])
  }

  @Test("Citations without a URL are ignored")
  func citationsWithoutURLIgnored() {
    var collector = AnthropicCitationCollector()
    collector.textBlockStarted(at: 0)
    collector.add(["type": "char_location", "cited_text": "x"])
    collector.textBlockEnded(at: 10)
    #expect(collector.sources.isEmpty)
    #expect(collector.supports.isEmpty)
  }

  @Test("Collected supports put the chips under the paragraph that was cited")
  func supportsRenderUnderCitedParagraph() {
    let preamble = "I'll look that up."
    let answer = "Shannon was born in 1916."
    let content = preamble + "\n\n" + answer
    var collector = AnthropicCitationCollector()
    collector.textBlockStarted(at: 0)
    collector.textBlockEnded(at: preamble.count)
    collector.textBlockStarted(at: preamble.count + 2)
    collector.add(Self.citation("https://en.wikipedia.org/wiki/Claude_Shannon"))
    collector.textBlockEnded(at: content.count)

    let blocks = ReplyBlockBuilder.buildBlocks(
      content: content, sources: collector.sources, groundingSupports: collector.supports)
    let kinds = blocks.map { block -> String in
      switch block {
      case .text: return "text"
      case .sources(let s): return "sources:\(s.map(\.title).joined(separator: ","))"
      default: return "other"
      }
    }
    #expect(kinds == ["text", "text", "sources:en.wikipedia.org"])
  }

  @Test("A 400 about web search is recognised as the tool being refused, nothing else is")
  func webSearchRejectionDetection() {
    #expect(AnthropicChatProvider.isWebSearchRejection(
      status: 400,
      body: #"{"type":"error","error":{"type":"invalid_request_error","message":"Web search is not enabled for this organization"}}"#))
    #expect(!AnthropicChatProvider.isWebSearchRejection(status: 400, body: "max_tokens: too large"))
    #expect(!AnthropicChatProvider.isWebSearchRejection(status: 500, body: "web_search overloaded"))
  }
}
