import SwiftUI

/// Wiederverwendbare Komponente für Section-Trennung
struct SectionDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color(.separatorColor))
      .frame(height: SettingsConstants.sectionDividerHeight)
  }
}
