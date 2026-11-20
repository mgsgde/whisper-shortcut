import SwiftUI

/// Reusable component for section headers. Pass `systemImage` for a native SF Symbol icon
/// next to the title (preferred over emoji in the title string).
struct SectionHeader: View {
  let title: LocalizedStringResource
  let subtitle: LocalizedStringResource?
  let systemImage: String?

  init(title: LocalizedStringResource, systemImage: String? = nil, subtitle: LocalizedStringResource? = nil) {
    self.title = title
    self.subtitle = subtitle
    self.systemImage = systemImage
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {  // Increased spacing between title and subtitle
      HStack(spacing: 8) {  // Add spacing between icon and text
        if let systemImage = systemImage {
          Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(.secondary)  // monochrome, like Claude's settings
        }
        Text(title)
          .font(.title2)  // Claude-style: calm medium-weight headers, not shouting
          .fontWeight(.medium)
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

