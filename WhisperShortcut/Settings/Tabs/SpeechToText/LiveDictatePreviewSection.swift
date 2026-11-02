import SwiftUI

/// Settings → Dictate: "Show live text while dictating" (plans/active/live-dictate-preview.md).
///
/// Off by default. The switch only works with offline Parakeet once it is downloaded; otherwise
/// it is shown disabled with the reason underneath, and a stored "on" simply waits — the preview
/// checks the model again at every recording start (`LiveDictatePreviewSetting.shouldStart`).
///
/// Its own view reading the setting through `@AppStorage`, so the shared settings model and the
/// tab only gain one line.
struct LiveDictatePreviewSection: View {
  let selectedModel: TranscriptionModel
  /// Observed so the switch enables itself the moment a Parakeet download finishes.
  @ObservedObject var modelManager = ModelManager.shared

  @AppStorage(UserDefaultsKeys.liveDictatePreview) private var isOn = SettingsDefaults.liveDictatePreview

  private var isParakeet: Bool { selectedModel.offlineModelType?.engine == .parakeet }
  private var isAvailable: Bool {
    LiveDictatePreviewSetting.isLivePreviewAvailable(
      model: selectedModel, downloaded: selectedModel.isOfflineModelAvailable())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "Live Text",
        systemImage: "text.bubble",
        subtitle: "While you dictate, a small panel above the recording pill shows what you have said so far. It is a preview: the text that gets pasted is still transcribed from the whole recording after Stop, so it can differ slightly."
      )

      // Shown off while unavailable: a stored "on" that cannot be switched off would only confuse.
      // The stored value is kept and applies again once Parakeet is back.
      Toggle(
        "Show live text while dictating",
        isOn: Binding(get: { isOn && isAvailable }, set: { isOn = $0 }))
        .toggleStyle(SwitchToggleStyle())
        .disabled(!isAvailable)
        .onChange(of: isOn) { _, newValue in
          DebugLogger.log("LIVE-PREVIEW SETTINGS: Live text while dictating changed to \(newValue)")
        }

      if !isAvailable {
        Group {
          // Two literals, not a ternary: a ternary types as String and would skip localization.
          if !LiveDictatePreviewSetting.isAppleSilicon {
            Text("Requires a Mac with Apple silicon.")
          } else if isParakeet {
            Text("Download Parakeet Ultra under Offline Models to use this.")
          } else {
            Text("Available with the offline Parakeet model.")
          }
        }
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
