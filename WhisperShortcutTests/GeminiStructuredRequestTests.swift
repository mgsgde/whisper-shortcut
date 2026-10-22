import Foundation
import Testing

@testable import WhisperShortcut_AppStore

/// The Smart Improvement Gemini path used to hand-build the structured-output body.
/// `generateStructured` is that body plus `thinkingConfig`. This pins the diff.
@Suite("Gemini structured request")
struct GeminiStructuredRequestTests {

  @Test("Low thinking adds only thinkingConfig to the hand-built body")
  func lowThinkingIsTheOnlyBodyDifference() throws {
    let model = PromptModel.gemini38Flash.rawValue
    #expect(GeminiAPIClient.generateContentEndpoint(model: model) == AppConstants.contextDerivationEndpoint)
    #expect(
      GeminiAPIClient.generateContentEndpoint(model: model) == TranscriptionModel.gemini38Flash.apiEndpoint)
    let pro = PromptModel.gemini31Pro
    #expect(pro.asTranscriptionModel?.rawValue == pro.rawValue)
    #expect(
      GeminiAPIClient.generateContentEndpoint(model: pro.rawValue) == pro.asTranscriptionModel?.apiEndpoint)

    let schema: [String: Any] = [
      "type": "object",
      "properties": [
        "decision": ["type": "string"] as [String: Any],
      ] as [String: Any],
      "required": ["decision"],
    ]
    let contents: [[String: Any]] = [[
      "role": "user",
      "parts": [
        ["text": "fixed input"],
        ["inline_data": ["mimeType": "audio/wav", "data": "QQ=="]],
      ] as [[String: Any]],
    ]]
    let systemInstruction: [String: Any] = ["parts": [["text": "system"]]]

    let handBuilt: [String: Any] = [
      "contents": contents,
      "system_instruction": systemInstruction,
      "generationConfig": [
        "responseMimeType": "application/json",
        "responseSchema": schema,
        "maxOutputTokens": AppConstants.llmMaxOutputTokens,
      ] as [String: Any],
    ]
    let withThinking = GeminiAPIClient().structuredRequestBody(
      model: model,
      contents: contents,
      systemInstruction: systemInstruction,
      schema: schema,
      thinkingLevel: .low)

    var generation = try #require(withThinking["generationConfig"] as? [String: Any])
    let thinking = try #require(generation.removeValue(forKey: "thinkingConfig") as? [String: Any])
    var withoutThinking = withThinking
    withoutThinking["generationConfig"] = generation

    let handJSON = try Self.canonical(handBuilt)
    let strippedJSON = try Self.canonical(withoutThinking)
    let thinkingJSON = try Self.canonical(thinking)
    print("R93-BODY-DIFF added generationConfig.thinkingConfig=\(thinkingJSON)")
    #expect(strippedJSON == handJSON)
    #expect(thinking["thinkingLevel"] as? String == "low")
    #expect(thinking.count == 1)
    #expect(handJSON.contains("inline_data"))
    #expect(strippedJSON.contains("mimeType"))
    #expect(!handJSON.contains("thinkingConfig"))
  }

  private static func canonical(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    return try #require(String(data: data, encoding: .utf8))
  }
}
