import SwiftUI

/// Wiederverwendbare Komponente für die GPT-Modellauswahl
struct GPTModelSelectionView: View {
  let title: String
  @Binding var selectedModel: GPTModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.sectionSpacing) {
      SectionHeader(title: title)
      
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

        ForEach(GPTModel.allCases, id: \.self) { model in
          HStack {
            Text("• \(model.displayName):")
              .font(.callout)
              .foregroundColor(.secondary)
              .textSelection(.enabled)
            
            Text("\(model.costLevel) cost")
              .font(.callout)
              .foregroundColor(model.isRecommended ? .green : .orange)
              .textSelection(.enabled)
            
            if model.isRecommended {
              Text("(Recommended)")
                .font(.callout)
                .foregroundColor(.green)
                .textSelection(.enabled)
            }
          }
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
