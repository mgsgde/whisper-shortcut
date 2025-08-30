import SwiftUI

/// Wiederverwendbare Komponente für die GPT-Modellauswahl
struct GPTModelSelectionView: View {
  let title: String
  @Binding var selectedModel: GPTModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: title,
        subtitle: "Choose the AI model for generating responses"
      )

      HStack(spacing: SettingsConstants.modelSpacing) {
        ForEach(GPTModel.allCases, id: \.self) { model in
          ZStack {
            Rectangle()
              .fill(selectedModel == model ? Color.accentColor : Color.clear)
              .cornerRadius(SettingsConstants.cornerRadius)

            Text(model.displayName)
              .font(.system(.body, design: .default))
              .foregroundColor(selectedModel == model ? .white : .primary)
          }
          .frame(maxWidth: .infinity, minHeight: SettingsConstants.modelSelectionHeight)
          .contentShape(Rectangle())
          .onTapGesture {
            NSLog("🎯 GPT-MODEL-SELECTION: User tapped on \(model.displayName) (\(model.rawValue))")
            selectedModel = model
            NSLog(
              "🎯 GPT-MODEL-SELECTION: Model changed to \(selectedModel.displayName) (\(selectedModel.rawValue))"
            )
          }
        }
      }
      .background(Color(.controlBackgroundColor))
      .cornerRadius(8)
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(.separatorColor), lineWidth: 1)
      )
      .frame(height: SettingsConstants.modelSelectionHeight)

      // Model Details
      VStack(alignment: .leading, spacing: 8) {
        Text("Model Details:")
          .font(.callout)
          .fontWeight(.semibold)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        switch selectedModel {
        case .gpt5:
          Text("• GPT-5: Highest quality and most capable model")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
          Text("• Best for: Complex tasks, maximum quality")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
          Text("• Cost: High")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
        case .gpt5Mini:
          Text("• GPT-5 Mini: Fast and efficient model")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
          Text("• Best for: Everyday use, quick responses")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
          Text("• Cost: Low")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
        }
      }
    }
  }
}

#if DEBUG
  struct GPTModelSelectionView_Previews: PreviewProvider {
    static var previews: some View {
      @State var selectedModel: GPTModel = .gpt5Mini

      GPTModelSelectionView(title: "GPT Model", selectedModel: $selectedModel)
        .padding()
        .frame(width: 600)
    }
  }
#endif
