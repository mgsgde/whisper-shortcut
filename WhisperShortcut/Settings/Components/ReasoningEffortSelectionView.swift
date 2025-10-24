import SwiftUI

/// Wiederverwendbare Komponente für die Reasoning Effort-Auswahl
struct ReasoningEffortSelectionView: View {
  let title: String
  @Binding var selectedEffort: ReasoningEffort
  let onEffortChanged: (() -> Void)?

  init(
    title: String,
    selectedEffort: Binding<ReasoningEffort>,
    onEffortChanged: (() -> Void)? = nil
  ) {
    self.title = title
    self._selectedEffort = selectedEffort
    self.onEffortChanged = onEffortChanged
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
      SectionHeader(
        title: title,
        subtitle: "Choose reasoning effort for GPT-5 models (only applies to models that support reasoning)"
      )

      HStack(spacing: SettingsConstants.modelSpacing) {
        ForEach(ReasoningEffort.allCases, id: \.self) { effort in
          ZStack {
            Rectangle()
              .fill(selectedEffort == effort ? Color.accentColor : Color.clear)
              .cornerRadius(SettingsConstants.cornerRadius)

            Text(effort.displayName)
              .font(.system(.body, design: .default))
              .foregroundColor(selectedEffort == effort ? .white : .primary)
          }
          .frame(maxWidth: .infinity, minHeight: SettingsConstants.modelSelectionHeight)
          .contentShape(Rectangle())
          .onTapGesture {
            selectedEffort = effort
            onEffortChanged?()
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

      // Effort Details
      VStack(alignment: .leading, spacing: 8) {
        Text(selectedEffort.description)
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)

        if selectedEffort.isRecommended {
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
}

#if DEBUG
  struct ReasoningEffortSelectionView_Previews: PreviewProvider {
    static var previews: some View {
      @State var selectedEffort: ReasoningEffort = .medium

      ReasoningEffortSelectionView(title: "Reasoning Effort", selectedEffort: $selectedEffort)
        .padding()
        .frame(width: 600)
    }
  }
#endif
