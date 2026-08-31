import Foundation

/// One model OpenRouter can route to.
///
/// Deliberately at file scope rather than nested inside `OpenRouterModelCatalog`: nesting it in a
/// `@MainActor` class makes the type main-actor isolated too, which puts the pure decode/format
/// logic behind an actor hop and out of reach of synchronous tests.
struct OpenRouterAudioModel: Identifiable, Hashable {
  let id: String
  let name: String
  /// USD per prompt token, as OpenRouter reports it. Nil when the model is unpriced.
  let promptPricePerToken: Double?

  /// "$0.30/M" — the unit users compare on. Audio is billed differently across models, so treat
  /// this as a rough ordering hint, not a quote.
  var pricePerMillionLabel: String? {
    guard let promptPricePerToken else { return nil }
    if promptPricePerToken == 0 { return "Free" }
    return String(format: "$%.2f/M", promptPricePerToken * 1_000_000)
  }
}

/// The list of models OpenRouter currently routes to, fetched live.
///
/// Exists because the alternative — a hardcoded list — is wrong within weeks: OpenRouter adds and
/// retires models continuously, and the whole reason to route through it is that you get new models
/// without an app update. A free-text slug field avoided the staleness but pushed the problem onto
/// the user, who had to know that `google/gemini-3.5-flash-lite` is spelled exactly that way.
///
/// `/api/v1/models` is unauthenticated, so the catalog loads before the user connects an account —
/// they can see what they would be picking from while deciding whether to sign up at all.
@MainActor
final class OpenRouterModelCatalog: ObservableObject {
  static let shared = OpenRouterModelCatalog()

  @Published private(set) var audioModels: [OpenRouterAudioModel] = []
  @Published private(set) var isLoading = false
  @Published private(set) var loadError: String?

  private var hasLoaded = false

  private init() {}

  /// Loads once per app run. Cheap enough to call from `onAppear`.
  func loadIfNeeded() {
    guard !hasLoaded, !isLoading else { return }
    Task { await reload() }
  }

  func reload() async {
    isLoading = true
    loadError = nil
    defer { isLoading = false }

    do {
      var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/models")!)
      request.timeoutInterval = 15
      let (data, response) = try await LLMHTTPSession.integrations.data(for: request)

      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw OpenRouterCatalogError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
      }

      audioModels = try OpenRouterModelCatalog.decodeAudioModels(from: data)
      hasLoaded = true
      DebugLogger.log("OPENROUTER-CATALOG: Loaded \(audioModels.count) audio-capable models")
    } catch {
      loadError = error.localizedDescription
      DebugLogger.logError("OPENROUTER-CATALOG: Load failed: \(error.localizedDescription)")
    }
  }

  /// Split out from the network call, and `nonisolated` so the filtering and sorting stay testable
  /// without a request or an actor hop.
  ///
  /// Filters on `architecture.input_modalities` containing `audio` — the dictation path sends the
  /// recording as an `input_audio` content part, so a model without audio input fails at request
  /// time rather than degrading. Better to not offer it.
  nonisolated static func decodeAudioModels(from data: Data) throws -> [OpenRouterAudioModel] {
    let payload = try JSONDecoder().decode(ModelsResponse.self, from: data)
    return payload.data
      .filter { $0.architecture?.inputModalities?.contains("audio") == true }
      .map {
        OpenRouterAudioModel(
          id: $0.id,
          name: $0.name ?? $0.id,
          promptPricePerToken: $0.pricing?.prompt.flatMap(Double.init)
        )
      }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}

// MARK: - Wire format

private struct ModelsResponse: Decodable {
  let data: [Entry]
}

private struct Entry: Decodable {
  let id: String
  let name: String?
  let architecture: Architecture?
  let pricing: Pricing?
}

private struct Architecture: Decodable {
  let inputModalities: [String]?

  enum CodingKeys: String, CodingKey {
    case inputModalities = "input_modalities"
  }
}

/// Prices arrive as decimal strings ("0.0000005"), not numbers.
private struct Pricing: Decodable {
  let prompt: String?
}

enum OpenRouterCatalogError: LocalizedError {
  case badStatus(Int)

  var errorDescription: String? {
    switch self {
    case .badStatus(let code): return "OpenRouter returned HTTP \(code)."
    }
  }
}
