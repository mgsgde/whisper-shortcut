import SwiftUI

/// Wiederverwendbare Komponente für Section-Headers
struct SectionHeader: View {
  let title: String
  let subtitle: String?

  init(title: String, subtitle: String? = nil) {
    self.title = title
    self.subtitle = subtitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {  // Reduced from 4 to 2 for more compact spacing
      Text(title)
        .font(.title2)  // Increased from .title3 to .title2 for more prominent section headers
        .fontWeight(.semibold)
        .textSelection(.enabled)

      if let subtitle = subtitle {
        Text(subtitle)
          .font(.callout)
          .foregroundColor(.secondary)
          .textSelection(.enabled)
      }
    }
  }
}

#if DEBUG
  struct SectionHeader_Previews: PreviewProvider {
    static var previews: some View {
      VStack(spacing: 20) {
        SectionHeader(title: "Shortcuts")

        SectionHeader(
          title: "Shortcuts",
          subtitle: "Configure keyboard shortcuts for different modes"
        )
      }
      .padding()
    }
  }
#endif
