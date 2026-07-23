import SwiftUI

/// A single selectable model tile used in the transcription and prompt model grids.
/// Highlights on hover, fills with the accent color when selected, and shows a star badge
/// for the recommended model so users see the recommendation before selecting.
struct ModelTile: View {
  let title: String
  let isSelected: Bool
  let isDisabled: Bool
  let isRecommended: Bool
  let onTap: () -> Void

  @State private var isHovered = false

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .fill(fillColor)

      if isRecommended {
        VStack {
          HStack {
            Spacer()
            Image(systemName: "star.fill")
              .font(.caption2)
              .foregroundColor(isSelected ? .white : .yellow)
              .padding(6)
              .help("Recommended")
          }
          Spacer()
        }
      }

      Text(title)
        .font(.system(.body, design: .default))
        .fontWeight(.medium)
        .foregroundColor(isSelected ? .white : (isDisabled ? .secondary : .primary))
        .padding(.horizontal, 8)
    }
    .frame(maxWidth: .infinity, minHeight: SettingsConstants.modelSelectionHeight)
    .contentShape(Rectangle())
    .opacity(isDisabled && !isSelected ? 0.6 : 1)
    .onHover { hovering in
      if !isDisabled { isHovered = hovering }
    }
    .onTapGesture {
      if isDisabled { return }
      onTap()
    }
    .pointerCursorOnHover()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private var fillColor: Color {
    if isSelected { return Color.accentColor }
    if isHovered { return Color.primary.opacity(0.08) }
    return Color.clear
  }
}
