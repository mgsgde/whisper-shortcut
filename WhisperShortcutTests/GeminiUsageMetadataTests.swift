import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// The stall watchdog and the "Searching the web…" label both key off `usageMetadata`: a growing
/// `totalTokenCount` is progress, a growing `toolUsePromptTokenCount` is a grounding round.
@Suite("Gemini usage metadata")
struct GeminiUsageMetadataTests {

  @Test("toolUsePromptTokenCount decodes from a grounded stream chunk")
  func decodesToolUseTokens() throws {
    let json = """
      {"candidates":[{"content":{"role":"model","parts":[{"text":""}]}}],
       "usageMetadata":{"promptTokenCount":10372,"candidatesTokenCount":41,
       "toolUsePromptTokenCount":13792,"totalTokenCount":24205}}
      """
    let chunk = try JSONDecoder().decode(GeminiResponse.self, from: Data(json.utf8))
    let usage = try #require(chunk.usageMetadata)
    #expect(usage.toolUsePromptTokenCount == 13792)
    #expect(usage.totalTokenCount == 24205)
  }
}
