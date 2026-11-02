import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Gemini reports `groundingSupports.segment` offsets in UTF-8 bytes; the citation UI slices by
/// Character. Without conversion, chips drift after the first umlaut or emoji.
@Suite("Gemini grounding offsets")
struct GeminiGroundingOffsetTests {

  private func response(start: Int, end: Int) throws -> GeminiResponse {
    let json = """
      {"candidates":[{"content":{"role":"model","parts":[{"text":"x"}]},
       "groundingMetadata":{"groundingSupports":[
         {"segment":{"startIndex":\(start),"endIndex":\(end)},"groundingChunkIndices":[0]}]}}]}
      """
    return try JSONDecoder().decode(GeminiResponse.self, from: Data(json.utf8))
  }

  /// Slices `text` by Character offsets the way the paragraph builder counts them.
  private func slice(_ text: String, _ s: GroundingSupport) -> String {
    let a = text.index(text.startIndex, offsetBy: s.startIndex)
    let b = text.index(text.startIndex, offsetBy: s.endIndex)
    return String(text[a..<b])
  }

  @Test("Byte offsets after umlauts and emoji map to the same characters")
  func nonASCIIOffsets() throws {
    let text = "Größe 🎉 über Äpfel. Zweiter Satz mit Quelle."
    let target = "Zweiter Satz mit Quelle."
    let prefix = try #require(text.range(of: target)).lowerBound
    let startByte = text[..<prefix].utf8.count
    let endByte = startByte + target.utf8.count
    #expect(startByte > text[..<prefix].count)  // the bytes really do diverge from characters

    let supports = GeminiAPIClient().extractGroundingSupports(
      from: try response(start: startByte, end: endByte), text: text)
    let support = try #require(supports.first)
    #expect(slice(text, support) == target)
    #expect(support.groundingChunkIndices == [0])
  }

  @Test("ASCII text is unchanged")
  func asciiOffsets() throws {
    let text = "Hello world, see source."
    let supports = GeminiAPIClient().extractGroundingSupports(
      from: try response(start: 13, end: 23), text: text)
    #expect(try slice(text, #require(supports.first)) == "see source")
  }

  @Test("Ranges past the text are clamped; fully out-of-range supports are dropped")
  func clampsAndDrops() throws {
    #expect(GeminiAPIClient.characterRange(utf8Start: 3, utf8End: 99, in: "äbc") == 2..<3)
    #expect(GeminiAPIClient.characterRange(utf8Start: 50, utf8End: 60, in: "äbc") == nil)
    #expect(GeminiAPIClient.characterRange(utf8Start: 0, utf8End: 5, in: "") == nil)
  }

  @Test("A range that splits a multi-byte character covers the whole character")
  func midCharacter() {
    // "ä" is bytes 0..<2; an end of 1 still includes it, a start of 1 starts at the next one.
    #expect(GeminiAPIClient.characterRange(utf8Start: 0, utf8End: 1, in: "äb") == 0..<1)
    #expect(GeminiAPIClient.characterRange(utf8Start: 1, utf8End: 3, in: "äb") == 0..<2)
  }
}
