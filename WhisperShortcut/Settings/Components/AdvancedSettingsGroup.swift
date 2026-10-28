import SwiftUI

/// Collapsed-by-default home for rarely used Settings rows. Reversible; no data-model change.
///
/// The whole header row toggles, like "More models" in the model pickers. A plain `DisclosureGroup`
/// only reacts to its small chevron on macOS, so a click on the word "Advanced" did nothing and
/// testers reported the section as impossible to open.
struct AdvancedSettingsGroup<Content: View>: View {
  @State private var isExpanded = false
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
          Text("Advanced")
            .font(.headline)
          Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .pointerCursorOnHover()
      .accessibilityLabel(Text("Advanced"))
      .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))

      if isExpanded {
        VStack(alignment: .leading, spacing: SettingsConstants.internalSectionSpacing) {
          content
        }
        .padding(.top, 8)
      }
    }
  }
}
