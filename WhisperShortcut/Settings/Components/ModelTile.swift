import SwiftUI

/// A single selectable model tile used in every model picker.
/// Highlights on hover and fills with the accent color when selected. Top-row tiles name why they
/// are there (Recommended · Fastest · Offline); any tile whose provider is not set up yet says so
/// ("Needs key") but stays selectable — the same rule in every picker.
struct ModelTile: View {
  let title: String
  /// Optional second line. Used by routed entries to name the model actually being called, so a
  /// tile reading just "OpenRouter" does not look like a peer of "Gemini 3.5 Flash-Lite".
  var subtitle: String? = nil
  let isSelected: Bool
  let isDisabled: Bool
  /// Why the tile is in the picker's top row; empty everywhere else.
  var badges: [ModelPickerBadge] = []
  /// "Best Gemini pick" under "More models": the provider's own recommendation. Outlined star, so
  /// it never reads as the picker's one filled-star Recommended.
  var providerPick: String? = nil
  /// "Needs key" / "Needs setup" when the model cannot run yet; see `PickerCuratedModel`.
  var setupBadge: String? = nil
  /// Tooltip for `setupBadge`: where to fix it.
  var setupHelp: String? = nil
  let onTap: () -> Void

  @State private var isHovered = false

  var body: some View {
    VStack(spacing: 3) {
      Text(verbatim: title)
        .font(.system(.body, design: .default))
        .fontWeight(.medium)
        .foregroundColor(isSelected ? .white : (isDisabled ? .secondary : .primary))
        .multilineTextAlignment(.center)

      if let subtitle {
        Text(verbatim: subtitle)
          .font(.caption2)
          .foregroundColor(isSelected ? .white.opacity(0.85) : .secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      if !badges.isEmpty || providerPick != nil || setupBadge != nil {
        HStack(spacing: 8) {
          ForEach(badges, id: \.self) { badge in
            badgeLabel(badge.title, symbol: badge.symbol, tint: tint(for: badge))
          }
          if let providerPick {
            badgeLabel(String(localized: "Best \(providerPick) pick", comment: "Tile badge: the provider's own recommended model, e.g. 'Best Gemini pick'"), symbol: "star", tint: .yellow)
          }
          if let setupBadge {
            badgeLabel(setupBadge, symbol: "key.fill", tint: .orange)
              .help(setupHelp ?? "")
          }
        }
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, minHeight: SettingsConstants.modelSelectionHeight)
    .background(
      RoundedRectangle(cornerRadius: SettingsConstants.cornerRadius)
        .fill(fillColor)
    )
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
    .accessibilityLabel(accessibilityText)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private func badgeLabel(_ text: String, symbol: String, tint: Color) -> some View {
    HStack(spacing: 3) {
      Image(systemName: symbol)
        .font(.system(size: 8, weight: .semibold))
        .foregroundColor(isSelected ? .white : tint)
      Text(verbatim: text)
        .font(.caption2)
        .fontWeight(.medium)
        .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary)
    }
    .fixedSize()
  }

  private func tint(for badge: ModelPickerBadge) -> Color {
    switch badge {
    case .recommended: return .yellow
    case .fastest: return .cyan
    case .offline: return .green
    }
  }

  private var accessibilityText: String {
    ([title, subtitle] + badges.map(\.title) + [providerPick.map { String(localized: "Best \($0) pick", comment: "Tile badge: the provider's own recommended model, e.g. 'Best Gemini pick'") }, setupBadge])
      .compactMap { $0 }
      .joined(separator: ", ")
  }

  private var fillColor: Color {
    if isSelected { return Color.accentColor }
    if isHovered { return Color.primary.opacity(0.08) }
    return Color.clear
  }
}
