import SwiftUI

/// Root view for the chat window.
struct ChatRootView: View {
  var body: some View {
    ChatView()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
