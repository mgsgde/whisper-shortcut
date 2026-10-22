import SwiftUI

/// Icon, title and subtitle at the top of a Welcome Tour step. Three steps wrote the same stack
/// out by hand, and only two of them let the subtitle wrap.
struct WelcomeStepHeader: View {
  let systemImage: String
  let title: String
  let subtitle: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 32))
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.title2)
          .fontWeight(.semibold)
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
