import Testing

@testable import WhisperShortcut_AppStore

/// `StructuredJSONExtractor` is what lets Smart Improvement parse a local server's or small
/// model's reply: cloud providers return a bare JSON object, but a local Ollama/LM Studio server
/// or small model routinely wraps it in a code fence, leaves a `<think>` block in front of it, or
/// pads it with a sentence of prose. Each case here is a shape actually observed from one of
/// those sources, not a hypothetical.
@Suite("StructuredJSONExtractor")
struct StructuredJSONExtractorTests {

  @Test("Plain JSON parses as-is")
  func plainJSON() {
    let text = #"{"term": "WhisperShortcut", "count": 3}"#
    let obj = StructuredJSONExtractor.object(from: text)
    #expect(obj?["term"] as? String == "WhisperShortcut")
    #expect(obj?["count"] as? Int == 3)
  }

  @Test("A ```json code fence is stripped")
  func fencedJSON() {
    let text = """
      ```json
      {"term": "glossary", "count": 5}
      ```
      """
    let obj = StructuredJSONExtractor.object(from: text)
    #expect(obj?["term"] as? String == "glossary")
    #expect(obj?["count"] as? Int == 5)
  }

  @Test("A bare ``` fence (no json tag) is stripped too")
  func bareFencedJSON() {
    let text = """
      ```
      {"term": "fence"}
      ```
      """
    let obj = StructuredJSONExtractor.object(from: text)
    #expect(obj?["term"] as? String == "fence")
  }

  @Test("A <think> reasoning block ahead of the JSON is stripped")
  func reasoningBlockThenJSON() {
    let text = """
      <think>
      Let me figure out the right term and count.
      </think>
      {"term": "dictation", "count": 2}
      """
    let obj = StructuredJSONExtractor.object(from: text)
    #expect(obj?["term"] as? String == "dictation")
    #expect(obj?["count"] as? Int == 2)
  }

  @Test("Prose before and after the object is ignored")
  func proseAroundObject() {
    let text = """
      Sure, here is the suggestion you asked for:
      {"term": "prompt", "count": 7}
      Let me know if you want another one!
      """
    let obj = StructuredJSONExtractor.object(from: text)
    #expect(obj?["term"] as? String == "prompt")
    #expect(obj?["count"] as? Int == 7)
  }

  @Test("Garbage with no object anywhere returns nil")
  func garbageReturnsNil() {
    #expect(StructuredJSONExtractor.object(from: "I'm not sure what you mean.") == nil)
    #expect(StructuredJSONExtractor.object(from: "") == nil)
    #expect(StructuredJSONExtractor.object(from: "{ this is not valid json") == nil)
  }

  @Test("A top-level JSON array is not treated as an object")
  func arrayReturnsNil() {
    #expect(StructuredJSONExtractor.object(from: #"["one", "two", "three"]"#) == nil)
  }
}
