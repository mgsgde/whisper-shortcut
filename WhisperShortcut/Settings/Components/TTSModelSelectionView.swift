import SwiftUI

/// TTS Model selection component for Read Aloud
struct TTSModelSelectionView: View {
  @Binding var selectedTTSModel: TTSModel
  let onModelChanged: (() -> Void)?
  /// When true, user is on subscription (proxy); TTS model is fixed by the backend. All options disabled.
  let subscriptionMode: Bool

  init(
    selectedTTSModel: Binding<TTSModel>,
    subscriptionMode: Bool = false,
    onModelChanged: (() -> Void)? = nil
  ) {
    self._selectedTTSModel = selectedTTSModel
    self.subscriptionMode = subscriptionMode
    self.onModelChanged = onModelChanged
  }

  private var effectiveSubtitle: String {
    if subscriptionMode {
      return "In subscription mode, TTS model is fixed to Gemini 2.5 Flash TTS and cannot be changed."
    }
    return "Choose the text-to-speech model for reading text aloud"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🤖 TTS Model",
        subtitle: effectiveSubtitle
      )

      if subscriptionMode {
        Text("TTS: Gemini 2.5 Flash TTS (fixed for subscription)")
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
          .padding(.vertical, 4)
      }

      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: SettingsConstants.modelSpacing) {
        ForEach(TTSModel.allCases, id: \.self) { model in
          let isDisabled = subscriptionMode
          ZStack {
            Rectangle()
              .fill(selectedTTSModel == model ? Color.accentColor : Color.clear)
              .cornerRadius(SettingsConstants.cornerRadius)

            Text(model.displayName)
              .font(.system(.body, design: .default))
              .fontWeight(.medium)
              .foregroundColor(selectedTTSModel == model ? .white : (isDisabled ? .secondary : .primary))
          }
          .frame(maxWidth: .infinity, minHeight: SettingsConstants.modelSelectionHeight)
          .contentShape(Rectangle())
          .opacity(isDisabled ? 0.6 : 1)
          .onTapGesture {
            if isDisabled { return }
            selectedTTSModel = model
            onModelChanged?()
          }
          .pointerCursorOnHover()
        }
      }
      .background(Color(.controlBackgroundColor))
      .cornerRadius(8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(.separatorColor), lineWidth: 1)
      )

      // Model Details
      VStack(alignment: .leading, spacing: 8) {
        Text(selectedTTSModel.description)
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        HStack {
          Text("Cost:")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.secondary)

          Text(selectedTTSModel.costLevel)
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(costLevelColor(for: selectedTTSModel.costLevel))
        }

        if selectedTTSModel.isRecommended {
          HStack {
            Image(systemName: "star.fill")
              .foregroundColor(.yellow)
              .font(.caption)
            Text("Recommended")
              .font(.callout)
              .fontWeight(.medium)
              .foregroundColor(.secondary)
          }
        }
      }
    }
  }

  // MARK: - Helper Functions
  private func costLevelColor(for costLevel: String) -> Color {
    switch costLevel {
    case "Minimal":
      return .green
    case "Low":
      return .green
    case "Medium":
      return .orange
    case "High":
      return .red
    default:
      return .secondary
    }
  }
}


