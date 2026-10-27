import SwiftUI

/// The rounded, stroked card the onboarding steps and the offline-model card sit on.
///
/// Eight copies spelled out the same background + overlay pair by hand, each with its own literal
/// radius; they agreed on 10 only by luck, next to the 8 the Settings rows use. One modifier keeps
/// the card radius a single decision.
extension View {
  func cardChrome(
    fill: Color = Color(nsColor: .controlBackgroundColor),
    stroke: Color = Color(nsColor: .separatorColor),
    lineWidth: CGFloat = 1
  ) -> some View {
    background(
      RoundedRectangle(cornerRadius: SettingsConstants.cardCornerRadius).fill(fill)
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsConstants.cardCornerRadius)
        .stroke(stroke, lineWidth: lineWidth)
    )
  }
}

/// Icon tinted, text in the secondary colour — a status reads at a glance without the whole line
/// shouting. Shared by the OpenRouter and ChatGPT account rows, which carried identical copies.
struct TintedIconLabelStyle: LabelStyle {
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 6) {
      configuration.icon.foregroundColor(tint)
      configuration.title.foregroundColor(.secondary)
    }
    .font(.callout)
  }
}
