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
            selectedModel = model
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
        case .gpt5ChatLatest:
          Text("• GPT-5 Chat Latest: Optimized for fast, general chat")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
          Text("• Best for: Quick responses, low latency, everyday use")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
          Text("• Cost: Medium")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
        case .gpt5:
          Text("• GPT-5: Deep reasoning and complex tasks")
            .font(.callout)
            .foregroundColor(.secondary)
            .textSelection(.enabled)
          Text("• Best for: Complex problems, coding, detailed analysis")
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
