import SwiftUI

struct ReasoningEffortSelectionView: View {
  @Binding var selectedEffort: ReasoningEffort
  let title: String
  let description: String
  
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.headline)
      
      Text(description)
        .font(.caption)
        .foregroundColor(.secondary)
      
      Picker(title, selection: $selectedEffort) {
        ForEach(ReasoningEffort.allCases, id: \.rawValue) { effort in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(effort.displayName)
                .fontWeight(.medium)
              
              if effort.isRecommended {
                Text("(Recommended)")
                  .font(.caption)
                  .foregroundColor(.secondary)
              }
              
              Spacer()
              
              Text(effort.performanceLevel)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(performanceLevelColor(for: effort.performanceLevel))
            }
          }
          .tag(effort)
        }
      }
      .pickerStyle(.menu)
      
      // Show details for selected effort
      VStack(alignment: .leading, spacing: 6) {
        Text("Details:")
          .font(.callout)
          .fontWeight(.medium)
        
        Text(selectedEffort.description)
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
          
        HStack {
          Text("Performance:")
            .font(.callout)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
          
          Text(selectedEffort.performanceLevel)
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundColor(performanceLevelColor(for: selectedEffort.performanceLevel))
        }
        
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
      .padding(.top, 4)
    }
  }
  
  private func performanceLevelColor(for level: String) -> Color {
    switch level {
    case "Fastest":
      return .green
    case "Fast":
      return .blue
    case "Moderate":
      return .orange
    case "Slow":
      return .red
    default:
      return .secondary
    }
  }
}

// MARK: - Preview
struct ReasoningEffortSelectionView_Previews: PreviewProvider {
  static var previews: some View {
    VStack {
      ReasoningEffortSelectionView(
        selectedEffort: .constant(.low),
        title: "Prompt Reasoning Effort",
        description: "Controls the depth of analysis for GPT-5 prompt responses"
      )
      
      Divider()
      
      ReasoningEffortSelectionView(
        selectedEffort: .constant(.medium),
        title: "Voice Response Reasoning Effort", 
        description: "Controls the depth of analysis for GPT-5 voice responses"
      )
    }
    .padding()
    .previewLayout(.sizeThatFits)
  }
}
