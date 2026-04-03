# WhisperShortcut 6.7.1

## Installation

Download the latest build from [Releases](https://github.com/mgsgde/whisper-shortcut/releases).

## Changes

- **Gemini model selection**: Fixed the model picker not prefilling correctly on the first open after a cold launch.
- **App Store build**: Resolved a compile issue by moving `defaultSmartImprovementModel` outside the `SUBSCRIPTION_ENABLED` branch so the App Store target builds cleanly.
- **Subscription models**: Fixed the `SubscriptionModelsConfigService` stub to use `subscriptionImprovementModel` for the improvement feature.

## Full changelog

[Compare v6.7…v6.7.1](https://github.com/mgsgde/whisper-shortcut/compare/v6.7...v6.7.1)
