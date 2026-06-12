import SwiftUI

/// Reusable component for section headers. Pass `systemImage` for a native SF Symbol icon
/// next to the title (preferred over emoji in the title string).
struct SectionHeader: View {
  let title: String
  let subtitle: String?
  let systemImage: String?

  init(title: String, systemImage: String? = nil, subtitle: String? = nil) {
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {  // Increased spacing between title and subtitle
      HStack(spacing: 8) {  // Add spacing between icon and text
        if let systemImage = systemImage {
          Image(systemName: systemImage)
            .font(.title2)
            .foregroundColor(.accentColor)
        }
        Text(title)
          .font(.title)  // Increased from .title2 to .title for more prominent section headers
          .fontWeight(.semibold)
          .textSelection(.enabled)
      }

      if let subtitle = subtitle {
        Text(subtitle)
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
      }
    }
  }
}

