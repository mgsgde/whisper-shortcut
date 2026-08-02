import SwiftUI

/// The small icon button that sits under a chat message — copy, download, retry, read aloud.
///
/// The four of them used to declare this chrome each for itself: symbol at size 13, a 28×28 hit
/// area, the hover tint, the rounded hover fill at 8%, the plain button style, the pointer cursor,
/// help and accessibility label. Only the symbol, the tooltip and the action ever differed, so
/// changing how a message action *looks* meant getting the same edit right in four places.
///
/// `isActive` is Read Aloud's "currently playing" state: it renders like hover, permanently. Every
/// other caller leaves it false and is unaffected.
struct MessageActionButton: View {
  let systemImage: String
  var isActive: Bool = false
  let help: String
  /// Defaults to `help`; set it only where the spoken label should differ from the tooltip.
  var accessibilityText: String? = nil
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    let highlighted = isActive || isHovered
    return Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 13))
        .foregroundColor(highlighted ? ChatTheme.primaryText : ChatTheme.secondaryText.opacity(0.75))
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(highlighted ? ChatTheme.primaryText.opacity(0.08) : Color.clear)
        )
    }
    .buttonStyle(.plain)
    .onHover { inside in
      isHovered = inside
    }
    .pointerCursorOnHover()
    .help(help)
    .accessibilityLabel(accessibilityText ?? help)
  }
}
