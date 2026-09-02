import SwiftUI

/// Collapsed-by-default home for rarely used Settings rows. Reversible; no data-model change.
struct AdvancedSettingsGroup<Content: View>: View {
  @State private var isExpanded = false
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
        content
      }
      .padding(.top, 8)
    } label: {
      Text("Advanced")
        .font(.headline)
    }
  }
}
