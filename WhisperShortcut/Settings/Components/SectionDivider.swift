import SwiftUI

/// Reusable divider line between sections.
struct SectionDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color(.separatorColor))
      .frame(height: SettingsConstants.sectionDividerHeight)
  }
}

/// Section divider with standard vertical spacing above and below (use between content sections in settings tabs).
struct SpacedSectionDivider: View {
  var body: some View {
    VStack(spacing: 0) {
      Spacer()
        .frame(height: SettingsConstants.sectionSpacing)
      SectionDivider()
      Spacer()
        .frame(height: SettingsConstants.sectionSpacing)
    }
  }
}
