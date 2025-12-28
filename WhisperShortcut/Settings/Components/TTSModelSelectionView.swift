import SwiftUI

/// TTS Model selection component for Read Aloud
struct TTSModelSelectionView: View {
  @Binding var selectedTTSModel: TTSModel
  let onModelChanged: (() -> Void)?

  init(
    selectedTTSModel: Binding<TTSModel>,
    onModelChanged: (() -> Void)? = nil
  ) {
    self._selectedTTSModel = selectedTTSModel
    self.onModelChanged = onModelChanged
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: "🤖 TTS Model",
        subtitle: "Choose the text-to-speech model for reading text aloud"
      )

      LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: SettingsConstants.modelSpacing) {
        ForEach(TTSModel.allCases, id: \.self) { model in
          ZStack {
            Rectangle()
              .fill(selectedTTSModel == model ? Color.accentColor : Color.clear)
              .cornerRadius(SettingsConstants.cornerRadius)

            Text(model.displayName)
              .font(.system(.body, design: .default))
              .fontWeight(.medium)
              .foregroundColor(selectedTTSModel == model ? .white : .primary)
          }
          .frame(maxWidth: .infinity, minHeight: SettingsConstants.modelSelectionHeight)
          .contentShape(Rectangle())
          .onTapGesture {
            selectedTTSModel = model
            onModelChanged?()
          }
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

#if DEBUG
  struct TTSModelSelectionView_Previews: PreviewProvider {
    static var previews: some View {
      @State var selectedTTSModel: TTSModel = .gemini25FlashTTS

      TTSModelSelectionView(selectedTTSModel: $selectedTTSModel)
        .padding()
        .frame(width: 600)
    }
  }
#endif


