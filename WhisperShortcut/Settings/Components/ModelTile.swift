import SwiftUI

/// A single selectable model tile used in the transcription and prompt model grids.
/// Highlights on hover, fills with the accent color when selected, and shows a star badge
/// for the recommended model so users see the recommendation before selecting.
struct ModelTile: View {
  let title: String
  /// Optional second line. Used by routed entries to name the model actually being called, so a
  /// tile reading just "OpenRouter" does not look like a peer of "Gemini 3.5 Flash-Lite".
  var subtitle: String? = nil
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

      VStack(spacing: 2) {
        Text(title)
          .font(.system(.body, design: .default))
          .fontWeight(.medium)
          .foregroundColor(isSelected ? .white : (isDisabled ? .secondary : .primary))

        if let subtitle {
          Text(subtitle)
            .font(.caption2)
            .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
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
    .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private var fillColor: Color {
    if isSelected { return Color.accentColor }
    if isHovered { return Color.primary.opacity(0.08) }
    return Color.clear
  }
}
