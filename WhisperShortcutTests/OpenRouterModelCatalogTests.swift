import Testing
import Foundation
@testable import WhisperShortcut_AppStore

/// Covers the filtering that decides which OpenRouter models the Dictate picker offers.
///
/// The failure mode is quiet and confusing: dictation sends the recording as an `input_audio`
/// content part, so offering a text-only model produces a request-time API error the user reads as
/// "OpenRouter is broken", not "wrong model". The picker is the only thing standing between them
/// and 300+ mostly-unsuitable slugs, so the audio filter has to be right.
@Suite("OpenRouter model catalog")
struct OpenRouterModelCatalogTests {

  /// Mirrors the real payload shape, including the parts that trip naive decoding: prices are
  /// decimal *strings*, `name` is optional, and `architecture` is absent on some entries.
  private func payload() -> Data {
    Data(
      """
      {"data": [
        {"id": "google/gemini-3.5-flash-lite", "name": "Google: Gemini 3.5 Flash Lite",
         "architecture": {"input_modalities": ["text", "image", "audio"]},
         "pricing": {"prompt": "0.0000005"}},
        {"id": "anthropic/claude-opus", "name": "Anthropic: Claude Opus",
         "architecture": {"input_modalities": ["text", "image"]},
         "pricing": {"prompt": "0.000015"}},
        {"id": "acme/free-omni", "name": "Acme: Free Omni",
         "architecture": {"input_modalities": ["text", "audio"]},
         "pricing": {"prompt": "0"}},
        {"id": "acme/no-architecture", "name": "Acme: Unknown"},
        {"id": "acme/unnamed",
         "architecture": {"input_modalities": ["audio"]}}
      ]}
      """.utf8)
  }

  @Test("Only audio-input models survive the filter")
  func filtersToAudioCapableModels() throws {
    let models = try OpenRouterModelCatalog.decodeAudioModels(from: payload())
    let ids = Set(models.map(\.id))

    #expect(ids == ["google/gemini-3.5-flash-lite", "acme/free-omni", "acme/unnamed"])
    #expect(!ids.contains("anthropic/claude-opus"), "text+image only")
    #expect(!ids.contains("acme/no-architecture"), "no modalities declared — cannot assume audio")
  }

  @Test("Entries without a name fall back to their slug so the picker is never blank")
  func unnamedModelsFallBackToID() throws {
    let models = try OpenRouterModelCatalog.decodeAudioModels(from: payload())
    let unnamed = try #require(models.first { $0.id == "acme/unnamed" })
    #expect(unnamed.name == "acme/unnamed")
  }

  @Test("Prices are converted from per-token strings to a per-million label")
  func formatsPricing() throws {
    let models = try OpenRouterModelCatalog.decodeAudioModels(from: payload())

    let gemini = try #require(models.first { $0.id == "google/gemini-3.5-flash-lite" })
    #expect(gemini.pricePerMillionLabel == "$0.50/M")

    let free = try #require(models.first { $0.id == "acme/free-omni" })
    #expect(free.pricePerMillionLabel == "Free")

    let unpriced = try #require(models.first { $0.id == "acme/unnamed" })
    #expect(unpriced.pricePerMillionLabel == nil)
  }

  @Test("Models are sorted by display name so the menu order is stable")
  func sortsByName() throws {
    let models = try OpenRouterModelCatalog.decodeAudioModels(from: payload())
    let names = models.map(\.name)
    #expect(names == names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
  }
}
