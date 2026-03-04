//
//  SubscriptionModelsConfigService.swift
//  WhisperShortcut
//
//  Caches subscription models from the backend (GET /v1/config/subscription-models) and provides
//  effective PromptModel / TranscriptionModel / TTSModel for subscription mode. Falls back to
//  SettingsDefaults.subscription* constants when fetch failed or model ID is unknown.
//

import Foundation

enum SubscriptionModelsConfigService {
  private static let cacheLock = NSLock()
  private static var _cached: SubscriptionModelsConfig?

  /// Cached config from the last successful fetch. Nil until refresh() succeeds.
  static var cached: SubscriptionModelsConfig? {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    return _cached
  }

  /// Fetches subscription models from the API and updates the cache. Call at app launch or when opening Settings.
  static func refresh() async {
    guard let config = await BackendAPIClient.fetchSubscriptionModels() else { return }
    cacheLock.lock()
    _cached = config
    cacheLock.unlock()
  }

  /// Effective model for prompt_mode / prompt_and_read. Uses cached API config or fallback constant.
  static func effectivePromptModel() -> PromptModel {
    if let id = cached?.prompt_mode, let model = PromptModel(rawValue: id) { return model }
    return SettingsDefaults.subscriptionPromptModel
  }

  /// Effective model for transcription (Dictate). Uses cached API config or fallback constant.
  static func effectiveTranscriptionModel() -> TranscriptionModel {
    if let id = cached?.transcription, let model = TranscriptionModel(rawValue: id) { return model }
    return SettingsDefaults.subscriptionTranscriptionModel
  }

  /// Effective model for Open Gemini chat window. Uses cached API config or fallback constant.
  static func effectiveOpenGeminiModel() -> PromptModel {
    if let id = cached?.gemini_chat, let model = PromptModel(rawValue: id) { return model }
    return SettingsDefaults.subscriptionOpenGeminiModel
  }

  /// Effective model for Smart Improvement. Uses cached API config or fallback constant.
  static func effectiveImprovementModel() -> PromptModel {
    if let id = cached?.smart_improvement, let model = PromptModel(rawValue: id) { return model }
    return SettingsDefaults.subscriptionImprovementModel
  }

  /// Effective TTS model when on subscription. Uses cached API config or fallback constant.
  static func effectiveTTSModel() -> TTSModel {
    if let id = cached?.tts, let model = TTSModel(rawValue: id) { return model }
    return SettingsDefaults.subscriptionTTSModel
  }

  /// Effective model for meeting summary (live and past) when on subscription.
  static func effectiveMeetingSummaryModel() -> PromptModel {
    if let id = cached?.meeting_summary, let model = PromptModel(rawValue: id) { return model }
    return SettingsDefaults.selectedMeetingSummaryModel
  }
}
