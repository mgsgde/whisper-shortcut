import SwiftUI

struct ConversationTimeoutSelectionView: View {
  @Binding var selectedTimeout: ConversationTimeout

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {

      Picker("Conversation Timeout", selection: $selectedTimeout) {
        ForEach(ConversationTimeout.allCases, id: \.rawValue) { timeout in
          HStack {
            Text(timeout.displayName)
            if timeout.isRecommended {
              Text("(Recommended)")
                .font(.caption)
                .foregroundColor(.secondary)
            }
          }
          .tag(timeout)
        }
      }
      .pickerStyle(MenuPickerStyle())
    }
  }
}

#Preview {
  ConversationTimeoutSelectionView(selectedTimeout: .constant(.thirtySeconds))
    .padding()
}
