import SwiftUI

/// Root view for the Gemini Chat window. Chat only; no Meeting mode.
struct GeminiRootView: View {
  var body: some View {
    GeminiChatView()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
