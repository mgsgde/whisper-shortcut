import SwiftUI

/// Small status badge shown next to an API-key section header: green "Connected" when a
/// key is present, neutral "Not set" otherwise. Lets the user see at a glance which
/// providers are configured without revealing the key.
struct APIKeyStatusChip: View {
  let isConnected: Bool

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: isConnected ? "checkmark.circle.fill" : "circle")
        .font(.caption)
      Text(isConnected ? "Connected" : "Not set")
        .font(.caption)
        .fontWeight(.medium)
    }
    .foregroundColor(isConnected ? .green : .secondary)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(
      Capsule().fill((isConnected ? Color.green : Color.secondary).opacity(0.12))
    )
    .accessibilityLabel(isConnected ? "Connected" : "Not set")
  }
}
