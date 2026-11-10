import SwiftUI

/// A quiet, inline "this needs one step" row for Settings and onboarding.
///
/// Replaces hand-built orange/green boxes (heavy stroke, warning triangle, paragraph of text,
/// two full-width buttons) that read as an error dialog for what is really a one-click fix.
/// The shape: a small tinted symbol badge, a one-line title, an optional one-line detail, and
/// the action on the trailing edge — the way System Settings shows "needs attention" rows.
struct SettingsCallout<Actions: View>: View {
  let symbol: String
  var tint: Color = .orange
  let title: LocalizedStringKey
  var detail: LocalizedStringKey?
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 24, height: 24)
        .background(Circle().fill(tint.opacity(0.16)))

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout)
          .fontWeight(.medium)
          .fixedSize(horizontal: false, vertical: true)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 12)

      HStack(spacing: 8) {
        actions()
      }
      .controlSize(.small)
      .fixedSize()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: SettingsConstants.cardCornerRadius, style: .continuous)
        .fill(tint.opacity(0.07))
    )
    .overlay(
      RoundedRectangle(cornerRadius: SettingsConstants.cardCornerRadius, style: .continuous)
        .strokeBorder(tint.opacity(0.18), lineWidth: 0.5)
    )
  }
}

/// The "done" counterpart: no box, just a green check and one secondary line, so a solved
/// problem stops taking space and attention.
struct SettingsConfirmation: View {
  let text: LocalizedStringKey

  var body: some View {
    Label {
      Text(text)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    }
    .font(.caption)
    .frame(maxWidth: .infinity, alignment: .leading)
    .transition(.opacity)
  }
}
