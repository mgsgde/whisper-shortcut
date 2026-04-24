import SwiftUI

/// Root view for the chat window.
struct GeminiRootView: View {
  var body: some View {
    GeminiChatView()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
