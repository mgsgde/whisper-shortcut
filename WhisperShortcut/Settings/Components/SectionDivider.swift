import SwiftUI

/// Wiederverwendbare Komponente für Section-Trennung
struct SectionDivider: View {
  var body: some View {
    Rectangle()
      .fill(Color(.separatorColor))
      .frame(height: SettingsConstants.sectionDividerHeight)
  }
}

#if DEBUG
struct SectionDivider_Previews: PreviewProvider {
  static var previews: some View {
    VStack(spacing: 0) {
      Text("Section 1")
        .padding()
      
      SectionDivider()
      
      Text("Section 2")
        .padding()
    }
    .frame(width: 400)
  }
}
#endif
