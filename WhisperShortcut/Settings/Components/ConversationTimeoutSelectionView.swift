import SwiftUI

struct ConversationTimeoutSelectionView: View {
  @Binding var selectedTimeout: ConversationTimeout

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Conversation Timeout")
        .font(.headline)

      Text("Clear conversation history after this time to save costs")
        .font(.caption)
        .foregroundColor(.secondary)

      Picker("Conversation Timeout", selection: $selectedTimeout) {
        ForEach(ConversationTimeout.allCases, id: \.rawValue) { timeout in
          HStack {
            Text(timeout.displayName)
            if timeout.isRecommended {
              Text("(Recommended)")
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            if timeout == .never {
              Text("May increase costs")
                .font(.caption)
                .foregroundColor(.orange)
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
  ConversationTimeoutSelectionView(selectedTimeout: .constant(.tenMinutes))
    .padding()
}
